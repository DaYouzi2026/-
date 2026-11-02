import Foundation
import AVFoundation
import CoreVideo
import Combine
import UIKit
import SwiftUI
import ImageIO

/// 相机 + 录制。两条通路：
///
/// * 原相机（native）：AVCaptureMovieFileOutput 直接落盘，能 4K/60fps，画质最高。
/// * 经典美颜（beauty）：AVCaptureVideoDataOutput → Core Image 美颜 → AVAssetWriter 落盘，
///   预览走 AVSampleBufferDisplayLayer。这条路走 GPU，1080P 封顶。
///
/// 两条路共用一路音频：既喂语音识别，也喂录制。
final class CameraRecorder: NSObject, ObservableObject {

    enum Mode: String {
        case native
        case beauty

        var title: String {
            self == .native ? "原相机" : "经典美颜"
        }
    }

    let session = AVCaptureSession()

    private let movieOut = AVCaptureMovieFileOutput()
    private let videoOut = AVCaptureVideoDataOutput()
    private let audioOut = AVCaptureAudioDataOutput()
    private let writer = BeautyWriter()

    private var videoIn: AVCaptureDeviceInput?
    private var audioIn: AVCaptureDeviceInput?

    private let cfgQ = DispatchQueue(label: "tidanci.cam.config")
    private let videoQ = DispatchQueue(label: "tidanci.cam.video")
    private let audioQ = DispatchQueue(label: "tidanci.cam.audio")

    // 只在 cfgQ 上读写
    private var frontFlag = true
    private var modeFlag: Mode = .native
    private var quality: VideoQuality = .uhd
    private var fps = 30
    private var needRotate = false
    /// 前置录制是否镜像。默认开：取景框是镜面，成片也镜面，两边才对得上
    private var mirrorSaveFlag = true

    // 只在 videoQ 上读写
    private var recordingFlag = false
    private var pendingURL: URL?
    private var writerReady = false
    private var previewPool: CVPixelBufferPool?
    private var previewDims = CGSize.zero
    private var audioRate: Double = 44100
    private var audioChannels = 1

    // 只在 audioQ 上读写
    /// 录制期间把麦克风 PCM 另存一份。相机这条路万一没把音轨写进文件（首次启动最容易），
    /// 用它把声音补回去 —— 「第一条视频没声音」不能再靠时序侥幸。
    ///
    /// 这里手写 WAV，不用 AVAudioFile：`AVAudioFile(forWriting:settings:)` 在格式
    /// （采样率/声道/是否交错）对不上时会抛 Objective-C 异常，Swift 的 try 抓不住，
    /// 直接闪退。自己拼 44 字节头 + 追加 Int16，永远不会有异常。
    private var backupURL: URL?
    private var backupHandle: FileHandle?
    private var backupFrames = 0
    private var backupRate: Double = 48000
    private var backupChannels = 1
    private var backupOn = false
    private var offsetFixed = false
    private var lastAudioAt: CFTimeInterval = 0
    /// 第一个音频帧比录制开始晚多少秒，补音时要把音频往后挪这么多
    private var backupOffset: Double = 0
    private var recordStartAt: CFTimeInterval = 0

    /// 录制中盯着麦克风：太久没收到音频就把音频环境重新激活一次
    private var audioWatch: DispatchSourceTimer?

    @Published private(set) var ready = false
    @Published private(set) var recording = false
    /// 实际生效的画质，比如 "4K·30"
    @Published private(set) var presetText = "—"
    /// 实际分辨率，比如 "3840×2160"
    @Published private(set) var detailText = ""
    @Published private(set) var isFront = true
    @Published private(set) var mode: Mode = .native
    @Published private(set) var recordingError = ""

    var onAudio: ((AVAudioPCMBuffer) -> Void)?
    var onFinish: ((URL?) -> Void)?

    // MARK: - 权限

    static func ensurePermissions(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { v in
            guard v else {
                DispatchQueue.main.async { done(false) }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { a in
                DispatchQueue.main.async { done(a) }
            }
        }
    }

    // MARK: - 启停

    func start(front: Bool, quality: VideoQuality, fps: Int, mode: Mode) {
        self.quality = quality
        self.fps = fps
        self.modeFlag = mode
        cfgQ.async {
            AudioSession.forCamera()
            if self.session.inputs.isEmpty {
                self.configure(front: front)
            }
            // 首次授权那一瞬间麦克风常常还没就绪。在会话「跑起来之前」再补一次，
            // 这时候加输入不会打断任何东西；跑起来之后再动会话才是危险的。
            if self.audioIn == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                self.session.beginConfiguration()
                self.addAudioInput()
                self.session.commitConfiguration()
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            DispatchQueue.main.async {
                self.ready = true
                self.mode = mode
            }
        }
    }

    func stop() {
        cfgQ.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            // 会话停了就不再占麦克风；下次 start 会重新激活并补齐音频输入
            AudioSession.release()
            DispatchQueue.main.async { self.ready = false }
        }
    }

    func switchCamera() {
        cfgQ.async {
            if self.movieOut.isRecording { return }
            let target = !self.frontFlag
            self.configure(front: target)
        }
    }

    /// 前置镜头默认镜像保存。取景框显示的是镜面（和照镜子一样），
    /// 如果成片不镜像，左右会反过来，脸和嘴看着就"歪"了。
    func setMirrorSave(_ on: Bool) {
        cfgQ.async {
            self.mirrorSaveFlag = on
            guard !self.movieOut.isRecording else { return }
            self.applyMirror()
        }
    }

    /// 把镜像设置同步到所有视频连接。后置永远不镜像。
    private func applyMirror() {
        let m = mirrorSaveFlag && frontFlag
        let outs: [AVCaptureOutput] = [movieOut, videoOut]
        for o in outs {
            guard let c = o.connection(with: .video) else { continue }
            guard c.isVideoMirroringSupported else { continue }
            if c.automaticallyAdjustsVideoMirroring {
                c.automaticallyAdjustsVideoMirroring = false
            }
            c.isVideoMirrored = m
        }
    }

    /// 切原相机 / 美颜。会重配输出，画面会闪一下，所以只在没录的时候调。
    func setMode(_ m: Mode) {
        cfgQ.async {
            guard self.modeFlag != m else { return }
            guard !self.movieOut.isRecording else { return }
            self.modeFlag = m
            self.session.beginConfiguration()
            self.configureOutputs()
            if let dev = self.videoIn?.device {
                self.applyFormat(dev)
            }
            self.session.commitConfiguration()
            self.videoQ.async {
                self.previewPool = nil
                self.previewDims = .zero
            }
            DispatchQueue.main.async {
                self.mode = m
                if let dev = self.videoIn?.device {
                    self.publishActual(dev, front: self.frontFlag)
                }
            }
        }
    }

    func updateFormat(quality: VideoQuality, fps: Int) {
        self.quality = quality
        self.fps = fps
        cfgQ.async {
            guard !self.movieOut.isRecording, let dev = self.videoIn?.device else { return }
            self.session.beginConfiguration()
            self.applyFormat(dev)
            self.session.commitConfiguration()
            self.publishActual(dev, front: self.frontFlag)
        }
    }

    // MARK: - 配置

    private func configure(front: Bool) {
        AudioSession.forCamera()

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        frontFlag = front

        for i in session.inputs {
            session.removeInput(i)
        }
        videoIn = nil
        audioIn = nil

        guard let dev = camera(front: front) else {
            DispatchQueue.main.async { self.recordingError = "找不到摄像头" }
            return
        }

        do {
            let vi = try AVCaptureDeviceInput(device: dev)
            if session.canAddInput(vi) {
                session.addInput(vi)
                videoIn = vi
            }
        } catch {
            DispatchQueue.main.async { self.recordingError = "镜头打不开：\(error.localizedDescription)" }
            return
        }

        addAudioInput()

        applyFormat(dev)
        configureOutputs()
        publishActual(dev, front: front)
    }

    /// 加麦克风输入。首次授权那一刻音频设备常常还没就绪，`AVCaptureDeviceInput` 会直接抛错；
    /// 老代码用 `try?` 吞掉就再也没重试过，整场相机会话都是哑的 —— 这就是「第一条视频没声音」。
    @discardableResult
    private func addAudioInput() -> Bool {
        if audioIn != nil { return true }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return false }
        guard let mic = AVCaptureDevice.default(for: .audio) else { return false }
        do {
            let ai = try AVCaptureDeviceInput(device: mic)
            guard session.canAddInput(ai) else { return false }
            session.addInput(ai)
            audioIn = ai
            return true
        } catch {
            return false
        }
    }

    /// 录制前补齐音频输入。首次启动相机、刚授权、或者被别的 App 打断过之后都可能缺一路，
    /// 缺了就一定录出无声视频，所以每次开录前都确认一遍。
    private func ensureAudioInput(then done: @escaping (Bool) -> Void) {
        cfgQ.async {
            if self.audioIn != nil, self.session.inputs.contains(where: { $0 === self.audioIn }) {
                DispatchQueue.main.async { done(true) }
                return
            }
            self.session.beginConfiguration()
            let ok = self.addAudioInput()
            if ok {
                // 输入变了，输出连接会重建，镜像要重新设一遍
                self.applyMirror()
            }
            self.session.commitConfiguration()
            DispatchQueue.main.async { done(ok) }
        }
    }

    private func configureOutputs() {
        for o in session.outputs {
            session.removeOutput(o)
        }

        if modeFlag == .native {
            if session.canAddOutput(movieOut) {
                session.addOutput(movieOut)
                movieOut.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
            }
            if let c = movieOut.connection(with: .video), c.isVideoOrientationSupported {
                c.videoOrientation = .portrait
            }
        } else {
            videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            videoOut.alwaysDiscardsLateVideoFrames = true
            videoOut.setSampleBufferDelegate(self, queue: videoQ)
            if session.canAddOutput(videoOut) {
                session.addOutput(videoOut)
            }
            if let c = videoOut.connection(with: .video) {
                if c.isVideoOrientationSupported {
                    c.videoOrientation = .portrait
                    needRotate = false
                } else {
                    needRotate = true
                }
            }
        }

        audioOut.setSampleBufferDelegate(self, queue: audioQ)
        if session.canAddOutput(audioOut) {
            session.addOutput(audioOut)
        }

        // 输出刚加完，连接才存在，镜像要在这时候设
        applyMirror()
    }

    private func applyFormat(_ dev: AVCaptureDevice) {
        // 美颜要逐帧过 GPU，1080P/30 是稳的上限；要 4K 就切原相机
        let side = modeFlag == .beauty ? min(quality.shortSide, 1080) : quality.shortSide
        let targetFps = modeFlag == .beauty ? min(fps, 30) : fps

        if session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
        }

        if let f = bestFormat(dev, short: side, fps: targetFps) {
            do {
                try dev.lockForConfiguration()
                dev.activeFormat = f
                let dur = CMTime(value: 1, timescale: CMTimeScale(targetFps))
                dev.activeVideoMinFrameDuration = dur
                dev.activeVideoMaxFrameDuration = dur
                dev.unlockForConfiguration()
                return
            } catch {
                // 掉到下面的预设兜底
            }
        }

        if side >= 2000, session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
        } else if side >= 1000, session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
        }
    }

    private func bestFormat(_ dev: AVCaptureDevice, short: CGFloat, fps: Int) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestScore = -Double.greatestFiniteMagnitude

        for f in dev.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let s = CGFloat(min(d.width, d.height))
            let l = CGFloat(max(d.width, d.height))
            guard s >= short - 60 else { continue }
            guard s > 0 else { continue }
            let ar = l / s
            guard abs(ar - 16.0 / 9.0) < 0.06 else { continue }
            let fpsOK = f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= Double(fps) - 0.5 }
            guard fpsOK else { continue }

            var score = -Double(abs(s - short)) * 4.0
            if abs(s - short) < 1 { score += 400 }
            if score > bestScore {
                bestScore = score
                best = f
            }
        }
        return best
    }

    private func publishActual(_ dev: AVCaptureDevice, front: Bool) {
        let d = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
        let short = Int(min(d.width, d.height))
        let long = Int(max(d.width, d.height))

        let label: String
        if short >= 2000 {
            label = "4K"
        } else if short >= 1000 {
            label = "1080P"
        } else if short >= 700 {
            label = "720P"
        } else {
            label = "\(short)P"
        }

        let secs = CMTimeGetSeconds(dev.activeVideoMinFrameDuration)
        let rate = (secs.isFinite && secs > 0) ? Int((1.0 / secs).rounded()) : 30

        DispatchQueue.main.async {
            self.presetText = "\(label)·\(rate)"
            self.detailText = "\(long)×\(short)"
            self.isFront = front
        }
    }

    private func camera(front: Bool) -> AVCaptureDevice? {
        let pos: AVCaptureDevice.Position = front ? .front : .back
        if let d = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos) {
            return d
        }
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera,
                                                   .builtInDualCamera,
                                                   .builtInUltraWideCamera]
        let ds = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: pos)
        return ds.devices.first ?? AVCaptureDevice.default(for: .video)
    }

    // MARK: - 录制

    func startRecording(to url: URL) {
        beginAudioBackup()

        if modeFlag == .native {
            // 正常情况下一个字都不改，直接开录（1.9 就是这么跑的，稳）。
            // 只有在「一个麦克风输入都没有」这种异常状态，才补一次输入再开录。
            if audioIn == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                ensureAudioInput { ok in
                    self.beginNativeRecording(url: url, micOK: ok)
                }
            } else {
                beginNativeRecording(url: url, micOK: audioIn != nil)
            }
            return
        }

        videoQ.async {
            self.pendingURL = url
            self.writerReady = false
            self.recordingFlag = true
            DispatchQueue.main.async {
                self.recordingError = ""
                self.recording = true
            }
        }
    }

    private func beginNativeRecording(url: URL, micOK: Bool) {
        cfgQ.async {
            guard self.movieOut.isRecording == false else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            AudioSession.keepAlive()
            if let c = self.movieOut.connection(with: .video), c.isVideoOrientationSupported {
                c.videoOrientation = .portrait
            }
            // 录制开始前再确认一次镜像，避免切镜头后连接被重建
            self.applyMirror()

            // 没有可用的视频连接时 startRecording 会直接抛 Objective-C 异常（闪退），先确认再开
            guard let vc = self.movieOut.connection(with: .video), vc.isEnabled else {
                DispatchQueue.main.async {
                    self.recording = false
                    self.recordingError = "画面还没准备好，再点一次"
                }
                return
            }

            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                self.recordingError = micOK ? "" : "麦克风没接上，这条可能没有声音"
                self.recording = true
            }
            self.movieOut.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        if modeFlag == .native {
            cfgQ.async {
                if self.movieOut.isRecording {
                    self.movieOut.stopRecording()
                }
            }
            return
        }

        videoQ.async {
            guard self.recordingFlag else { return }
            self.recordingFlag = false
            DispatchQueue.main.async { self.recording = false }
            self.writer.finish { url in
                guard let u = url else {
                    self.endAudioBackup { _, _ in }
                    self.onFinish?(nil)
                    return
                }
                self.repairAudioIfNeeded(u) { fixed in
                    self.onFinish?(fixed)
                }
            }
        }
    }

    // MARK: - 美颜帧处理

    private func handleVideo(_ sb: CMSampleBuffer) {
        guard let px = CMSampleBufferGetImageBuffer(sb) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let w = CVPixelBufferGetWidth(px)
        let h = CVPixelBufferGetHeight(px)

        var dims = CGSize(width: w, height: h)
        var img = BeautyPipeline.shared.makeBuffer(px)
        if needRotate {
            img = img.oriented(.right)
            dims = CGSize(width: h, height: w)
        }
        let face = BeautyPipeline.shared.tracker.geometry(pixel: px, rotate: needRotate)
        let out = BeautyPipeline.shared.process(img, dims: dims, face: face)

        if let buf = previewBuffer(dims) {
            BeautyPipeline.shared.render(out, into: buf)
            PreviewSink.shared.push(buf, pts: pts)
        }

        guard recordingFlag else { return }
        writeFrame(out, pts: pts, dims: dims)
    }

    private func writeFrame(_ img: CIImage, pts: CMTime, dims: CGSize) {
        if !writerReady {
            guard let url = pendingURL else { return }
            writerReady = writer.begin(url: url,
                                       width: Int(dims.width),
                                       height: Int(dims.height),
                                       sampleRate: audioRate,
                                       channels: audioChannels)
            if !writerReady {
                recordingFlag = false
                DispatchQueue.main.async {
                    self.recording = false
                    self.recordingError = "编码器起不来，切回原相机模式再试"
                    self.onFinish?(nil)
                }
                return
            }
        }

        guard let pool = writer.pool else { return }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess,
              let buf = pb else { return }
        BeautyPipeline.shared.render(img, into: buf)
        writer.append(video: buf, at: pts)
    }

    private func previewBuffer(_ dims: CGSize) -> CVPixelBuffer? {
        if previewPool == nil || previewDims != dims {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(dims.width),
                kCVPixelBufferHeightKey as String: Int(dims.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            previewPool = pool
            previewDims = dims
        }
        guard let pool = previewPool else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess else {
            return nil
        }
        return pb
    }

    // MARK: - 音频备份（兜住「这条没声音」）

    /// 开录时在临时目录挂一个 CAF，把麦克风 PCM 原样写进去。正常情况用不上；
    /// 一旦相机会话没把音轨写进文件（首次启动最容易），就拿它把声音补回去。
    private func beginAudioBackup() {
        audioQ.async {
            self.backupOn = true
            self.closeBackupFile()
            self.backupFrames = 0
            self.offsetFixed = false
            self.backupOffset = 0
            self.recordStartAt = CACurrentMediaTime()
            self.lastAudioAt = self.recordStartAt

            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tidanci-audio", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let u = dir.appendingPathComponent("backup.wav")
            try? FileManager.default.removeItem(at: u)
            self.backupURL = u

            // 先占位 44 字节头，等录完再回填长度
            if FileManager.default.createFile(atPath: u.path, contents: Data(count: 44)) {
                self.backupHandle = FileHandle(forWritingAtPath: u.path)
                try? self.backupHandle?.seekToEnd()
            }

            // 录制中盯着麦克风：连续 1.2 秒没有音频帧，说明环境又被别人改掉了，重新激活一次
            let t = DispatchSource.makeTimerSource(queue: self.audioQ)
            t.schedule(deadline: .now() + 0.8, repeating: 0.5)
            t.setEventHandler { [weak self] in
                guard let self, self.backupOn, self.lastAudioAt > 0 else { return }
                if CACurrentMediaTime() - self.lastAudioAt > 1.2 {
                    // 只补激活，不换类别：正在跑的采集最怕类别被改
                    AudioSession.keepAlive()
                    self.lastAudioAt = CACurrentMediaTime()
                }
            }
            self.audioWatch?.cancel()
            self.audioWatch = t
            t.resume()
        }
    }

    private func closeBackupFile() {
        if let h = backupHandle {
            // 回填 WAV 头
            let dataBytes = backupFrames * backupChannels * 2
            var head = Data()
            func le32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { head.append(contentsOf: $0) } }
            func le16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { head.append(contentsOf: $0) } }
            head.append(contentsOf: Array("RIFF".utf8))
            le32(UInt32(36 + dataBytes))
            head.append(contentsOf: Array("WAVEfmt ".utf8))
            le32(16)                                  // fmt 块长度
            le16(1)                                   // PCM
            le16(UInt16(max(1, backupChannels)))
            le32(UInt32(backupRate))
            le32(UInt32(backupRate) * UInt32(max(1, backupChannels)) * 2)   // byteRate
            le16(UInt16(max(1, backupChannels) * 2))                        // blockAlign
            le16(16)                                  // 位深
            head.append(contentsOf: Array("data".utf8))
            le32(UInt32(dataBytes))

            try? h.seek(toOffset: 0)
            try? h.write(contentsOf: head)
            try? h.close()
            backupHandle = nil
        }
    }

    /// 录制结束：关掉备份并交出文件地址。必须等文件写完再读，
    /// 否则读到的是半个文件，补进去的音频会截断。
    private func endAudioBackup(_ done: @escaping (URL?, Double) -> Void) {
        audioQ.async {
            self.backupOn = false
            self.audioWatch?.cancel()
            self.audioWatch = nil
            self.closeBackupFile()
            let u = self.backupURL
            var size = 0
            if let path = u?.path {
                size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
            }
            let off = self.backupOffset
            DispatchQueue.main.async { done(size > 4096 ? u : nil, off) }
        }
    }

    /// 把一帧 PCM 追加成 16 位小端。任何看不懂的格式直接放弃备份，
    /// 绝不在这里赌异常（赌输就是闪退）。
    private func appendAudioBackup(_ pcm: AVAudioPCMBuffer) {
        guard backupOn, let h = backupHandle else { return }
        let fmt = pcm.format
        let frames = Int(pcm.frameLength)
        let ch = Int(fmt.channelCount)
        guard frames > 0, ch > 0, fmt.sampleRate > 8000 else { return }

        backupRate = fmt.sampleRate
        backupChannels = ch

        var data = Data()
        data.reserveCapacity(frames * ch * 2)

        if fmt.commonFormat == .pcmFormatFloat32, let src = pcm.floatChannelData {
            let interleaved = fmt.isInterleaved
            for i in 0..<frames {
                for c in 0..<ch {
                    let raw = interleaved ? src[0][i * ch + c] : src[c][i]
                    let v = max(-1, min(1, raw))
                    var s = Int16(v * 32767)
                    withUnsafeBytes(of: &s) { data.append(contentsOf: $0) }
                }
            }
        } else if fmt.commonFormat == .pcmFormatInt16, let src = pcm.int16ChannelData {
            let interleaved = fmt.isInterleaved
            for i in 0..<frames {
                for c in 0..<ch {
                    var s = interleaved ? src[0][i * ch + c] : src[c][i]
                    withUnsafeBytes(of: &s) { data.append(contentsOf: $0) }
                }
            }
        } else {
            // 32 位整数 / 定点：没见过，直接放弃备份，画面照录
            backupOn = false
            return
        }

        if !data.isEmpty {
            try? h.write(contentsOf: data)
            backupFrames += frames
        }

        let now = CACurrentMediaTime()
        if !offsetFixed {
            offsetFixed = true
            backupOffset = max(0, min(1.5, now - recordStartAt))
        }
        lastAudioAt = now
    }

    /// 成片没音轨、或者音轨全静音，就用备份 PCM 补一条进去；正常就原样返回。
    private func repairAudioIfNeeded(_ video: URL, done: @escaping (URL?) -> Void) {
        endAudioBackup { backup, offset in
            guard let b = backup else {
                done(video)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                // 光有音轨不算数：采集没出帧时系统也会挂一条空音轨，播出来一样是哑的
                let hasTrack = !AVURLAsset(url: video).tracks(withMediaType: .audio).isEmpty
                let videoOk = hasTrack && SilenceCut.peakDb(video) > -52
                let backupOk = SilenceCut.peakDb(b) > -52
                DispatchQueue.main.async {
                    guard !videoOk, backupOk else {
                        done(video)
                        return
                    }
                    self.mux(video: video, audio: b, offset: offset, done: done)
                }
            }
        }
    }

    private func mux(video: URL, audio: URL, offset: Double, done: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let comp = AVMutableComposition()
            let va = AVURLAsset(url: video)
            let aa = AVURLAsset(url: audio)
            guard let vt = va.tracks(withMediaType: .video).first,
                  let vt2 = comp.addMutableTrack(withMediaType: .video,
                                                 preferredTrackID: kCMPersistentTrackID_Invalid),
                  let at = aa.tracks(withMediaType: .audio).first,
                  let at2 = comp.addMutableTrack(withMediaType: .audio,
                                                 preferredTrackID: kCMPersistentTrackID_Invalid) else {
                DispatchQueue.main.async { done(video) }
                return
            }
            let vd = va.duration
            try? vt2.insertTimeRange(CMTimeRange(start: .zero, duration: vd), of: vt, at: .zero)
            vt2.preferredTransform = vt.preferredTransform

            let start = CMTime(seconds: offset, preferredTimescale: 600)
            let len = max(0, vd.seconds - offset)
            if len > 0.1 {
                try? at2.insertTimeRange(CMTimeRange(start: .zero,
                                                     duration: CMTime(seconds: len, preferredTimescale: 600)),
                                         of: at,
                                         at: start)
            }

            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("tidanci-fix-\(UUID().uuidString)")
                .appendingPathExtension(video.pathExtension.isEmpty ? "mp4" : video.pathExtension)
            try? FileManager.default.removeItem(at: tmp)

            guard let ex = AVAssetExportSession(asset: comp,
                                                presetName: AVAssetExportPresetHighestQuality) else {
                DispatchQueue.main.async { done(video) }
                return
            }
            ex.outputURL = tmp
            ex.outputFileType = video.pathExtension.lowercased() == "mov" ? .mov : .mp4
            ex.exportAsynchronously {
                DispatchQueue.main.async {
                    guard ex.status == .completed,
                          FileManager.default.fileExists(atPath: tmp.path) else {
                        try? FileManager.default.removeItem(at: tmp)
                        done(video)
                        return
                    }
                    _ = try? FileManager.default.replaceItemAt(video, withItemAt: tmp)
                    self.recordingError = "原声没进文件，已用备份音轨补上"
                    done(video)
                }
            }
        }
    }

    private func handleAudio(_ sb: CMSampleBuffer) {
        if let fd = CMSampleBufferGetFormatDescription(sb),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
            let rate = asbd.pointee.mSampleRate
            let ch = Int(asbd.pointee.mChannelsPerFrame)
            if rate > 8000, ch > 0 {
                audioRate = rate
                audioChannels = ch
            }
        }

        if recordingFlag, modeFlag == .beauty {
            writer.append(audio: sb)
        }

        if let pcm = CameraRecorder.toPCM(sb) {
            if backupOn { appendAudioBackup(pcm) }
            onAudio?(pcm)
        }
    }

    static func toPCM(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return nil }
        guard let fmt = AVAudioFormat(streamDescription: asbd),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0,
                                                             frameCount: Int32(frames),
                                                             into: buf.mutableAudioBufferList)
        return st == noErr ? buf : nil
    }
}

// MARK: - 采集回调

extension CameraRecorder: AVCaptureVideoDataOutputSampleBufferDelegate,
                         AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoOut {
            handleVideo(sampleBuffer)
        } else {
            handleAudio(sampleBuffer)
        }
    }
}

// MARK: - 原相机录制回调

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        var ok = error == nil
        var msg = ""
        if let e = error as NSError? {
            if let v = e.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool, v {
                ok = true
            } else {
                msg = e.localizedDescription
            }
        }
        let finished = ok
        DispatchQueue.main.async {
            self.recording = false
            if !msg.isEmpty { self.recordingError = msg }
            guard finished else {
                self.endAudioBackup { _, _ in }
                self.onFinish?(nil)
                return
            }
            // 万一这条路没把音轨写进文件，用录制期间备份的 PCM 补上，别让用户白录一条
            self.repairAudioIfNeeded(outputFileURL) { url in
                self.onFinish?(url)
            }
        }
    }
}

// MARK: - 原相机预览

final class PreviewLayerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    var mirrored: Bool = true {
        didSet { syncMirror() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncMirror()
    }

    /// 取景框必须和录制连接用同一套镜像设置，否则"看到的"和"录出来的"是反的
    func syncMirror() {
        guard let c = previewLayer.connection else { return }
        if c.isVideoOrientationSupported {
            c.videoOrientation = .portrait
        }
        if c.isVideoMirroringSupported {
            if c.automaticallyAdjustsVideoMirroring {
                c.automaticallyAdjustsVideoMirroring = false
            }
            if c.isVideoMirrored != mirrored {
                c.isVideoMirrored = mirrored
            }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var mirrored: Bool = true

    func makeUIView(context: Context) -> PreviewLayerView {
        let v = PreviewLayerView()
        v.backgroundColor = .black
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.mirrored = mirrored
        return v
    }

    func updateUIView(_ uiView: PreviewLayerView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        uiView.mirrored = mirrored
        uiView.syncMirror()
    }
}
