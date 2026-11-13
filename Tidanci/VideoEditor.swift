import Foundation
import AVFoundation
import UIKit
import Speech
import CoreMedia
import AVFAudio
import AudioToolbox

/// 一条字幕
struct SubtitleCue {
    var start: Double
    var end: Double
    var text: String
}

enum EditStage: Int {
    case preparing = 0
    case denoise
    case transcribe
    case render
    case done

    var title: String {
        switch self {
        case .preparing: return "准备"
        case .denoise: return "降噪"
        case .transcribe: return "识别字幕"
        case .render: return "合成"
        case .done: return "完成"
        }
    }
}

/// 对已录视频做后期：降噪、生成字幕并烧进画面。
/// 每一步都可以单独失败，失败了就退回到「不做这一步」继续往下走，
/// 宁可交一个没字幕的成片，也不要整个导出失败。
final class VideoEditor: ObservableObject {

    @Published var stage: EditStage = .preparing
    @Published var progress: Double = 0
    @Published var running = false
    @Published var statusText: String = ""
    /// 这次到底识别出几条字幕 —— 0 就是「一个字都没有」，界面要如实说出来
    @Published var cueCount = 0
    /// 字幕识别出来了但没烧上（带字幕导出失败，改交无字幕成片）
    @Published var subtitleDropped = false
    /// 本次处理已耗时（秒）。四分钟的片子要跑好几分钟，界面得有个东西在动，
    /// 否则用户分不清「在识别」还是「已经卡死」。
    @Published var elapsed: Double = 0

    private var ticker: Timer?
    private var startedAt: Date?

    private let workQ = DispatchQueue(label: "video.editor", qos: .userInitiated)

    struct Fail: LocalizedError {
        let msg: String
        var errorDescription: String? { msg }
    }

    // MARK: - 入口

    /// 只扫气口、不做别的。编辑页点「智能剪辑」后先调它，把结果拿给用户确认，
    /// 确认完再调 `run(... cutGaps:)` 真正剪。
    func scanGaps(input: URL, completion: @escaping ([SilenceGap], Double) -> Void) {
        workQ.async {
            let asset = AVURLAsset(url: input)
            let dur = asset.duration.seconds
            let raw = (try? SilenceCut.detect(input)) ?? []
            let merged = SilenceCut.merge(raw).filter { $0.length > 0.40 }
            DispatchQueue.main.async { completion(merged, dur < 0 ? 0 : dur) }
        }
    }

    func run(input: URL,
             denoise: Bool,
             subtitle: Bool,
             style: SubtitleStyle = SubtitleStyle(),
             /// nil = 不剪；空数组 = 用户选择「一处都不剪」；非空 = 就剪这几处
             cutGaps: [SilenceGap]? = nil,
             completion: @escaping (URL?, String?) -> Void) {
        guard !running else { return }
        running = true
        progress = 0
        stage = .preparing
        statusText = "读视频…"
        cueCount = 0
        subtitleDropped = false
        startTicker()

        workQ.async {
            var notes: [String] = []
            let asset = AVURLAsset(url: input)

            guard let vTrack = asset.tracks(withMediaType: .video).first else {
                self.finish(nil, "这个文件里没有视频轨")
                DispatchQueue.main.async { completion(nil, "这个文件里没有视频轨") }
                return
            }

            // 1) 降噪
            var newAudio: URL?
            if denoise {
                DispatchQueue.main.async {
                    self.stage = .denoise
                    self.statusText = "降噪中…"
                }
                do {
                    let out = Self.temp("denoise.caf")
                    try self.denoise(asset: asset, to: out) { p in
                        DispatchQueue.main.async { self.progress = 0.05 + p * 0.35 }
                    }
                    newAudio = out
                } catch {
                    notes.append("降噪没做成，已保留原音")
                }
            }

            // 2) 掐气口：用用户在弹窗里勾好的那几处。
            //    这里用较低的保命比例（0.15），因为选择权已经在用户手里了。
            var keeps: [CMTimeRange] = []
            if let gaps = cutGaps, !gaps.isEmpty {
                DispatchQueue.main.async {
                    self.progress = 0.44
                }
                keeps = SilenceCut.keepRanges(duration: asset.duration.seconds,
                                              gaps: gaps,
                                              minKeepRatio: 0.15)
                if keeps.isEmpty {
                    notes.append("按选择剪完几乎没内容了，已按原片输出")
                }
            }

            // 3) 字幕
            var cues: [SubtitleCue] = []
            if subtitle {
                DispatchQueue.main.async {
                    self.stage = .transcribe
                    self.statusText = "识别字幕…"
                    self.progress = 0.48
                }
                do {
                    // 注意：这里喂的是「从视频里抽出来的音频」，不是视频文件本身。
                    // 直接把 .mp4 交给 SFSpeechURLRecognitionRequest，十次有九次报
                    // kAFAssistantErrorDomain 1101 —— 一个字都不给。
                    cues = try self.transcribe(asset, limit: asset.duration.seconds)
                    let n = cues.count
                    DispatchQueue.main.async { self.cueCount = n }
                } catch {
                    notes.append("字幕没识别出来：\(error.localizedDescription)")
                    Diag.note("字幕：整体失败 \(error.localizedDescription)")
                }
            }

            // 4) 合成
            DispatchQueue.main.async {
                self.stage = .render
                self.statusText = "合成中…"
                self.progress = 0.72
            }
            do {
                let out = try self.compose(asset: asset,
                                           vTrack: vTrack,
                                           audio: newAudio,
                                           cues: cues,
                                           keeps: keeps,
                                           style: style)
                DispatchQueue.main.async {
                    self.stage = .done
                    self.progress = 1
                    self.statusText = "完成"
                }
                self.finish(out, nil)
                DispatchQueue.main.async {
                    completion(out, notes.isEmpty ? nil : notes.joined(separator: "；"))
                }
            } catch {
                let m = error.localizedDescription
                self.finish(nil, m)
                DispatchQueue.main.async { completion(nil, m) }
            }
        }
    }

    private func finish(_ url: URL?, _ err: String?) {
        DispatchQueue.main.async {
            self.stopTicker()
            self.running = false
            if let e = err { self.statusText = e }
        }
    }

    // MARK: - 计时器

    private func startTicker() {
        stopTicker()
        startedAt = Date()
        elapsed = 0
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let t0 = self.startedAt else { return }
            self.elapsed = Date().timeIntervalSince(t0)
        }
        RunLoop.main.add(t, forMode: .common)   // 手指还在滑页面时也别停
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        startedAt = nil
    }

    /// 「1 分 20 秒」这种给人看的时间
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) 秒" }
        return "\(s / 60) 分 \(s % 60) 秒"
    }

    // MARK: - 降噪

    /// 高通切掉低频轰鸣（空调、风声、手持震动），再做向下扩展把持续底噪压下去。
    /// 全程走系统音频单元，不手写 DSP，不会因为系数错导致变调或爆音。
    private func denoise(asset: AVAsset,
                         to out: URL,
                         onProgress: @escaping (Double) -> Void) throws {
        guard let aTrack = asset.tracks(withMediaType: .audio).first else {
            throw Fail(msg: "这个视频没有声音")
        }

        let sr = 44100.0
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1
        ]
        let trackOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: settings)
        trackOut.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOut) else { throw Fail(msg: "读不了音轨") }
        reader.add(trackOut)
        guard reader.startReading() else { throw Fail(msg: "读音轨失败") }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else {
            throw Fail(msg: "音频格式不支持")
        }

        // 先把 PCM 全部读进内存。短视频够用，超过 5 分钟的视频在上面已经拦掉了
        var chunks: [AVAudioPCMBuffer] = []
        var totalFrames: AVAudioFrameCount = 0
        while let sb = trackOut.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb)
            let frames = len / 4
            if frames <= 0 { continue }
            guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(frames)) else { continue }
            let ptr = UnsafeMutablePointer<Int8>.allocate(capacity: len)
            defer { ptr.deallocate() }
            let st = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: ptr)
            if st != noErr { continue }
            memcpy(buf.floatChannelData![0], ptr, len)
            buf.frameLength = AVAudioFrameCount(frames)
            chunks.append(buf)
            totalFrames += AVAudioFrameCount(frames)
        }
        if totalFrames == 0 { throw Fail(msg: "音轨是空的") }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        // AVFoundation 里**没有** AVAudioUnitDynamicsProcessor 这个类（第一次编译就栽在这），
        // 动态处理器只能按 AudioComponent 描述去要，参数也走 AudioUnitSetParameter。
        let dynDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let dyn = AVAudioUnitEffect(audioComponentDescription: dynDesc)

        engine.attach(player)
        engine.attach(eq)
        engine.attach(dyn)
        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: dyn, format: format)
        engine.connect(dyn, to: engine.mainMixerNode, format: format)

        try engine.enableManualRenderingMode(.offline,
                                             format: format,
                                             maximumFrameCount: 4096)

        eq.bands[0].filterType = .highPass
        eq.bands[0].frequency = 95
        eq.bands[0].bandwidth = 0.5
        eq.bands[0].bypass = false

        // 阈值以下继续往下压，等于一个温和的噪声门。
        // 注意单位：threshold/headRoom/expansionThreshold/masterGain 是 dB，
        // expansionRatio 是倍数，attack/release 是秒。
        Self.param(dyn, kDynamicsProcessorParam_Threshold, -22)
        Self.param(dyn, kDynamicsProcessorParam_HeadRoom, 0.5)
        Self.param(dyn, kDynamicsProcessorParam_ExpansionRatio, 2.8)
        Self.param(dyn, kDynamicsProcessorParam_ExpansionThreshold, -46)
        Self.param(dyn, kDynamicsProcessorParam_AttackTime, 0.002)
        Self.param(dyn, kDynamicsProcessorParam_ReleaseTime, 0.06)
        Self.param(dyn, kDynamicsProcessorParam_OverallGain, 1.5)

        let file = try AVAudioFile(forWriting: out, settings: format.settings)

        engine.prepare()
        try engine.start()
        player.play()
        for c in chunks {
            player.scheduleBuffer(c, at: nil, options: [], completionHandler: nil)
        }

        guard let rbuf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                          frameCapacity: 4096) else {
            throw Fail(msg: "渲染缓冲建不起来")
        }

        var done: AVAudioFrameCount = 0
        while done < totalFrames {
            let want = min(4096, totalFrames - done)
            let st = try engine.renderOffline(want, to: rbuf)
            switch st {
            case .success:
                if rbuf.frameLength == 0 { break }
                try file.write(from: rbuf)
                done += rbuf.frameLength
                onProgress(Double(done) / Double(totalFrames))
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            default:
                done = totalFrames
            }
        }
        engine.stop()
        return
    }

    // MARK: - 字幕识别
    //
    // 老版本这里是「把视频 URL 直接丢给 SFSpeechURLRecognitionRequest」，两个硬坑：
    //
    //   1. 它要的是**音频文件**。拿 .mp4 喂进去，多数机型直接报
    //      kAFAssistantErrorDomain 1101（甚至 0 条结果但不报错），
    //      现象就是「识别了半天，画面里一个字都没有」。
    //   2. 单次请求大概只吃得下 1 分钟音频。四分钟的口播整段喂进去，
    //      后面三分钟直接丢，长片几乎必然没字幕。
    //
    // 现在改成：抽 16k 单声道 WAV（顺手做峰值归一化）→ 按 45 秒切段 →
    // 本地、联网各识别一遍 → 谁的覆盖好就用谁 → 合并去重。
    // 任何一段失败都不影响别的段。

    private func transcribe(_ asset: AVAsset, limit: Double) throws -> [SubtitleCue] {
        try Self.ensureSpeechAuth()

        let loc = Locale(identifier: "zh-CN")
        guard let rec = SFSpeechRecognizer(locale: loc) else {
            throw Fail(msg: "这台设备不支持中文识别")
        }
        guard rec.isAvailable else {
            throw Fail(msg: "语音识别暂时不可用（可能是没网，或系统还没下好中文包）")
        }

        let wav = Self.temp("speech.wav")
        DispatchQueue.main.async { self.statusText = "抽取音轨…" }
        let audioLen = try extractAudio(asset, to: wav)
        guard audioLen > 0.3 else { throw Fail(msg: "音轨太短，没得识别") }

        DispatchQueue.main.async { self.statusText = "切分段…" }
        let parts = try splitWAV(wav, chunkSeconds: 45)
        try? FileManager.default.removeItem(at: wav)
        guard !parts.isEmpty else { throw Fail(msg: "音频切不出来") }
        Diag.note("字幕：音频 \(String(format: "%.1f", audioLen))s，切成 \(parts.count) 段")

        // 本地识别快、离线能用，但真实机器上出现过「开头好几秒在说话它却不出字」；
        // 联网识别更跟手，可是没网就没辙。所以两遍都跑，谁的覆盖好就用谁。
        var passes: [(name: String, onDevice: Bool)] = []
        if rec.supportsOnDeviceRecognition { passes.append(("本地", true)) }
        passes.append(("联网", false))

        var best: [SubtitleCue] = []
        var bestName = ""
        var lastErr: Error?

        for (idx, p) in passes.enumerated() {
            let base = 0.48 + 0.22 * Double(idx) / Double(passes.count)
            let span = 0.22 / Double(passes.count)
            let (cues, ok, err) = runPass(parts, rec: rec, onDevice: p.onDevice,
                                          passIndex: idx, passTotal: passes.count,
                                          progressBase: base, progressSpan: span)
            if ok == 0 {
                lastErr = err
                Diag.note("字幕：\(p.name)识别整轮失败 \(err?.localizedDescription ?? "-")")
                continue
            }
            let merged = Self.sanitize(cues, limit: limit)
            Diag.note("字幕：\(p.name)成功 \(ok)/\(parts.count) 段，合并 \(merged.count) 条，"
                      + "覆盖到 \(String(format: "%.1f", merged.last?.end ?? 0))s，"
                      + "首条从 \(String(format: "%.1f", merged.first?.start ?? -1))s 开始")
            if Self.score(merged) > Self.score(best) {
                best = merged
                bestName = p.name
            }
        }

        for piece in parts { try? FileManager.default.removeItem(at: piece.url) }

        if best.isEmpty {
            throw Fail(msg: lastErr?.localizedDescription ?? "没识别到字幕")
        }
        Diag.note("字幕：采用\(bestName)结果，共 \(best.count) 条")
        return best
    }

    /// 谁的覆盖更全就听谁的：字多者优先，开头更早的加分。
    /// 开头漏几秒，一般就是少十几二十个字，字数这一项就能比出来。
    private static func score(_ cues: [SubtitleCue]) -> Int {
        guard !cues.isEmpty else { return 0 }
        let chars = cues.reduce(0) { $0 + $1.text.count }
        let early = max(0, 30 - Int(cues[0].start)) * 2
        return chars + early
    }

    /// 完整跑一遍所有段。哪一段失败不影响别的段，返回成功段数和最后一个错误。
    private func runPass(_ parts: [Piece],
                         rec: SFSpeechRecognizer,
                         onDevice: Bool,
                         passIndex: Int,
                         passTotal: Int,
                         progressBase: Double,
                         progressSpan: Double) -> (cues: [SubtitleCue], ok: Int, err: Error?) {
        var cues: [SubtitleCue] = []
        var ok = 0
        var lastErr: Error?

        let t0 = Date()
        let tag = onDevice ? "本机识别" : "联网识别"
        let passInfo = passTotal > 1 ? "\(tag)（第 \(passIndex + 1)/\(passTotal) 遍）" : tag

        for (i, p) in parts.enumerated() {
            do {
                let t = try Self.ask(p.url, rec: rec, onDevice: onDevice)
                ok += 1
                cues += Self.buildCues(t).map {
                    SubtitleCue(start: $0.start + p.offset,
                                end: $0.end + p.offset,
                                text: $0.text)
                }
                Diag.note("字幕：\(onDevice ? "本地" : "联网")第 \(i + 1)/\(parts.count) 段 "
                          + "\(t.segments.count) 小节")
            } catch {
                lastErr = error
                Diag.note("字幕：\(onDevice ? "本地" : "联网")第 \(i + 1)/\(parts.count) 段失败 "
                          + "\(error.localizedDescription)")
            }

            let done = Double(i + 1) / Double(parts.count)
            let spent = Date().timeIntervalSince(t0)
            // 按已跑完的段推剩下几段 —— 每段都是独立请求，耗时比较平均，估得还算准
            let remain = done > 0.001 ? spent / done - spent : 0
            DispatchQueue.main.async {
                self.progress = progressBase + progressSpan * done
                var line = "\(passInfo) · \(i + 1)/\(parts.count) 段"
                if remain >= 3 { line += " · 约剩 \(Self.clock(remain))" }
                self.statusText = line
            }
        }
        return (cues, ok, lastErr)
    }

    private static func ask(_ url: URL,
                            rec: SFSpeechRecognizer,
                            onDevice: Bool) throws -> SFTranscription {
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = onDevice
        req.addsPunctuation = true

        let sem = DispatchSemaphore(value: 0)
        var text: SFTranscription?
        var partial: SFTranscription?
        var failed: Error?

        let task = rec.recognitionTask(with: req) { res, err in
            if let r = res {
                if r.isFinal { text = r.bestTranscription } else { partial = r.bestTranscription }
            }
            if let e = err {
                if failed == nil { failed = e }
                sem.signal()
                return
            }
            if res?.isFinal == true { sem.signal() }
        }

        // 45 秒一段，正常几秒就回；卡到 60 秒就是出问题了，别把整条流程拖死
        if sem.wait(timeout: .now() + 60) == .timedOut {
            task.cancel()
        }
        // 收尾没回来但过程中已经吐过字，就用最后那版 —— 有字总比一个字都没有强
        if let t = text, !t.segments.isEmpty { return t }
        if let p = partial, !p.segments.isEmpty { return p }
        throw failed ?? Fail(msg: "这一段没识别出内容")
    }

    /// 从视频里抽 16k 单声道 WAV，并在写盘前做峰值归一化。
    ///
    /// 归一化这一步是给识别器看的：麦克风录出来的片子峰值常常只有 -15dB、
    /// 平均 -35dB，本地识别模型容易把开头较轻的人声当杂音丢掉，
    /// 现象就是「开头好几秒在说话却没有字幕」。抬到 -3dB 左右再喂，稳得多。
    private func extractAudio(_ asset: AVAsset, to out: URL) throws -> Double {
        guard let aTrack = asset.tracks(withMediaType: .audio).first else {
            throw Fail(msg: "这个视频里没有声音，识别不了")
        }
        let sr = 16000.0
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else {
            throw Fail(msg: "音频格式不支持")
        }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1
        ]
        let trackOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: settings)
        trackOut.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOut) else { throw Fail(msg: "读不了音轨") }
        reader.add(trackOut)
        guard reader.startReading() else { throw Fail(msg: "读音轨失败") }

        // 全部读进内存再统一处理。5 分钟的片子也就 20MB，扛得住。
        var samples: [Float] = []
        samples.reserveCapacity(Int(sr) * 300)
        while let sb = trackOut.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb)
            let n = len / 4
            if n <= 0 { continue }
            var tmp = [Float](repeating: 0, count: n)
            let st = tmp.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: base)
            }
            if st == noErr { samples.append(contentsOf: tmp) }
        }

        let secs = Double(samples.count) / sr
        guard secs > 0.3 else { throw Fail(msg: "音轨是空的") }

        // 峰值归一化到 -3dBFS（0.7），最多放大 30dB，免得纯底噪被抬成「伪人声」
        var peak: Float = 0
        for v in samples { let a = abs(v); if a > peak { peak = a } }
        var gain: Float = 1
        if peak > 1e-5 { gain = min(0.7 / peak, 32) }
        if gain > 1.05 {
            for i in samples.indices {
                let v = samples[i] * gain
                samples[i] = max(-1, min(1, v))
            }
            Diag.note("字幕：识别前放大 \(Int((20 * log10(Double(gain))).rounded()))dB，"
                      + "原峰值 \(String(format: "%.1f", 20 * log10(Double(peak))))dB")
        }

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        try? FileManager.default.removeItem(at: out)
        let file = try AVAudioFile(forWriting: out,
                                   settings: fileSettings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)

        let cap = 320_000
        var off = 0
        while off < samples.count {
            let n = min(cap, samples.count - off)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                             frameCapacity: AVAudioFrameCount(n)) else { break }
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress! + off, count: n)
            }
            buf.frameLength = AVAudioFrameCount(n)
            try file.write(from: buf)
            off += n
        }
        return secs
    }

    private struct Piece {
        let url: URL
        let offset: Double
    }

    /// 按固定秒数切开，返回每段文件和它在整条音轨里的起点
    private func splitWAV(_ url: URL, chunkSeconds: Double) throws -> [Piece] {
        let src = try AVAudioFile(forReading: url)
        let pf = src.processingFormat
        let total = src.length
        let per = AVAudioFramePosition(pf.sampleRate * chunkSeconds)
        guard per > 0, total > 0 else { return [] }

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: pf.sampleRate,
            AVNumberOfChannelsKey: pf.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        var out: [Piece] = []
        var pos: AVAudioFramePosition = 0
        var idx = 0
        while pos < total {
            let count = AVAudioFrameCount(min(per, total - pos))
            guard count > 0,
                  let buf = AVAudioPCMBuffer(pcmFormat: pf, frameCapacity: count) else { break }
            src.framePosition = pos
            try src.read(into: buf, frameCount: count)
            if buf.frameLength == 0 { break }

            let piece = Self.temp("speech-\(idx).wav")
            let f = try AVAudioFile(forWriting: piece,
                                    settings: fileSettings,
                                    commonFormat: .pcmFormatFloat32,
                                    interleaved: false)
            try f.write(from: buf)

            out.append(Piece(url: piece, offset: Double(pos) / pf.sampleRate))
            pos += AVAudioFramePosition(count)
            idx += 1
            if idx > 200 { break }
        }
        return out
    }

    /// 合并后统一收拾：排序、去重叠、掐到片长以内。
    /// 不收拾的话分段的接缝处两条字幕会叠在一起，屏幕上就是「一坨字」。
    private static func sanitize(_ cues: [SubtitleCue], limit: Double) -> [SubtitleCue] {
        var out: [SubtitleCue] = []
        for c in cues.sorted(by: { $0.start < $1.start }) {
            let text = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }

            var s = max(0, c.start)
            var e = max(c.end, s + 0.30)
            if let p = out.last {
                if s < p.end { s = p.end + 0.02 }
            }
            if s >= limit - 0.05 { continue }
            if e > limit { e = limit }
            if e - s < 0.12 { continue }
            // 分段接缝处偶尔会把上一句的尾巴再说一遍，一模一样就直接丢掉
            if let p = out.last, p.text == text, s - p.end < 0.6 { continue }
            out.append(SubtitleCue(start: s, end: e, text: text))
        }
        return out
    }

    private static func ensureSpeechAuth() throws {
        var st = SFSpeechRecognizer.authorizationStatus()
        if st == .notDetermined {
            let sem = DispatchSemaphore(value: 0)
            SFSpeechRecognizer.requestAuthorization { _ in sem.signal() }
            _ = sem.wait(timeout: .now() + 15)
            st = SFSpeechRecognizer.authorizationStatus()
        }
        switch st {
        case .authorized:
            return
        case .denied:
            throw Fail(msg: "「语音识别」权限被关了，去 设置 › 提词大师 打开")
        case .restricted:
            throw Fail(msg: "这台设备不允许语音识别")
        default:
            throw Fail(msg: "语音识别没授权")
        }
    }

    private static func buildCues(_ t: SFTranscription) -> [SubtitleCue] {
        var out: [SubtitleCue] = []
        var buf = ""
        var start: Double = 0
        var end: Double = 0
        let stop: Set<Character> = ["。", "！", "？", "，", "；", "、", "：",
                                   ".", "!", "?", ",", ";", ":"]

        func flush() {
            let txt = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            buf = ""
            guard !txt.isEmpty else { return }
            var s = start
            // 和上一条接上，别让两条字幕在同一时刻叠着 —— 叠了就是「一坨字堆在屏幕上」
            if let p = out.last, s < p.end { s = p.end + 0.02 }
            let e = max(end + 0.18, s + 0.25)
            out.append(SubtitleCue(start: s, end: e, text: txt))
        }

        for seg in t.segments {
            if buf.isEmpty { start = seg.timestamp }
            buf += seg.substring
            end = seg.timestamp + seg.duration

            // 一行大概 14 个字；有标点就断开，读起来才跟得上口播的节奏
            let long = buf.count >= 14
            let broken = seg.substring.contains { stop.contains($0) }
            if long || broken {
                flush()
            }
        }
        flush()
        return out
    }

    // MARK: - 合成

    private func compose(asset: AVAsset,
                         vTrack: AVAssetTrack,
                         audio: URL?,
                         cues: [SubtitleCue],
                         keeps: [CMTimeRange],
                         style: SubtitleStyle) throws -> URL {
        let comp = AVMutableComposition()
        let dur = asset.duration
        guard dur.seconds > 0 else { throw Fail(msg: "视频长度不对") }

        // 没检测到气口 / 用户没开 → 整片一段
        let full = CMTimeRange(start: .zero, duration: dur)
        let plan = keeps.isEmpty ? [full] : keeps
        let cutting = !keeps.isEmpty
            && (keeps.count > 1 || abs(keeps[0].duration.seconds - dur.seconds) > 0.05)

        guard let vt = comp.addMutableTrack(withMediaType: .video,
                                            preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Fail(msg: "建不了视频轨")
        }
        vt.preferredTransform = vTrack.preferredTransform

        // 按保留片段逐段拼接：气口就是这么被掐掉的
        var cursor = CMTime.zero
        for k in plan {
            try vt.insertTimeRange(k, of: vTrack, at: cursor)
            cursor = cursor + k.duration
        }
        let total = cursor
        guard total.seconds > 0.2 else { throw Fail(msg: "剪完几乎没有内容了") }

        // 音频：有降噪结果就用降噪的，否则保留原声；同样按片段拼，保持口型同步
        if let a = audio {
            let aAsset = AVURLAsset(url: a)
            if let src = aAsset.tracks(withMediaType: .audio).first,
               let at = comp.addMutableTrack(withMediaType: .audio,
                                             preferredTrackID: kCMPersistentTrackID_Invalid) {
                var c = CMTime.zero
                for k in plan {
                    let left = CMTimeSubtract(aAsset.duration, k.start)
                    let ad = CMTimeMinimum(k.duration, left)
                    if ad.seconds > 0.02 {
                        try? at.insertTimeRange(CMTimeRange(start: k.start, duration: ad),
                                                of: src, at: c)
                    }
                    c = c + k.duration
                }
            }
        } else if let src = asset.tracks(withMediaType: .audio).first,
                  let at = comp.addMutableTrack(withMediaType: .audio,
                                                preferredTrackID: kCMPersistentTrackID_Invalid) {
            var c = CMTime.zero
            for k in plan {
                try? at.insertTimeRange(k, of: src, at: c)
                c = c + k.duration
            }
        }

        // 画面实际尺寸（考虑旋转）
        let tr = vTrack.preferredTransform
        let natural = vTrack.naturalSize
        let rect = CGRect(origin: .zero, size: natural).applying(tr)
        let size = CGSize(width: abs(rect.width), height: abs(rect.height))

        // 剪过之后时间轴变了，字幕要跟着往前挪，否则会整段落错位
        let shown = cutting ? SilenceCut.remap(cues, keeps: plan) : cues

        let out = Self.temp("edit.mp4")
        try? FileManager.default.removeItem(at: out)

        let vc = AVMutableVideoComposition()
        vc.renderSize = size
        vc.frameDuration = CMTime(value: 1, timescale: 30)

        let inst = AVMutableVideoCompositionInstruction()
        inst.timeRange = CMTimeRange(start: .zero, duration: total)
        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: vt)
        li.setTransform(tr, at: .zero)
        inst.layerInstructions = [li]
        vc.instructions = [inst]

        if !shown.isEmpty {
            let parent = CALayer()
            parent.frame = CGRect(origin: .zero, size: size)
            parent.isGeometryFlipped = false

            let video = CALayer()
            video.frame = parent.frame
            parent.addSublayer(video)

            let limit = total.seconds
            var burned = 0
            for c in shown {
                // 掐掉气口后片长变短了，落在片尾之后的字幕不要再画
                guard c.start < limit - 0.05 else { continue }
                let end = min(c.end, limit)
                guard end > c.start else { continue }
                burned += 1
                let img = Self.subtitleImage(c.text, size: size, style: style)
                let layer = CALayer()
                layer.contents = img.cgImage
                layer.contentsGravity = .resize
                // CA 坐标原点在左下，字幕位置就是「底边离底部多远」。
                // 位置调得很高时再夹一下，别让多行字幕顶出画面。
                let y = min(size.height * CGFloat(style.bottomRatio),
                            max(0, size.height - img.size.height - size.height * 0.02))
                layer.frame = CGRect(x: (size.width - img.size.width) / 2,
                                     y: y,
                                     width: img.size.width,
                                     height: img.size.height)
                layer.opacity = 0

                // 淡入 → 常亮 → 淡出，用关键帧把「这条字幕自己的时间段」说清楚。
                // 之前用的是 from=1/to=1 的透明度动画，配合 fillMode=.both，
                // 在动画开始之前也会套用起始值 1 —— 于是整段视频里所有字幕从第 0 秒就全亮着，
                // 屏幕上就是「全部堆在一起」。关键帧第一个值是 0，从源头堵住。
                let a = CAKeyframeAnimation(keyPath: "opacity")
                a.values = [0, 1, 1, 0]
                a.keyTimes = [0, 0.06, 0.94, 1]
                a.beginTime = AVCoreAnimationBeginTimeAtZero + c.start
                a.duration = max(0.30, end - c.start)
                a.fillMode = .both
                a.isRemovedOnCompletion = false
                a.calculationMode = .linear
                layer.add(a, forKey: "sub")

                parent.addSublayer(layer)
            }

            vc.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: video,
                in: parent
            )
            Diag.note("字幕：烧进画面 \(burned) 条，画面 \(Int(size.width))x\(Int(size.height))，"
                      + "\(String(format: "%.1f", limit))s")
        }

        do {
            return try Self.export(comp, vc: vc, to: out)
        } catch {
            // 带字幕导出这条路炸了，也别让用户白拍 —— 退回无字幕成片，把原因带回界面
            guard !shown.isEmpty else { throw error }
            Diag.note("字幕：带字幕导出失败 \(error.localizedDescription)，改导无字幕成片")
            let plain = Self.temp("edit-plain.mp4")
            let url = try Self.export(comp, vc: nil, to: plain)
            DispatchQueue.main.async { self.subtitleDropped = true }
            return url
        }
    }

    private static func export(_ asset: AVAsset, vc: AVVideoComposition?, to out: URL) throws -> URL {
        guard let ex = AVAssetExportSession(asset: asset,
                                            presetName: AVAssetExportPresetHighestQuality) else {
            throw Fail(msg: "导出器起不来")
        }
        ex.outputURL = out
        ex.outputFileType = .mp4
        ex.videoComposition = vc
        ex.shouldOptimizeForNetworkUse = true

        let sem = DispatchSemaphore(value: 0)
        ex.exportAsynchronously { sem.signal() }
        if sem.wait(timeout: .now() + 600) == .timedOut {
            ex.cancelExport()
            throw Fail(msg: "导出超时")
        }
        if ex.status != .completed {
            throw Fail(msg: ex.error?.localizedDescription ?? "导出失败")
        }
        return out
    }

    private static func subtitleImage(_ text: String,
                                      size: CGSize,
                                      style: SubtitleStyle) -> UIImage {
        let fontSize = style.fontSize(width: size.width)
        let font = style.font(width: size.width)
        let maxW = size.width * 0.88

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        para.lineSpacing = fontSize * 0.16

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
            .paragraphStyle: para,
            .strokeColor: UIColor.black.withAlphaComponent(0.62),
            .strokeWidth: -4.0
        ]

        let ns = text as NSString
        let bound = ns.boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                                    attributes: attrs,
                                    context: nil)

        let h = ceil(bound.height) + fontSize * 0.5
        let canvas = CGSize(width: maxW, height: max(10, h))

        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = false

        return UIGraphicsImageRenderer(size: canvas, format: fmt).image { _ in
            ns.draw(with: CGRect(x: 0,
                                 y: fontSize * 0.25,
                                 width: maxW,
                                 height: bound.height),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attrs,
                    context: nil)
        }
    }

    // MARK: - 工具

    /// 给 AudioUnit 设一个参数，失败就算了（不同系统版本参数 id 略有差异，不值得为此中断导出）
    private static func param(_ unit: AVAudioUnit, _ id: AudioUnitParameterID, _ v: Float) {
        AudioUnitSetParameter(unit.audioUnit, id, kAudioUnitScope_Global, 0, v, 0)
    }

    private static func temp(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tidanci-edit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: u)
        return u
    }
}
