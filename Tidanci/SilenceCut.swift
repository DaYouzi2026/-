import Foundation
import AVFoundation

/// 一段气口（静音区间），单位秒
struct SilenceGap {
    var start: Double
    var end: Double
    var length: Double { max(0, end - start) }
}

/// 自动找气口：用系统解码器把音轨解成 PCM，按 20ms 窗口算 RMS 分贝，
/// 连续低于阈值且够长的区间就是「换气的地方」。全程系统 API，不依赖任何外部库。
enum SilenceCut {

    private static let sampleRate = 16000.0
    private static let windowSec = 0.02

    // MARK: - 有没有声音

    /// 音轨的最大音量（dB）。文件里挂着音轨、但采样全是 0 时，播放一样是没声音，
    /// 光看「有没有音轨」看不出来 —— 所以补音之前要拿它确认一遍。
    static func peakDb(_ url: URL, maxSeconds: Double = 45) -> Float {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return -120 }
        reader.timeRange = CMTimeRange(start: .zero,
                                       duration: CMTime(seconds: maxSeconds, preferredTimescale: 600))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
        ]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return -120 }
        reader.add(out)
        guard reader.startReading() else { return -120 }

        let win = Int(sampleRate * windowSec)
        var peak: Float = -120
        var carry: [Float] = []

        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb)
            guard len >= 4 else { continue }
            var data = [Float](repeating: 0, count: len / 4)
            let st = data.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: base)
            }
            guard st == noErr else { continue }
            carry.append(contentsOf: data)
            var i = 0
            while carry.count - i >= win {
                var sum: Float = 0
                for k in i..<(i + win) { sum += carry[k] * carry[k] }
                let rms = (sum / Float(win)).squareRoot()
                peak = max(peak, 20 * log10(max(rms, 1e-7)))
                i += win
            }
            if i > 0 { carry.removeFirst(i) }
        }
        return peak
    }

    // MARK: - 检测

    static func detect(_ url: URL,
                       thresholdDb: Float = -38,
                       minSilence: Double = 0.45) throws -> [SilenceGap] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { return [] }
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
        ]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return [] }
        reader.add(out)
        guard reader.startReading() else { return [] }

        let win = Int(sampleRate * windowSec)
        var levels: [Float] = []
        var carry: [Float] = []
        carry.reserveCapacity(win * 2)

        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb)
            guard len >= 4 else { continue }

            var data = [Float](repeating: 0, count: len / 4)
            let st = data.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: base)
            }
            guard st == noErr else { continue }

            carry.append(contentsOf: data)
            var i = 0
            while carry.count - i >= win {
                var sum: Float = 0
                for k in i..<(i + win) { sum += carry[k] * carry[k] }
                let rms = (sum / Float(win)).squareRoot()
                levels.append(20 * log10(max(rms, 1e-7)))
                i += win
            }
            if i > 0 { carry.removeFirst(i) }
        }

        guard !levels.isEmpty else { return [] }

        var gaps: [SilenceGap] = []
        var runStart: Int?
        for (idx, db) in levels.enumerated() {
            if db < thresholdDb {
                if runStart == nil { runStart = idx }
            } else if let s = runStart {
                gaps.append(gap(s, idx))
                runStart = nil
            }
        }
        if let s = runStart { gaps.append(gap(s, levels.count)) }

        return gaps.filter { $0.length >= minSilence }
    }

    private static func gap(_ from: Int, _ to: Int) -> SilenceGap {
        SilenceGap(start: Double(from) * windowSec,
                   end: Double(to) * windowSec)
    }

    // MARK: - 保留片段

    /// 把气口换算成「要保留的片段」。每个气口前后各留 pad 秒，避免把字头字尾咬掉。
    /// 返回空数组 = 不建议剪（没气口、或者素材本来就很干净）。
    static func keepRanges(duration: Double,
                           gaps: [SilenceGap],
                           pad: Double = 0.12) -> [CMTimeRange] {
        guard duration > 0.8, !gaps.isEmpty else { return [] }

        // 合并挨得很近的气口：说话中间换气会被切成两段，分开处理会把字也剪掉
        var merged: [SilenceGap] = []
        for g in gaps.sorted(by: { $0.start < $1.start }) {
            if var last = merged.last, g.start - last.end < 0.18 {
                last.end = max(last.end, g.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(g)
            }
        }

        var keeps: [CMTimeRange] = []
        var cursor = 0.0
        for g in merged {
            let s = g.start + pad          // 保留到这儿为止
            let e = g.end - pad            // 下一段从这儿开始
            if s - cursor > 0.20 { keeps.append(range(cursor, s)) }
            cursor = max(cursor, e)
        }
        if duration - cursor > 0.20 { keeps.append(range(cursor, duration)) }

        let kept = keeps.reduce(0.0) { $0 + $1.duration.seconds }
        // 剪掉太多说明阈值把说话也当静音了，宁可不动
        if keeps.isEmpty || kept < duration * 0.4 { return [] }
        return keeps
    }

    /// 一步到位：检测 + 出保留片段。返回空表示「不用剪」。
    static func plan(_ url: URL,
                     thresholdDb: Float = -38,
                     minSilence: Double = 0.45) -> [CMTimeRange] {
        let asset = AVURLAsset(url: url)
        let dur = asset.duration.seconds
        guard dur > 0 else { return [] }
        let gaps = (try? detect(url, thresholdDb: thresholdDb, minSilence: minSilence)) ?? []
        return keepRanges(duration: dur, gaps: gaps)
    }

    // MARK: - 时间轴重映射

    /// 剪掉气口后，原来的第 t 秒落在成片的哪一秒。
    /// 返回 nil 表示这一秒所在的整段被剪掉了（那儿的字幕不该再出现）。
    static func map(_ t: Double, keeps: [CMTimeRange]) -> Double? {
        var acc = 0.0
        for k in keeps {
            let s = k.start.seconds
            let e = CMTimeRangeGetEnd(k).seconds
            if t < s { return nil }
            if t <= e { return acc + (t - s) }
            acc += (e - s)
        }
        return nil
    }

    /// 字幕跟着重新排队：跨过被剪掉的气口之后，后面的字幕要往前挪
    static func remap(_ cues: [SubtitleCue], keeps: [CMTimeRange]) -> [SubtitleCue] {
        guard !keeps.isEmpty else { return cues }
        var out: [SubtitleCue] = []
        var acc = 0.0
        for k in keeps {
            let ks = k.start.seconds
            let ke = CMTimeRangeGetEnd(k).seconds
            for c in cues {
                let s = max(c.start, ks)
                let e = min(c.end, ke)
                if e - s < 0.10 { continue }
                out.append(SubtitleCue(start: acc + (s - ks),
                                       end: acc + (e - ks),
                                       text: c.text))
            }
            acc += (ke - ks)
        }
        return out
    }

    private static func range(_ s: Double, _ e: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: max(0, s), preferredTimescale: 600),
                    duration: CMTime(seconds: max(0, e - s), preferredTimescale: 600))
    }
}
