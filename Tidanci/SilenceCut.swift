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

    /// 一条音轨的体检结果
    struct AudioStats {
        /// 音轨自身长度（秒）
        var duration: Double = 0
        /// 整条音轨的最大音量
        var peak: Float = -120
        /// 最后一段（默认末尾四分之一）的最大音量。全程峰值看不出来的「录到一半哑了」靠它。
        var tail: Float = -120
        /// 20ms 窗口数，0 表示压根没解出声音
        var windows: Int = 0
    }

    /// 音轨的最大音量（dB）。文件里挂着音轨、但采样全是 0 时，播放一样是没声音，
    /// 光看「有没有音轨」看不出来 —— 所以补音之前要拿它确认一遍。
    ///
    /// v1.14：默认改成扫全程。旧版只扫前 45 秒，四分钟的片子后半段哑了它照样报「正常」，
    /// 于是「这条片子看着没问题」被原样留下 —— 用户听到的就是没声音。
    static func peakDb(_ url: URL, maxSeconds: Double = 0) -> Float {
        stats(url, maxSeconds: maxSeconds).peak
    }

    /// 全程扫一遍，给出「总长度 / 全局峰值 / 尾巴峰值」。
    static func stats(_ url: URL, tailRatio: Double = 0.25, maxSeconds: Double = 0) -> AudioStats {
        let dur = trackDuration(url)
        let scan = levelSeries(url, start: 0,
                               duration: maxSeconds > 0 ? min(maxSeconds, dur) : dur)
        var s = AudioStats(duration: dur, peak: -120, tail: -120, windows: scan.count)
        guard !scan.isEmpty else { return s }
        s.peak = scan.max() ?? -120
        let start = max(0, Int(Double(scan.count) * (1 - tailRatio)))
        s.tail = scan[start...].max() ?? -120
        return s
    }

    /// 抽样式体检：只解「开头 headSeconds 秒 + 末尾 tailRatio」。
    ///
    /// 全程扫一条四分钟的 AAC 音轨，要把整段解码成 PCM，光这一步就要好几秒，
    /// 用户只能盯着「正在整理音轨」干等。可实际上只有两件事要判断：
    /// 整条是不是哑的（听开头就知道），后半段有没有断（听尾巴就知道）。
    /// 备份是未压缩的 WAV，仍然全程扫——它才是「到底有没有录到声音」的证据。
    static func statsSampled(_ url: URL,
                             headSeconds: Double = 12,
                             tailRatio: Double = 0.40) -> AudioStats {
        let dur = trackDuration(url)
        guard dur > 0 else { return AudioStats() }
        let head = levelSeries(url, start: 0, duration: min(headSeconds, dur))
        let tailStart = max(0, dur * (1 - tailRatio))
        // 片子还没 headSeconds 长，或者尾巴已经和开头重叠：扫一次就够了
        let tail: [Float]
        if tailStart <= headSeconds {
            tail = head
        } else {
            tail = levelSeries(url, start: tailStart, duration: dur - tailStart)
        }
        var s = AudioStats(duration: dur, peak: -120, tail: -120,
                           windows: head.count + tail.count)
        s.peak = max(head.max() ?? -120, tail.max() ?? -120)
        s.tail = tail.max() ?? -120
        return s
    }

    /// 音轨长度。直接读元数据，不用解码。
    private static func trackDuration(_ url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        guard let t = asset.tracks(withMediaType: .audio).first else { return 0 }
        return t.timeRange.duration.seconds
    }

    private static func scanLevels(_ url: URL,
                                   maxSeconds: Double = 0)
        -> (levels: [Float], trackDuration: Double) {
        let dur = trackDuration(url)
        let scan = levelSeries(url, start: 0,
                               duration: maxSeconds > 0 ? min(maxSeconds, dur) : dur)
        return (scan, dur)
    }

    /// 解出 [start, start+duration) 这段音频，返回每 20ms 一个的 dB 值
    private static func levelSeries(_ url: URL, start: Double, duration: Double) -> [Float] {
        guard duration > 0.05 else { return [] }
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: duration, preferredTimescale: 600))
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
        return levels
    }

    // MARK: - 检测

    static func detect(_ url: URL,
                       thresholdDb: Float = -38,
                       minSilence: Double = 0.45) throws -> [SilenceGap] {
        let levels = scanLevels(url).levels
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

    /// 合并挨得很近的气口：说话中间换气会被切成两段，分开处理会把字也剪掉。
    /// 弹窗列表也用合并后的结果，这样「看到几处」和「实际剪几处」是同一份数据。
    static func merge(_ gaps: [SilenceGap]) -> [SilenceGap] {
        var merged: [SilenceGap] = []
        for g in gaps.sorted(by: { $0.start < $1.start }) {
            if var last = merged.last, g.start - last.end < 0.18 {
                last.end = max(last.end, g.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(g)
            }
        }
        return merged
    }

    /// 把气口换算成「要保留的片段」。每个气口前后各留 pad 秒，避免把字头字尾咬掉。
    /// 返回空数组 = 不建议剪（没气口、或者素材本来就很干净）。
    ///
    /// - Parameter minKeepRatio: 保留内容低于原片这个比例就放弃剪辑。
    ///   自动剪的时候用 0.4（阈值可能把说话误判成静音，宁可不剪）；
    ///   用户在弹窗里亲手选过之后用 0.15（他自己看过时间点了，尊重选择，但仍留一道保命线）。
    static func keepRanges(duration: Double,
                           gaps: [SilenceGap],
                           pad: Double = 0.12,
                           minKeepRatio: Double = 0.4) -> [CMTimeRange] {
        guard duration > 0.8, !gaps.isEmpty else { return [] }

        let merged = merge(gaps)

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
        if keeps.isEmpty || kept < duration * minKeepRatio { return [] }
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
