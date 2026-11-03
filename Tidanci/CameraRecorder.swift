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
    /// 第一帧音频的 PTS（秒）。备份的时间轴从这里起算，缺帧处补静音，
    /// 这样备份的长度、节奏和视频严格一致 —— 长录制才不会越到后面越不同步。
    private var firstAudioPts: Double = -1
    /// 因为丢帧补进去的静音帧数，进诊断
    private var backupPadFrames = 0
    /// 中途采样率/声道变了（理论上不会），只记一次
    private var backupFmtWarned = false

    /// 录制中盯着麦克风：太久没收到音频就把音频环境重新激活一次
    private var audioWatch: DispatchSourceTimer?

    /// 最近一帧麦克风音频的时间（不论有没有在录）。开录前用它判断「麦克风到底有没有出数据」，
    /// 没数据就先修，而不是稀里糊涂录一条无声视频。
    private var lastAudioFrameAt: CFTimeInterval = 0
    /// 本次录制收到的音频帧数，进诊断日志
    private var audioFrameCount = 0
    /// 断流提示只记一次，免得日志被刷满
    private var audioWarned = false
    private var audioNextRetry: CFTimeInterval = 0
    /// 整理音轨期间有人要求停会话：等整理完再停，别把正在读的文件链路拆了
    private var stopPending = false
    /// 已经收到「停止录制」，但成片还没交出去（写入收尾 + 整理音轨）
    private var finishing = false
    /// 停会话的兜底闹钟：整理链路万一卡住，也不能一直占着麦克风
    private var stopFallback: DispatchWorkItem?

    @Published private(set) var ready = false
    /// 录完之后正在重建音轨。长视频要几秒，界面得给个动静
    @Published private(set) var tidying = false
    @Published private(set) var recording = false {
        didSet { AudioSession.cameraBusy = recording }
    }
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
            //
            // 一次不成不代表没有：刚授权那几百毫秒里音频设备还在初始化，
            // AVCaptureDeviceInput 会抛错。老代码只试一次，失败就整场哑掉 ——
            // 这就是「第一次录的视频没有声音」。这里给 4 次机会、每次隔 120ms，
            // 最多多等 0.36 秒（只在异常情况才等）。
            if self.audioIn == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                for attempt in 0..<4 {
                    self.session.beginConfiguration()
                    let ok = self.addAudioInput()
                    self.session.commitConfiguration()
                    if ok { break }
                    if attempt < 3 { Thread.sleep(forTimeInterval: 0.12) }
                }
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
        // 状态都在主线程读写，后台来的调用先转回主线程
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.stop() }
            return
        }
        // 正在收尾或整理音轨：先别关会话。这几个步骤都要读刚写完的文件和备份，
        // 用户这时退出页面也不该把它拦腰截断 —— 记下来，等交付完再停。
        if tidying || finishing {
            stopPending = true
            stopFallback?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.stopPending else { return }
                self.stopPending = false
                self.doStop()
            }
            stopFallback = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: w)
            return
        }
        doStop()
    }

    /// 交付成片（成功或失败）统一走这里：清掉收尾状态，并执行被推迟的停会话。
    private func deliver(_ url: URL?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.deliver(url) }
            return
        }
        finishing = false
        stopFallback?.cancel()
        stopFallback = nil
        let stopNow = stopPending
        stopPending = false
        onFinish?(url)
        if stopNow { doStop() }
    }

    private func doStop() {
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

    // MARK: - 相机会话被系统打断

    private var observingSession = false

    /// 来电、别的 App 抢麦、切后台回来，都会让会话中断一次 —— 中断期间音频这条路
    /// 直接停掉，画面照走。以前这种断流只能等看门狗每 1.5 秒摸一次，摸不回来就整段哑。
    /// 现在把系统的中断/错误通知接上：停下来的时候把会话重新拉起来，下一段就正常。
    private func observeSessionIfNeeded() {
        guard !observingSession else { return }
        observingSession = true
        let c = NotificationCenter.default
        c.addObserver(forName: .AVCaptureSessionWasInterrupted,
                      object: session, queue: nil) { _ in
            Diag.note("相机会话被中断（录音会停，这一段靠备份兜）")
        }
        c.addObserver(forName: .AVCaptureSessionInterruptionEnded,
                      object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            Diag.note("相机会话中断结束")
            self.cfgQ.async {
                // 录制中不动 session：startRunning 会把当前这段录制提前收尾，
                // 四分钟的片子就废了。等停下再重启，下一段自然正常。
                if !self.session.isRunning, !self.movieOut.isRecording {
                    self.session.startRunning()
                }
                AudioSession.enforceForCamera()
            }
        }
        c.addObserver(forName: .AVCaptureSessionRuntimeError,
                      object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            let code = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code ?? 0
            Diag.note("相机会话运行时错误 code=\(code)")
            self.cfgQ.async {
                if !self.movieOut.isRecording, !self.session.isRunning {
                    self.session.startRunning()
                }
                AudioSession.enforceForCamera()
            }
        }
    }

    private func configure(front: Bool) {
        observeSessionIfNeeded()
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
        audioFrameCount = 0

        // 开录前先问一句「麦克风现在到底出不出数据」。
        // 没数据就先把音频路由抢回来，等它缓过来再开录——
        // 比让人对着镜头说完一整段、回放才发现没声音强得多。
        let age = CACurrentMediaTime() - lastAudioFrameAt
        if age > 1.0 {
            Diag.note("开录前 \(String(format: "%.1f", age)) 秒没音频帧，先修路由")
            AudioSession.enforceForCamera()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                self?.beginRecordingNow(url)
            }
            return
        }
        beginRecordingNow(url)
    }

    private func beginRecordingNow(_ url: URL) {
        // 上一次收尾可能因为异常没走到 deliver，这里把状态清干净，
        // 否则新的一条一开录就会被「等整理完再停会话」卡住
        finishing = false
        stopPending = false
        stopFallback?.cancel()
        stopFallback = nil

        beginAudioBackup()

        // 开录后一秒半还是没有音频帧：基本就是麦克风这条路断了，先把话说在前面。
        // 不去打断录制（画面还在录，说不定后面恢复），只把提示留下。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.recording, self.audioFrameCount == 0 else { return }
            self.recordingError = "麦克风没在出数据，这条可能没有声音"
            Diag.note("录制中 1.5 秒无音频帧")
            AudioSession.enforceForCamera()
        }

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
        // 从这一刻到交付成片之间，会话先别关（关闭会让写文件/整理音轨的链路悬空）
        if Thread.isMainThread {
            finishing = true
        } else {
            DispatchQueue.main.async { self.finishing = true }
        }

        if modeFlag == .native {
            cfgQ.async {
                if self.movieOut.isRecording {
                    self.movieOut.stopRecording()
                } else {
                    // 没在录：撤销刚才那个标志，否则 stop() 会一直等下去
                    DispatchQueue.main.async { self.finishing = false }
                }
            }
            return
        }

        videoQ.async {
            guard self.recordingFlag else {
                DispatchQueue.main.async { self.finishing = false }
                return
            }
            self.recordingFlag = false
            DispatchQueue.main.async { self.recording = false }
            self.writer.finish { url in
                guard let u = url else {
                    self.endAudioBackup { _, _ in }
                    self.deliver(nil)
                    return
                }
                self.repairAudioIfNeeded(u) { fixed in
                    self.deliver(fixed)
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
                    self.deliver(nil)
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
            self.backupPadFrames = 0
            self.firstAudioPts = -1
            self.backupFmtWarned = false
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

            // 录制中盯着麦克风。阈值收到 0.7 秒：识别一句话说完会重开请求，
            // 那一下最容易把音频会话带偏，早一点抢回来还有救，晚两秒就整段哑了。
            self.audioWarned = false
            self.audioNextRetry = 0
            let t = DispatchSource.makeTimerSource(queue: self.audioQ)
            t.schedule(deadline: .now() + 0.6, repeating: 0.4)
            t.setEventHandler { [weak self] in
                guard let self, self.backupOn, self.lastAudioAt > 0 else { return }
                let now = CACurrentMediaTime()
                let gap = now - self.lastAudioAt
                // 最多每 1.5 秒抢一次：反复 setCategory 本身就会打断采集，
                // 抢得太勤反而把刚恢复的 I/O 又踹一脚。
                guard gap > 0.7, now >= self.audioNextRetry else { return }
                self.audioNextRetry = now + 1.5
                let changed = AudioSession.enforceForCamera()
                if !self.audioWarned {
                    self.audioWarned = true
                    Diag.note(String(format: "录音断流 %.1fs，已强制恢复音频路由%@",
                                     gap, changed ? "（换了类别）" : ""))
                }
            }
            self.audioWatch?.cancel()
            self.audioWatch = t
            t.resume()
        }
    }

    private func closeBackupFile() {
        if let h = backupHandle {
            // 回填 WAV 头。长度按「实际写进去的总帧数」算（含补的静音），
            // 否则文件里音频比声明长/短，读出来会截断或爆音。
            let raw = backupFrames * backupChannels * 2
            // WAV 的长度字段是 32 位，超了要截：宁可文件短一点，也不能溢出崩溃
            let dataBytes = min(raw, Int(UInt32.max) - 64)
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

            Diag.note("备份：\(Int(backupRate))Hz/\(backupChannels)ch 共 "
                      + String(format: "%.1f", Double(backupFrames) / max(1, backupRate))
                      + "s（其中补静音 \(String(format: "%.1f", Double(backupPadFrames) / max(1, backupRate)))s）")
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
    ///
    /// v1.14：按 PTS 对齐写入。旧版是「来一帧写一帧」，中途什么时候断过、断了多久
    /// 完全不知道，备份就成了压缩过的音轨 —— 补进四分钟的成片里，越到后面越对不上嘴。
    /// 现在每一帧都按它自己的时间戳落位，中间的空洞补静音，时间轴和视频一模一样。
    private func appendAudioBackup(_ pcm: AVAudioPCMBuffer, pts: CMTime) {
        guard backupOn, let h = backupHandle else { return }
        let fmt = pcm.format
        let frames = Int(pcm.frameLength)
        let ch = Int(fmt.channelCount)
        guard frames > 0, ch > 0, fmt.sampleRate > 8000 else { return }

        let ptsSec = pts.isValid && pts.seconds.isFinite ? pts.seconds : CACurrentMediaTime()
        if firstAudioPts < 0 {
            // 第一帧定死格式和起点，之后不再改：改采样率等于把已写进去的时间轴推翻
            firstAudioPts = ptsSec
            backupRate = fmt.sampleRate
            backupChannels = ch
            if !offsetFixed {
                offsetFixed = true
                backupOffset = max(0, min(1.5, ptsSec - recordStartAt))
            }
        } else if abs(fmt.sampleRate - backupRate) > 1 || ch != backupChannels {
            if !backupFmtWarned {
                backupFmtWarned = true
                Diag.note("备份格式中途变了：\(Int(fmt.sampleRate))Hz/\(ch)ch，这一帧跳过")
            }
            return
        }

        // 这个空洞最多补到 15 分钟，PTS 要是抽风也不会写出几十个 G
        let rel = max(0, ptsSec - firstAudioPts)
        let want = Int((rel * backupRate).rounded())
        let pad = min(want - backupFrames, Int(backupRate) * 900)
        if pad > Int(backupRate * 0.02) {
            writeZeros(pad, channels: backupChannels, handle: h)
            backupPadFrames += pad
        }

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
            do {
                try h.write(contentsOf: data)
                backupFrames += frames
            } catch {
                // 写失败（磁盘满 / 句柄被系统回收）以前是 try? 悄悄吞掉，
                // 结果备份停在半截，补出来的成片后半段没声 —— 记下来
                Diag.note("备份写入失败：\(error.localizedDescription)")
                backupOn = false
                return
            }
        }

        lastAudioAt = CACurrentMediaTime()
    }

    private func writeZeros(_ frames: Int, channels: Int, handle h: FileHandle) {
        let bytes = frames * channels * 2
        guard bytes > 0 else { return }
        let chunk = 32768
        let zero = Data(count: min(bytes, chunk))
        var left = bytes
        while left > 0 {
            let n = min(left, chunk)
            do {
                try h.write(contentsOf: n == chunk ? zero : Data(zero.prefix(n)))
            } catch {
                // 只把真写进去的那部分算进长度，否则 WAV 头会比文件长，读出来是破的
                backupFrames += (bytes - left) / max(1, channels * 2)
                Diag.note("补静音失败：\(error.localizedDescription)")
                backupOn = false
                return
            }
            left -= n
        }
        backupFrames += frames
    }

    /// 用备份 PCM 当音轨，重新合成一条成片。
    ///
    /// ── v1.14：判据改成看「尾巴」 ─────────────────────────────
    /// v1.13 用「音轨时长 < 视频 92% 或 峰值静音」判断成片坏没坏。四分钟的片子
    /// 在这两条上都能蒙混过关：
    ///   · 峰值只扫前 45 秒 —— 前 45 秒有声，峰值就是正常的；
    ///   · 编码器一路写静音样本，音轨时长照样是满的。
    /// 于是「看起来没问题」被原样留下，用户听到的是从头到尾没声音。
    ///
    /// 现在看末尾四分之一的音量：成片尾巴是死的、备份尾巴有声，一律以备份为准重做。
    private func repairAudioIfNeeded(_ video: URL, done: @escaping (URL?) -> Void) {
        endAudioBackup { backup, offset in
            guard let b = backup else {
                Diag.note("没有可用备份，成片原样输出")
                done(video)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let t0 = CACurrentMediaTime()
                let bs = SilenceCut.stats(b)
                let asset = AVURLAsset(url: video)
                let aTrack = asset.tracks(withMediaType: .audio).first
                let vLen = asset.duration.seconds
                // 成片音轨只抽查头尾：全程解码四分钟的 AAC 要好几秒，
                // 而判断「整条哑了」看开头、「后半段断了」看尾巴就够了。
                let vs = aTrack == nil ? SilenceCut.AudioStats() : SilenceCut.statsSampled(video)

                // 成片音轨的四种坏法：没有、比视频短一截、整体静音、尾巴是死的。
                // 阈值从 92% 收到 97%：四分钟的片子断在 3 分半，92% 是判不出来的。
                let short = vs.duration < vLen * 0.97
                let deadTail = vs.tail <= -50 && bs.tail > -50
                let broken = (aTrack == nil) || short || vs.peak <= -52 || deadTail

                let vText: String
                if aTrack == nil {
                    vText = "无"
                } else {
                    vText = String(format: "%.1fs/%.0fdB/尾%.0fdB", vs.duration, vs.peak, vs.tail)
                }
                Diag.note("结束：帧=\(self.audioFrameCount) 备份="
                          + String(format: "%.1fs/%.0fdB/尾%.0fdB", bs.duration, bs.peak, bs.tail)
                          + " 成片音轨=\(vText) 视频="
                          + String(format: "%.1fs", vLen)
                          + " 判定=\(broken ? "需补音" : "正常") 体检 "
                          + String(format: "%.2fs", CACurrentMediaTime() - t0))

                DispatchQueue.main.async {
                    // 备份也是哑的：麦克风整条路没通，补也补不出声音，别白等一轮合成
                    guard bs.peak > -52 else {
                        self.recordingError = "这条没录到声音（麦克风没出数据），建议重录"
                        done(video)
                        return
                    }
                    // 成片音轨确实完好，就直接交片：重建要转 AAC + 整片直通拷贝，
                    // 四分钟的片子得等好几秒，没必要为了「更保险」让每条都等。
                    // 判据已经管住四种坏法（无音轨 / 变短 / 全哑 / 尾巴死）。
                    guard broken else {
                        Diag.note("成片音轨正常，跳过重建")
                        done(video)
                        return
                    }
                    self.tidying = true
                    self.mux(video: video, audio: b, offset: offset, mustFix: true) { url in
                        self.tidying = false
                        done(url)
                        // 整理期间有人退出了页面、要求关会话：现在可以关了
                        if self.stopPending {
                            self.stopPending = false
                            self.doStop()
                        }
                    }
                }
            }
        }
    }

    private func mux(video: URL, audio: URL, offset: Double,
                     mustFix: Bool, done: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // ① 备份是 WAV（PCM），mp4 容器装不了。先单独编码成 AAC——
            //    只要音轨是 AAC，整个片子就能走 passthrough：视频一个像素都不重编码。
            //    旧版一律 HighestQuality，4K 片子要重压十几秒，用户以为卡死了。
            let t0 = CACurrentMediaTime()
            let aac = self.encodeAAC(audio)
            Diag.note("音频准备：AAC \(aac == nil ? "失败" : "成功")，耗时 "
                      + String(format: "%.1fs", CACurrentMediaTime() - t0))
            if aac == nil, !mustFix {
                // 编码没成、成片音轨又是好的：没必要为了保险去重压一条四分钟的 4K
                Diag.note("AAC 失败但成片音轨正常，保持原样")
                DispatchQueue.main.async { done(video) }
                return
            }
            let source = aac ?? audio

            let comp = AVMutableComposition()
            let va = AVURLAsset(url: video)
            let aa = AVURLAsset(url: source)
            guard let vt = va.tracks(withMediaType: .video).first,
                  let vt2 = comp.addMutableTrack(withMediaType: .video,
                                                 preferredTrackID: kCMPersistentTrackID_Invalid),
                  let at = aa.tracks(withMediaType: .audio).first,
                  let at2 = comp.addMutableTrack(withMediaType: .audio,
                                                 preferredTrackID: kCMPersistentTrackID_Invalid) else {
                Diag.note("合成失败：拿不到轨道")
                DispatchQueue.main.async { done(video) }
                return
            }
            let vd = va.duration
            try? vt2.insertTimeRange(CMTimeRange(start: .zero, duration: vd), of: vt, at: .zero)
            vt2.preferredTransform = vt.preferredTransform

            // 音轨按「视频还剩多长」和「备份实际多长」里较短的那个插。
            // 旧版只按视频算长度：备份短了几十毫秒，insertTimeRange 就会整段失败，
            // try? 把错误吞掉之后成片干脆没有音轨——「补了个寂寞」就是这么来的。
            let start = CMTime(seconds: offset, preferredTimescale: 600)
            let aRange = at.timeRange
            let room = max(0, vd.seconds - offset)
            let len = min(room, aRange.duration.seconds)
            if len > 0.1 {
                try? at2.insertTimeRange(CMTimeRange(start: aRange.start,
                                                     duration: CMTime(seconds: len, preferredTimescale: 600)),
                                         of: at,
                                         at: start)
            }
            Diag.note("合成：视频 \(String(format: "%.1f", vd.seconds))s 备份 "
                      + "\(String(format: "%.1f", aRange.duration.seconds))s 偏移 "
                      + String(format: "%.2f", offset) + "s 实插 "
                      + String(format: "%.1f", len) + "s")

            let ext = video.pathExtension.lowercased() == "mov" ? "mov" : "mp4"
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("tidanci-fix-\(UUID().uuidString).\(ext)")
            let fileType: AVFileType = ext == "mov" ? .mov : .mp4

            // ② 先试直通（快），直通被容器/机型拒了再退重编码（慢但一定能出）。
            //    四分钟的 4K 片子直通是秒级，重编码要几分钟——所以两者给不同的等待上限。
            var out = self.export(comp, to: tmp, fileType: fileType,
                                  preset: AVAssetExportPresetPassthrough, timeout: 180)
            if out == nil {
                Diag.note("直通合成没成功，改走重编码（这条会慢一些）")
                out = self.export(comp, to: tmp, fileType: fileType,
                                  preset: AVAssetExportPresetHighestQuality, timeout: 600)
            }

            guard let ok = out else {
                Diag.note("补音失败：合成没有产出文件，成片保持原样（没声音）")
                DispatchQueue.main.async {
                    self.recordingError = "这条没补上声音，检查下手机存储再重录一次"
                    done(video)
                }
                return
            }

            var replaced = true
            do {
                _ = try FileManager.default.replaceItemAt(video, withItemAt: ok)
            } catch {
                // 原子替换在「原文件还被相册/系统占着」或者空间不够时会失败。
                // 退一步：先把新文件搬进同一个目录（同卷 rename，几乎不会失败），
                // 再删原文件改名。四分钟的片子体积大，这一步比以前更容易踩到。
                Diag.note("原子替换失败：\(error.localizedDescription)，改走改名替换")
                let dir = video.deletingLastPathComponent()
                let staged = dir.appendingPathComponent("tidanci-stage-\(UUID().uuidString)")
                    .appendingPathExtension(video.pathExtension.isEmpty ? "mp4" : video.pathExtension)
                do {
                    try FileManager.default.moveItem(at: ok, to: staged)
                    try? FileManager.default.removeItem(at: video)
                    try FileManager.default.moveItem(at: staged, to: video)
                } catch {
                    replaced = false
                    try? FileManager.default.removeItem(at: staged)
                    Diag.note("改名替换也失败：\(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                // 成功就静默——用户只需要听到声音，不需要知道过程
                self.recordingError = replaced ? "" : "音轨合成失败，这条可能没声音"
                done(video)
            }
        }
    }

    /// 同步导出（调用方已经在后台队列上，不会卡界面）
    private func export(_ asset: AVAsset, to url: URL,
                        fileType: AVFileType, preset: String,
                        timeout: TimeInterval = 180) -> URL? {
        try? FileManager.default.removeItem(at: url)
        guard let ex = AVAssetExportSession(asset: asset, presetName: preset) else { return nil }
        ex.outputURL = url
        ex.outputFileType = fileType
        // 相册播放用不上 moov 前置，关掉能少一次整文件重排
        ex.shouldOptimizeForNetworkUse = false
        let sem = DispatchSemaphore(value: 0)
        ex.exportAsynchronously { sem.signal() }
        // 旧版是死等：四分钟的片子万一卡在导出，这个后台队列就永远不回来了，
        // 成片一直不出现，用户以为「录完就没了」
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            ex.cancelExport()
            Diag.note("导出超时（\(preset)，\(Int(timeout))s）")
            return nil
        }
        if ex.status == .completed, FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        Diag.note("导出失败（\(preset)）：\(ex.error?.localizedDescription ?? "-")")
        return nil
    }

    /// WAV → AAC(m4a)
    ///
    /// 不走 AVAssetExportSession：它对长音频（四分钟）是整段解码再编码，
    /// 中间既没有进度也没法干预，失败原因还只给一句含糊的话。
    /// 这里用 reader + writer 一段一段推，硬件编码，四分钟音频一两秒完事。
    private func encodeAAC(_ wav: URL) -> URL? {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("tidanci-aac-\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: out)

        let asset = AVURLAsset(url: wav)
        guard let track = asset.tracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else {
            Diag.note("AAC：读不到 WAV 音轨")
            return nil
        }

        var rate: Double = 48000
        var ch = 1
        if let fd = track.formatDescriptions.first {
            let afd = fd as! CMAudioFormatDescription
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(afd) {
                if asbd.pointee.mSampleRate > 8000 { rate = asbd.pointee.mSampleRate }
                if asbd.pointee.mChannelsPerFrame > 0 { ch = Int(asbd.pointee.mChannelsPerFrame) }
            }
        }

        let readerOut = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(readerOut) else {
            Diag.note("AAC：reader 加不上输出")
            return nil
        }
        reader.add(readerOut)

        guard let writer = try? AVAssetWriter(outputURL: out, fileType: .m4a) else {
            Diag.note("AAC：writer 打不开")
            return nil
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: ch,
            AVEncoderBitRateKey: 96000
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            Diag.note("AAC：writer 加不上输入")
            return nil
        }
        writer.add(input)

        guard reader.startReading(), writer.startWriting() else {
            Diag.note("AAC：启动失败 \(reader.error?.localizedDescription ?? "-") "
                      + "\(writer.error?.localizedDescription ?? "-")")
            return nil
        }
        writer.startSession(atSourceTime: .zero)

        var chunks = 0
        var spins = 0
        while writer.status == .writing {
            if reader.status == .failed {
                Diag.note("AAC：reader 失败 \(reader.error?.localizedDescription ?? "-")")
                break
            }
            if input.isReadyForMoreMediaData {
                spins = 0
                if let sb = readerOut.copyNextSampleBuffer() {
                    if input.append(sb) { chunks += 1 }
                } else {
                    input.markAsFinished()
                    break
                }
            } else {
                // 编码器一直说「忙」就是卡住了，别把后台线程永远挂在这儿
                spins += 1
                if spins > 5000 {
                    Diag.note("AAC：编码器卡住，放弃")
                    writer.cancelWriting()
                    return nil
                }
                Thread.sleep(forTimeInterval: 0.004)
            }
        }

        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        if sem.wait(timeout: .now() + 120) == .timedOut {
            writer.cancelWriting()
            Diag.note("AAC：收尾超时")
            return nil
        }
        guard writer.status == .completed else {
            Diag.note("AAC：写入失败 \(writer.error?.localizedDescription ?? "-")")
            return nil
        }
        Diag.note("AAC：\(Int(rate))Hz/\(ch)ch \(chunks) 段")
        return out
    }

    private func handleAudio(_ sb: CMSampleBuffer) {
        lastAudioFrameAt = CACurrentMediaTime()
        audioFrameCount += 1

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
            if backupOn {
                appendAudioBackup(pcm, pts: CMSampleBufferGetPresentationTimeStamp(sb))
            }
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
                self.deliver(nil)
                return
            }
            // 万一这条路没把音轨写进文件，用录制期间备份的 PCM 补上，别让用户白录一条
            self.repairAudioIfNeeded(outputFileURL) { url in
                self.deliver(url)
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
