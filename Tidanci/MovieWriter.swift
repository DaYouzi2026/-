import Foundation
import AVFoundation
import CoreMedia

/// 单一写入器：视频帧和音频帧按**同一个采集时钟的 PTS** 交错写进一个 mp4。
///
/// ── 为什么换成这个（v1.27）──────────────────────────────────────────────
/// 之前 native 用 `AVCaptureMovieFileOutput` 写画面，声音另走 `audioOut` 存 PCM，
/// 停录后再 WAV→AAC→整片重封装→二次自检。那段流水线要全量解码 + 整片重写，
/// 4 分钟的片子要 5 分钟才存完，而且音画对齐靠估算 offset。
///
/// 系统相机、FiLMiC Pro、抖音/剪映的拍摄、市面上的提词器走的都是这一条：
/// 一个 `AVCaptureSession` → 一个 `AVAssetWriter`，音视频从采集出来的那一刻起
/// 就带着同一时基的时间戳，按时间先后插进同一个文件。
/// **停录 = finishWriting，成片立刻可用**：没有 mux、没有转码、没有 offset。
///
/// ── 关键设计 ────────────────────────────────────────────────────────
/// * 写入器**惰性创建**：等第一帧视频到了才知道真实分辨率（旋转后的），
///   也才知道音频流格式。之前硬编码的宽高在竖屏旋转后会错，这里不会。
/// * 音频比视频先到时先缓存（几百 KB），建好写入器再补进去，不丢开头的声音。
/// * 音频流格式中途变了（插拔蓝牙耳机最典型）用 `AudioBridge` 转成写入器
///   期待的那一档，**绝不让格式突变把整段录制写废**。
/// * 视频用 H.264（4K60 用 HEVC，和系统相机同策略），硬件编码，实时写盘。
final class MovieWriter {

    /// 给诊断用的写入情况
    struct Stats {
        var videoFrames = 0
        var audioFrames = 0
        var droppedVideo = 0
        var droppedAudio = 0
        var audioSeconds: Double = 0
        var formatWarned = false
    }

    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var startAt = CMTime.invalid
    /// 写入器还没建好时先到的音频帧（最多 240 帧 ≈ 5 秒）
    private var pending: [CMSampleBuffer] = []
    private var armedURL: URL?
    private var rate: Double = 48000
    private var channels = 1
    private var fpsHint = 30
    private var stats = Stats()
    private(set) var url: URL?

    /// 已经 startWriting 且还在写
    var isWriting: Bool {
        lock.lock(); defer { lock.unlock() }
        return writer?.status == .writing
    }

    /// 备好了目标文件，但还没等到第一帧视频
    var isArmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return armedURL != nil
    }

    var snapshot: Stats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    // MARK: - 开录

    /// 备好目标文件。真正的 writer 要等第一帧视频（才知道分辨率）。
    func arm(url: URL, sampleRate: Double, channels: Int, fps: Int) {
        lock.lock(); defer { lock.unlock() }
        writer?.cancelWriting()
        writer = nil
        videoIn = nil
        audioIn = nil
        startAt = .invalid
        pending.removeAll()
        try? FileManager.default.removeItem(at: url)
        armedURL = url
        self.url = url
        self.rate = sampleRate > 8000 ? sampleRate : 48000
        self.channels = (channels >= 1 && channels <= 2) ? channels : 1
        self.fpsHint = fps > 0 ? fps : 30
        stats = Stats()
    }

    // MARK: - 写帧

    func appendVideo(_ sb: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard pts.isValid, pts.isNumeric else { return }

        lock.lock(); defer { lock.unlock() }

        if writer == nil {
            guard armedURL != nil else { return }
            guard buildLocked(first: sb, pts: pts) else { return }
        }
        guard let w = writer, w.status == .writing, let vi = videoIn else { return }
        guard vi.isReadyForMoreMediaData else {
            stats.droppedVideo += 1
            return
        }
        if vi.append(sb) {
            stats.videoFrames += 1
        } else {
            stats.droppedVideo += 1
        }
    }

    func appendAudio(_ sb: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard writer != nil else {
            guard armedURL != nil else { return }
            if pending.count < 240 { pending.append(sb) }
            return
        }
        _ = appendAudioLocked(sb)
    }

    // MARK: - 收尾

    /// 停录即调用。回调在主线程，第二个参数是「这条有没有音轨」。
    func finish(_ done: @escaping (URL?, Bool) -> Void) {
        lock.lock()
        guard let w = writer else {
            // 一帧视频都没写进来，文件不存在或不可用
            writer?.cancelWriting()
            writer = nil
            videoIn = nil
            audioIn = nil
            pending.removeAll()
            armedURL = nil
            lock.unlock()
            DispatchQueue.main.async { done(nil, false) }
            return
        }
        let out = url
        let s = stats
        writer = nil
        videoIn = nil
        audioIn = nil
        pending.removeAll()
        armedURL = nil
        lock.unlock()

        // 没有一帧音频就不要交一个空音轨的文件出去 —— 让上层如实告诉用户
        let hasAudio = s.audioFrames > 0
        if !hasAudio, let ai = w.inputs.first(where: { $0.mediaType == .audio }) {
            ai.markAsFinished()
        }

        w.finishWriting {
            let ok = (w.status == .completed) && (w.error == nil)
            if !ok {
                Diag.note("写入器：收尾失败 \(w.error?.localizedDescription ?? "-")")
            }
            Diag.note(String(format: "写入器：画面 %d 帧 / 声音 %d 帧=%.1fs，丢弃 v%d/a%d，%s",
                              s.videoFrames, s.audioFrames, s.audioSeconds,
                              s.droppedVideo, s.droppedAudio,
                              ok ? (hasAudio ? "成片可用" : "⚠️ 没有音轨") : "失败"))
            DispatchQueue.main.async { done(ok ? out : nil, hasAudio) }
        }
    }

    /// 异常路径（开录失败、页面被关掉）直接把文件扔掉
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        writer?.cancelWriting()
        writer = nil
        videoIn = nil
        audioIn = nil
        startAt = .invalid
        pending.removeAll()
        armedURL = nil
    }

    // MARK: - 内部

    private func buildLocked(first sb: CMSampleBuffer, pts: CMTime) -> Bool {
        guard let out = armedURL, let fd = CMSampleBufferGetFormatDescription(sb) else { return false }
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        guard dims.width > 0, dims.height > 0 else { return false }

        guard let w = try? AVAssetWriter(outputURL: out, fileType: .mp4) else {
            Diag.note("写入器：文件建不起来 \(out.lastPathComponent)")
            armedURL = nil
            return false
        }

        let vi = AVAssetWriterInput(mediaType: .video,
                                   outputSettings: Self.videoSettings(width: Int(dims.width),
                                                                      height: Int(dims.height),
                                                                      fps: fpsHint))
        vi.expectsMediaDataInRealTime = true

        let asettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels > 1 ? 192_000 : 128_000
        ]
        let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: asettings)
        ai.expectsMediaDataInRealTime = true

        guard w.canAdd(vi), w.canAdd(ai) else {
            Diag.note("写入器：装不下这两条轨")
            armedURL = nil
            return false
        }
        w.add(vi)
        w.add(ai)
        guard w.startWriting() else {
            Diag.note("写入器：startWriting 失败 \(w.error?.localizedDescription ?? "-")")
            armedURL = nil
            return false
        }

        // 时间轴起点取「第一帧视频」和「已缓存的第一帧音频」里更早的那个，
        // 这样开头几十毫秒的声音不会因为视频晚到而被丢掉。
        var startTime = pts
        if let a = pending.first {
            let ap = CMSampleBufferGetPresentationTimeStamp(a)
            if ap.isValid, ap.isNumeric, CMTimeCompare(ap, startTime) < 0 {
                startTime = ap
            }
        }
        w.startSession(atSourceTime: startTime)

        writer = w
        videoIn = vi
        audioIn = ai
        startAt = startTime

        // 先到的音频补进去（只补时间不早于起始时间的）
        for a in pending {
            _ = appendAudioLocked(a)
        }
        pending.removeAll()

        Diag.note("写入器：\(Int(dims.width))×\(Int(dims.height)) 音频 \(Int(rate))Hz/\(channels)ch 已开写")
        return true
    }

    private func appendAudioLocked(_ sb: CMSampleBuffer) -> Bool {
        guard let w = writer, w.status == .writing, let ai = audioIn else { return false }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard pts.isValid, pts.isNumeric, CMTimeCompare(pts, startAt) >= 0 else {
            stats.droppedAudio += 1
            return false
        }

        var buf = sb
        if !AudioBridge.matches(sb, rate: rate, channels: channels) {
            guard let c = AudioBridge.convert(sb, to: rate, channels: channels) else {
                stats.droppedAudio += 1
                return false
            }
            buf = c
            if !stats.formatWarned {
                stats.formatWarned = true
                Diag.note("音轨：输入格式变了，已转成 \(Int(rate))Hz/\(channels)ch 继续写")
            }
        }

        guard ai.isReadyForMoreMediaData else {
            stats.droppedAudio += 1
            return false
        }
        guard ai.append(buf) else {
            stats.droppedAudio += 1
            if !stats.formatWarned {
                stats.formatWarned = true
                Diag.note("音轨：写入被拒 \(w.error?.localizedDescription ?? "-")")
            }
            return false
        }
        stats.audioFrames += 1
        let sec = CMTimeGetSeconds(CMTimeSubtract(pts, startAt))
        if sec.isFinite, sec + 0.05 > stats.audioSeconds { stats.audioSeconds = sec }
        return true
    }

    /// 码率按分辨率×帧率给，4K60 用 HEVC（和系统相机一致），其余 H.264。
    private static func videoSettings(width: Int, height: Int, fps: Int) -> [String: Any] {
        let pixels = Double(width) * Double(height)
        // 码率和系统相机同档：4K30 ≈ 50Mbps，1080P30 ≈ 12Mbps
        let bpp: Double = fps >= 50 ? 8.0 : 6.0
        let bitrate = Int(min(max(pixels * bpp, 6_000_000), 200_000_000))
        let heavy = pixels >= 3840.0 * 2160.0 * 0.9 && fps >= 50

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoMaxKeyFrameIntervalKey: max(fps * 2, 30),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoAllowFrameReorderingKey: true
        ]
        if !heavy {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        return [
            AVVideoCodecKey: heavy ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]
    }
}

// MARK: - 音频格式桥

/// 写入器建好以后音频流的采样率/声道就定死了，中途插蓝牙耳机（16k）会让后续帧
/// 格式对不上。这里把它转成写入器那一档，保证声音不断。
enum AudioBridge {

    static func matches(_ sb: CMSampleBuffer, rate: Double, channels: Int) -> Bool {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return false }
        let r = asbd.pointee.mSampleRate
        let c = Int(asbd.pointee.mChannelsPerFrame)
        return abs(r - rate) < 1 && c == channels
    }

    static func convert(_ sb: CMSampleBuffer, to rate: Double, channels: Int) -> CMSampleBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd),
              let inFmt = AVAudioFormat(streamDescription: asbd) else { return nil }

        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return nil }
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        inBuf.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0,
                                                          frameCount: Int32(frames),
                                                          into: inBuf.mutableAudioBufferList) == noErr else { return nil }

        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: rate,
                                         channels: AVAudioChannelCount(channels),
                                         interleaved: true),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { return nil }

        let cap = AVAudioFrameCount(Double(frames) * rate / max(inFmt.sampleRate, 1)) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return nil }

        var err: NSError?
        var fed = false
        let input: AVAudioConverterInputBlock = { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        let rc = conv.convert(to: outBuf, error: &err, withInputFrom: input)
        guard rc != .error, outBuf.frameLength > 0 else { return nil }

        return makeSampleBuffer(outBuf, pts: CMSampleBufferGetPresentationTimeStamp(sb))
    }

    /// 交错 float32 的 PCM 包成 CMSampleBuffer（只有一路 buffer，打包最简单）
    private static func makeSampleBuffer(_ buf: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
        var asbd = buf.format.streamDescription.pointee
        var fdesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                             asbd: &asbd,
                                             layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &fdesc) == noErr,
              let fdesc else { return nil }

        let abl = buf.audioBufferList
        guard let data = abl.pointee.mBuffers.mData, abl.pointee.mBuffers.mDataByteSize > 0 else { return nil }
        let bytes = Int(abl.pointee.mBuffers.mDataByteSize)

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: nil,
                                                 blockLength: bytes,
                                                 blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil,
                                                 offsetToData: 0,
                                                 dataLength: bytes,
                                                 flags: 0,
                                                 blockBufferOut: &block) == noErr,
              let blk = block else { return nil }

        guard CMBlockBufferReplaceDataBytes(with: data,
                                            blockBuffer: blk,
                                            offsetIntoDestination: 0,
                                            dataLength: bytes) == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(buf.frameLength),
                             timescale: CMTimeScale(max(asbd.mSampleRate, 8000))),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)

        var out: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                        dataBuffer: blk,
                                        formatDescription: fdesc,
                                        sampleCount: CMItemCount(buf.frameLength),
                                        sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 0,
                                        sampleSizeArray: nil,
                                        sampleBufferOut: &out) == noErr else { return nil }
        return out
    }
}
