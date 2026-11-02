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

    private let workQ = DispatchQueue(label: "video.editor", qos: .userInitiated)

    struct Fail: LocalizedError {
        let msg: String
        var errorDescription: String? { msg }
    }

    // MARK: - 入口

    func run(input: URL,
             denoise: Bool,
             subtitle: Bool,
             completion: @escaping (URL?, String?) -> Void) {
        guard !running else { return }
        running = true
        progress = 0
        stage = .preparing
        statusText = "读视频…"

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

            // 2) 字幕
            var cues: [SubtitleCue] = []
            if subtitle {
                DispatchQueue.main.async {
                    self.stage = .transcribe
                    self.statusText = "识别字幕…"
                    self.progress = 0.45
                }
                do {
                    cues = try self.transcribe(newAudio ?? input)
                } catch {
                    notes.append("字幕没识别出来")
                }
            }

            // 3) 合成
            DispatchQueue.main.async {
                self.stage = .render
                self.statusText = "合成中…"
                self.progress = 0.72
            }
            do {
                let out = try self.compose(asset: asset,
                                           vTrack: vTrack,
                                           audio: newAudio,
                                           cues: cues)
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
            self.running = false
            if let e = err { self.statusText = e }
        }
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

    private func transcribe(_ url: URL) throws -> [SubtitleCue] {
        let loc = Locale(identifier: "zh-CN")
        guard let rec = SFSpeechRecognizer(locale: loc) else {
            throw Fail(msg: "这台设备不支持中文识别")
        }
        guard rec.isAvailable else {
            throw Fail(msg: "语音识别暂时不可用")
        }

        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        if rec.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }

        let sem = DispatchSemaphore(value: 0)
        var cues: [SubtitleCue] = []
        var failed: Error?

        rec.recognitionTask(with: req) { res, err in
            if let e = err {
                failed = e
                sem.signal()
                return
            }
            guard let r = res, r.isFinal else { return }
            cues = Self.buildCues(r.bestTranscription)
            sem.signal()
        }

        _ = sem.wait(timeout: .now() + 240)
        if let e = failed, cues.isEmpty { throw e }
        if cues.isEmpty { throw Fail(msg: "没识别到字幕") }
        return cues
    }

    private static func buildCues(_ t: SFTranscription) -> [SubtitleCue] {
        var out: [SubtitleCue] = []
        var buf = ""
        var start: Double = 0
        var end: Double = 0
        let stop: Set<Character> = ["。", "！", "？", "，", "；", ".", "!", "?", ",", ";"]

        for seg in t.segments {
            if buf.isEmpty { start = seg.timestamp }
            buf += seg.substring
            end = seg.timestamp + seg.duration

            let long = buf.count >= 16
            let broken = seg.substring.contains { stop.contains($0) }
            if long || broken {
                let txt = buf.trimmingCharacters(in: .whitespacesAndNewlines)
                if !txt.isEmpty {
                    out.append(SubtitleCue(start: start, end: end + 0.20, text: txt))
                }
                buf = ""
            }
        }
        if !buf.isEmpty {
            out.append(SubtitleCue(start: start, end: end + 0.20, text: buf))
        }
        return out
    }

    // MARK: - 合成

    private func compose(asset: AVAsset,
                         vTrack: AVAssetTrack,
                         audio: URL?,
                         cues: [SubtitleCue]) throws -> URL {
        let comp = AVMutableComposition()
        let dur = asset.duration
        guard dur.seconds > 0 else { throw Fail(msg: "视频长度不对") }

        guard let vt = comp.addMutableTrack(withMediaType: .video,
                                            preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Fail(msg: "建不了视频轨")
        }
        try vt.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: vTrack, at: .zero)
        vt.preferredTransform = vTrack.preferredTransform

        // 音频：有降噪结果就用降噪的，否则保留原声
        if let a = audio {
            let aAsset = AVURLAsset(url: a)
            if let src = aAsset.tracks(withMediaType: .audio).first,
               let at = comp.addMutableTrack(withMediaType: .audio,
                                             preferredTrackID: kCMPersistentTrackID_Invalid) {
                let ad = min(aAsset.duration, dur)
                try? at.insertTimeRange(CMTimeRange(start: .zero, duration: ad),
                                        of: src,
                                        at: .zero)
            }
        } else if let src = asset.tracks(withMediaType: .audio).first,
                  let at = comp.addMutableTrack(withMediaType: .audio,
                                                preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? at.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: src, at: .zero)
        }

        // 画面实际尺寸（考虑旋转）
        let tr = vTrack.preferredTransform
        let natural = vTrack.naturalSize
        let rect = CGRect(origin: .zero, size: natural).applying(tr)
        let size = CGSize(width: abs(rect.width), height: abs(rect.height))

        let out = Self.temp("edit.mp4")
        try? FileManager.default.removeItem(at: out)

        let vc = AVMutableVideoComposition()
        vc.renderSize = size
        vc.frameDuration = CMTime(value: 1, timescale: 30)

        let inst = AVMutableVideoCompositionInstruction()
        inst.timeRange = CMTimeRange(start: .zero, duration: dur)
        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: vt)
        li.setTransform(tr, at: .zero)
        inst.layerInstructions = [li]
        vc.instructions = [inst]

        if !cues.isEmpty {
            let parent = CALayer()
            parent.frame = CGRect(origin: .zero, size: size)
            parent.isGeometryFlipped = false

            let video = CALayer()
            video.frame = parent.frame
            parent.addSublayer(video)

            for c in cues {
                guard c.end > c.start else { continue }
                let text = Self.subtitleImage(c.text, size: size)
                let layer = CALayer()
                layer.contents = text.cgImage
                layer.contentsGravity = .resize
                // CA 坐标原点在左下，字幕要贴底部，所以 y 取小值
                let h = text.size.height
                layer.frame = CGRect(x: 0,
                                     y: size.height * 0.07,
                                     width: size.width,
                                     height: h)

                let anim = CABasicAnimation(keyPath: "opacity")
                anim.fromValue = 1
                anim.toValue = 1
                anim.beginTime = AVCoreAnimationBeginTimeAtZero + c.start
                anim.duration = max(0.15, c.end - c.start)
                anim.isRemovedOnCompletion = false
                anim.fillMode = .both
                layer.opacity = 0
                layer.add(anim, forKey: "show")

                parent.addSublayer(layer)
            }

            vc.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: video,
                in: parent
            )
        }

        guard let ex = AVAssetExportSession(asset: comp,
                                            presetName: AVAssetExportPresetHighestQuality) else {
            throw Fail(msg: "导出器起不来")
        }
        ex.outputURL = out
        ex.outputFileType = .mp4
        ex.videoComposition = vc
        ex.shouldOptimizeForNetworkUse = true

        let sem = DispatchSemaphore(value: 0)
        ex.exportAsynchronously { sem.signal() }
        _ = sem.wait(timeout: .now() + 600)

        if ex.status != .completed {
            throw Fail(msg: ex.error?.localizedDescription ?? "导出失败")
        }
        return out
    }

    private static func subtitleImage(_ text: String, size: CGSize) -> UIImage {
        let fontSize = max(15, size.width * 0.050)
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let maxW = size.width * 0.86

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
