import Foundation
import AVFoundation
import CoreVideo
import Combine
import UIKit
import SwiftUI
import ImageIO

/// 相机 + 录制。两条通路：
///
/// * 原相机（native）：AVCaptureMovieFileOutput 直接落盘，音视频写在同一个文件里，
///   停录即可用，能 4K/60fps，画质最高。
/// * 经典美颜（beauty）：AVCaptureVideoDataOutput → Core Image 美颜 → AVAssetWriter 落盘，
///   预览走 AVSampleBufferDisplayLayer。这条路走 GPU，1080P 封顶。
///
/// ── v1.22：native 回到「系统相机同款」，音频重新挂进 AVCaptureSession ──────────
/// v1.20 为了躲「长录时音频连接先断」，把麦克风整个从相机会话里搬走，改用 MicTap
/// （AVAudioEngine）单独采，成片再靠备份 WAV 合成音轨。代价是：
///   · movieOut 录出来的 mp4 根本没有音轨，每次停录都得跑一遍 repairAudioIfNeeded，
///     四分钟的片子要等好几秒 —— 用户说的「存半天」就是这一步；
///   · 备份 WAV 一旦中途断掉，成片是哑的，编辑页自然「识别不出来」。
///
/// 系统相机自己是 session 里挂麦克风 input + AVCaptureMovieFileOutput，音视频一起写。
/// 长录稳不稳，关键从来不是「把音频搬出去」，而是「被中断之后能不能自己接上」。
/// 所以现在：
///   ① native 的音频输入挂在 session 上，停录立刻交付带声音的 mp4，不再合成；
///   ② 跟读识别改由 session 里的 AVCaptureAudioDataOutput 喂 onAudio（native 不再有 MicTap）；
///   ③ 会话中断 / 运行时错误由通知接管，能恢复就把 session 拉起来接着录（iOS 18+ 再补 resumeRecording），恢复不了就把话说明白；
///   ④ 防抖是可选档位，落在连接的 preferredVideoStabilizationMode 上。
///
/// MicTap 与备份 WAV 只留给 beauty：那条路的 writer 音轨仍然靠它兜。
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

    /// 麦克风走独立引擎（AVAudioEngine），只在 beauty 路用。
    /// native 把麦克风挂在相机会话上（系统相机同款），绝不起这个引擎 ——
    /// 两路同时占一个麦，长录时最容易互相踩。
    private let mic = MicTap()

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
    /// 防抖档位（0 关 / 1 标准 / 2 电影级）。用户意图，实际生效的档位会降级后发到 stabilText
    private var stabilizationFlag = 1

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

    /// native 录制期间盯音频的定时器。故意和 audioWatch 分开：
    /// 那条是 beauty 的「重开独立引擎」，这条只做「重新激活音频路由」，
    /// 绝不碰 session —— startRunning/stopRunning 会把正在写的这一段提前收尾。
    private var nativeWatch: DispatchSourceTimer?
    private var watchOn = false

    /// 开录时刻的 hostTime。音频时间轴以它为 0 点，和视频 PTS 对齐。
    private var audioStartHost: UInt64 = 0
    /// 独立引擎起不来（被别的 App 长期占着麦之类），退回相机自带的那条音频路
    private var micFailed = false

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
    /// 实际生效的防抖描述，比如 "防抖·标准"。关掉时是空串（拍摄页不显示）
    @Published private(set) var stabilText = ""
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
            // 会话跑起来之前把麦克风挂好（configure 里做的）：native 的 movieOut
            // 只有 session 里存在音频输入时才会写音轨。auth 刚给下来那一下
            // AVCaptureDeviceInput 可能还建不起来，所以这里再补一次。
            if self.modeFlag == .native, self.audioIn == nil {
                self.session.beginConfiguration()
                _ = self.addAudioInput()
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
        // 异常路径下 endAudioBackup 可能没跑到，这里兜一次，别让引擎一直占着麦
        mic.onBuffer = nil
        mic.stop()
        stopNativeWatch()
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

    // MARK: - 防抖

    /// 防抖档位。设置页改这里，真正生效的档位发回 stabilText（拍摄页那个小胶囊）。
    /// 档位切换只在没录的时候做：录制中改连接属性会闪一下，还可能被系统直接忽略。
    func setStabilization(_ level: Int) {
        cfgQ.async {
            self.stabilizationFlag = level
            guard !self.movieOut.isRecording else { return }
            // 会话跑着的时候改连接属性，包一层 begin/commit 才是安全姿势
            let wrap = self.session.isRunning
            if wrap { self.session.beginConfiguration() }
            self.applyStabilization()
            if wrap { self.session.commitConfiguration() }
        }
    }

    /// 把档位落到所有视频连接（movieOut 与 videoOut 各一条）。
    ///
    /// 用户选的是「意图」，实际支持什么由机型和当前画质决定 —— 4K60 上电影级基本都没戏，
    /// 所以这里逐档降级，并把最终生效的那一档告诉界面，而不是让用户以为开了。
    /// 调用方要么在 begin/commit 里（configureOutputs / setMode / updateFormat），
    /// 要么自己包一层（setStabilization），这里不再套。
    private func applyStabilization() {
        let want = Stabilization(rawValue: stabilizationFlag) ?? .off
        // 具体到「电影级这一档支不支持」只有设备格式知道，连接只能回答「整体能不能防抖」
        let format = videoIn?.device.activeFormat
        var anyConnection = false
        var actual: AVCaptureVideoStabilizationMode = .off

        let outs: [AVCaptureOutput] = [movieOut, videoOut]
        for o in outs {
            guard let c = o.connection(with: .video) else { continue }
            guard c.isVideoStabilizationSupported else { continue }
            anyConnection = true
            actual = applyStabilization(to: c, want: want, format: format)
        }

        guard anyConnection else {
            DispatchQueue.main.async { self.stabilText = "" }
            return
        }

        let level = Self.level(of: actual)
        DispatchQueue.main.async {
            // 关掉就不占地方；开着才在拍摄页挂一个「防抖·标准」的小胶囊
            self.stabilText = level == .off ? "" : "防抖·\(level.title)"
        }
        if level != want {
            Diag.note("防抖：想要\(want.title)，这个画质只给到\(level.title)")
        }
    }

    /// 单条连接的降级链。返回真正落地的模式。
    ///
    /// 注意：`isVideoStabilizationModeSupported(_:)` 在 **AVCaptureDevice.Format** 上，
    /// 不在 AVCaptureConnection 上 —— 连接只有 `isVideoStabilizationSupported`（整体支不支持）。
    private func applyStabilization(to c: AVCaptureConnection,
                                    want: Stabilization,
                                    format: AVCaptureDevice.Format?) -> AVCaptureVideoStabilizationMode {
        // 拿不到格式（还没配上）就不做判断，直接照意图设：系统不支持的话
        // 会自己把 activeVideoStabilizationMode 置成 off，不会抛异常。
        func supported(_ m: AVCaptureVideoStabilizationMode) -> Bool {
            guard m != .off else { return true }
            guard let f = format else { return true }
            return f.isVideoStabilizationModeSupported(m)
        }

        let chain: [AVCaptureVideoStabilizationMode]
        switch want {
        // 电影级先试增强版（iOS 13+ 更稳），不支持再退普通电影级、标准、关
        case .cinematic: chain = [.cinematicExtended, .cinematic, .standard, .off]
        case .standard:  chain = [.standard, .off]
        case .off:       chain = [.off]
        }
        for mode in chain where supported(mode) {
            if c.preferredVideoStabilizationMode != mode {
                c.preferredVideoStabilizationMode = mode
            }
            return mode
        }
        return c.preferredVideoStabilizationMode
    }

    /// 系统返回的模式 → 界面上的三档
    private static func level(of mode: AVCaptureVideoStabilizationMode) -> Stabilization {
        switch mode {
        case .standard: return .standard
        case .cinematic, .cinematicExtended: return .cinematic
        default: return .off
        }
    }

    /// 切原相机 / 美颜。会重配输出，画面会闪一下，所以只在没录的时候调。
    func setMode(_ m: Mode) {
        cfgQ.async {
            guard self.modeFlag != m else { return }
            guard !self.movieOut.isRecording else { return }
            self.modeFlag = m
            self.session.beginConfiguration()
            self.syncAudioInputForMode()
            self.configureOutputs()
            if let dev = self.videoIn?.device {
                self.applyFormat(dev)
                // 刚换了格式（美颜 1080P ↔ 原相机 4K），支持的防抖档位也可能跟着变，
                // configureOutputs 里那次是按旧格式算的，这里要再落一次
                self.applyStabilization()
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
            // 换了分辨率/帧率，防抖支持情况会变（4K60 常常只支持到标准），要重新落一次
            self.applyStabilization()
            self.session.commitConfiguration()
            self.publishActual(dev, front: self.frontFlag)
        }
    }

    // MARK: - 配置

    // MARK: - 相机会话被系统打断

    private var observingSession = false

    /// 来电、别的 App 抢麦、切后台回来、机身过热限流，都会让会话中断一次 ——
    /// 中断期间音频和画面一起停。以前这种断流只能等看门狗摸回来，摸不回来整段就废了。
    ///
    /// v1.22 起走系统相机那套恢复路径：
    ///   · 中断结束 → 会话没在跑就拉起来，剩下的画面接着写进同一个文件
    ///     （iOS 18 起才额外调 resumeRecording；16/17 上由 AVCaptureMovieFileOutput 自己续写）；
    ///   · 运行时错误 → 同样重启一次，救不回来就把错误写到 recordingError 上。
    /// 不再靠「备份 WAV 事后补音」来掩盖中断 —— 那条路才是用户说的「存半天」。
    private func observeSessionIfNeeded() {
        guard !observingSession else { return }
        observingSession = true
        let c = NotificationCenter.default

        c.addObserver(forName: .AVCaptureSessionWasInterrupted,
                      object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            let raw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int) ?? -1
            Diag.note("相机会话被中断（\(Self.interruptText(raw))）"
                      + (self.movieOut.isRecording ? "，录制中" : ""))
            // 这里什么都不动：中断期间 session 是系统的，硬重启只会把正在写的这段打断。
            // 真正的恢复放在 interruptionEnded 里做。
            DispatchQueue.main.async {
                if self.movieOut.isRecording {
                    self.recordingError = "被系统打断了（\(Self.interruptText(raw))），会自动接着录"
                }
            }
        }

        c.addObserver(forName: .AVCaptureSessionInterruptionEnded,
                      object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            Diag.note("相机会话中断结束，尝试接着录")
            self.recoverSession(reason: "")
        }

        c.addObserver(forName: .AVCaptureSessionRuntimeError,
                      object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let code = err?.code ?? 0
            Diag.note("相机会话运行时错误 code=\(code) \(err?.localizedDescription ?? "")")
            self.recoverSession(reason: "录制被系统中断")
        }
    }

    /// 中断原因的文字版。只用于诊断日志和提示，看不懂的码原样带出来。
    private static func interruptText(_ raw: Int) -> String {
        guard let r = AVCaptureSession.InterruptionReason(rawValue: raw) else {
            return "原因未知(\(raw))"
        }
        switch r {
        case .videoDeviceNotAvailableInBackground: return "在后台"
        case .audioDeviceInUseByAnotherClient: return "麦克风被别的 App 占了"
        case .videoDeviceInUseByAnotherClient: return "摄像头被别的 App 占了"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "分屏"
        case .videoDeviceNotAvailableDueToSystemPressure: return "机身过热限流"
        default: return "原因未知(\(raw))"
        }
    }

    /// 中断/错误之后的重启。**唯一**允许在录制中碰 session 的地方，必须小心：
    ///   · 先让 session 跑起来（它没在跑，谈「接着录」没有意义）；
    ///   · 「续写」这一步是 iOS 18 才有的 API，18 以下只能靠 session.startRunning()；
    ///   · 全都失败就把话说清楚，不要让用户以为录上了。
    private func recoverSession(reason: String) {
        cfgQ.async {
            let wasRecording = self.movieOut.isRecording
            if !self.session.isRunning {
                self.session.startRunning()
            }
            // resumeRecording() 是 iOS 18 才加的（配套「手动暂停/继续」那套 UI），部署目标是 16，
            // 所以这里必须带可用性判断。iOS 16/17 上不用我们手动续写：
            // 来电/被抢占这类系统中断，AVCaptureMovieFileOutput 自己在中断恢复后会继续往
            // 同一个文件里写，我们只要把 session 拉起来就够了；硬加这行只会编译不过。
            // 别以后又把它加回来 —— 18 以下的机型压根没有这个方法。
            if #available(iOS 18.0, *),
               wasRecording, self.session.isRunning, self.movieOut.isRecording {
                self.movieOut.resumeRecording()
            }
            AudioSession.enforceForCamera()

            let running = self.session.isRunning
            let stillRecording = self.movieOut.isRecording
            Diag.note("会话恢复：running=\(running ? 1 : 0) recording=\(stillRecording ? 1 : 0)")
            guard !running else { return }
            DispatchQueue.main.async {
                if !reason.isEmpty {
                    self.recordingError = "\(reason)，这一段可能不完整"
                } else if self.recording {
                    self.recordingError = "相机没恢复过来，这一段可能不完整"
                }
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

        // native 把麦克风挂回相机会话，和系统相机一个做法：音频 input 与 video input
        // 一起进 session，AVCaptureMovieFileOutput 才会把声音写进同一个 mp4 ——
        // 停录即可用，不用事后拿备份 WAV 合成（那一步就是「存半天」）。
        // beauty 故意不挂：它走 writer，音轨由 audioOut/MicTap 喂，链路保持原样。
        if modeFlag == .native, !addAudioInput() {
            Diag.note("音频输入没挂上（授权可能刚给下来），开录前会再试一次")
        }

        applyFormat(dev)
        configureOutputs()
        publishActual(dev, front: front)
    }

    /// 加麦克风输入。首次授权那一刻音频设备常常还没就绪，`AVCaptureDeviceInput` 会直接抛错；
    /// 老代码用 `try?` 吞掉就再也没重试过，整场相机会话都是哑的 —— 这就是「第一条视频没声音」。
    ///
    /// v1.22 起 native 全程依赖这一路（movieOut 写音轨 + audioOut 喂识别），
    /// 所以调用点有三处：configure()、start() 的开跑前补挂、开录前再确认一次。
    @discardableResult
    private func addAudioInput() -> Bool {
        if audioIn != nil { return true }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            Diag.note("音频输入：没有麦克风权限")
            return false
        }
        guard let mic = AVCaptureDevice.default(for: .audio) else {
            Diag.note("音频输入：拿不到麦克风设备")
            return false
        }
        do {
            let ai = try AVCaptureDeviceInput(device: mic)
            guard session.canAddInput(ai) else {
                Diag.note("音频输入：session 装不下（可能已经在配了）")
                return false
            }
            session.addInput(ai)
            audioIn = ai
            Diag.note("音频输入：已挂进相机会话（movieOut 会一起写音轨）")
            return true
        } catch {
            Diag.note("音频输入：建不起来 \(error.localizedDescription)")
            return false
        }
    }

    /// 切模式时同步音频输入。
    ///
    /// native 要它（movieOut 写音轨 + audioOut 喂识别）；beauty 千万不能留 ——
    /// beauty 的备份 WAV 由 MicTap 写，session 的 audioOut 再往同一个文件里追加一遍，
    /// 备份就成了一段两路交错的噪声，事后补音直接毁片子。所以切到 beauty 时主动摘掉。
    private func syncAudioInputForMode() {
        if modeFlag == .native {
            _ = addAudioInput()
        } else if let ai = audioIn, !micFailed {
            // 只在独立引擎健康时才摘：如果当初正是因为引擎起不来才把麦克风挂回会话的
            // （fallbackToSessionAudio），摘掉等于把这条仅有的音频路断了。
            session.removeInput(ai)
            audioIn = nil
            Diag.note("切到美颜：音频输入已从相机会话摘掉（麦克风交给 MicTap）")
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

        // 音频数据输出两路都用：beauty 走它拿 PCM 喂 writer / 备份；
        // native 走它把同一路音频喂给跟读识别（onAudio），录制则由 movieOut 自己写。
        //
        // 同一个音频输入同时接 movieOut 和 audioOut：iOS 16 之前系统只允许一条连接活着
        // （而且是「movieOut 赢、audioOut 被停用」），16 起这个限制取消了。
        // 本工程 deployment target 是 16.0，所以两条可以同时有效 —— 万一哪天要降到 15，
        // 这里就会退化成「能录但跟读没声音」，届时必须改回别的时间轴。
        audioOut.setSampleBufferDelegate(self, queue: audioQ)
        if session.canAddOutput(audioOut) {
            session.addOutput(audioOut)
        } else if modeFlag == .native {
            Diag.note("音频输出没加进 session：这条能录，但跟读可能没反应")
        }

        // 输出刚加完，连接才存在，镜像和防抖都要在这时候设
        applyMirror()
        applyStabilization()
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

        if modeFlag == .native {
            // 原相机这条路，声音完全靠 session 里的音频输入。
            // 授权刚给下来那一下 AVCaptureDeviceInput 可能建不起来，所以开录前再确认一次：
            // 这一次没挂上，整条片子就是哑的，而哑片子事后只能靠合成去救 —— 正是要摆脱的东西。
            ensureSessionAudio { ok in
                if !ok { Diag.note("开录前麦克风输入仍然没挂上，这条可能没有声音") }
                self.beginRecordingNow(url)
            }
            return
        }

        // 美颜：独立引擎是「开录才启动」的，之前当然没有音频帧，不用在这儿等。
        // 只有退回相机自带音频的那条路，才需要在开录前先摸一下路由通不通。
        if micFailed {
            let age = CACurrentMediaTime() - lastAudioFrameAt
            if age > 1.0 {
                Diag.note("开录前 \(String(format: "%.1f", age)) 秒没音频帧，先修路由")
                AudioSession.enforceForCamera()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    self?.beginRecordingNow(url)
                }
                return
            }
        }
        beginRecordingNow(url)
    }

    /// 确认 session 里挂着麦克风输入。已经在就立刻回调，不在就补一次。
    /// 补完不用在这儿重设镜像/防抖：beginNativeRecording 开录前会整条重设一遍。
    private func ensureSessionAudio(_ done: @escaping (Bool) -> Void) {
        cfgQ.async {
            if self.audioIn != nil {
                DispatchQueue.main.async { done(true) }
                return
            }
            self.session.beginConfiguration()
            let ok = self.addAudioInput()
            self.session.commitConfiguration()
            DispatchQueue.main.async { done(ok) }
        }
    }

    private func beginRecordingNow(_ url: URL) {
        // 上一次收尾可能因为异常没走到 deliver，这里把状态清干净，
        // 否则新的一条一开录就会被「等整理完再停会话」卡住
        finishing = false
        stopPending = false
        stopFallback?.cancel()
        stopFallback = nil

        // 音频会话先摆到位，再启动麦克风引擎：录制中途一次 setCategory
        // 就能把 AVAudioEngine 踹停，顺序反了等于白开
        AudioSession.keepAlive()
        audioStartHost = mach_absolute_time()

        // 开录后一秒半还是没有音频帧：基本就是麦克风这条路断了，先把话说在前面。
        // 不去打断录制（画面还在录，说不定后面恢复），只把提示留下。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.recording, self.audioFrameCount == 0 else { return }
            self.recordingError = "麦克风没在出数据，这条可能没有声音"
            Diag.note("录制中 1.5 秒无音频帧")
            AudioSession.enforceForCamera()
        }

        if modeFlag == .native {
            // 系统相机同款：音视频由 movieOut 一起写，不起 MicTap、不写备份 WAV。
            beginNativeRecording(url: url)
            return
        }

        beginAudioBackup()

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

    private func beginNativeRecording(url: URL) {
        cfgQ.async {
            guard self.movieOut.isRecording == false else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            AudioSession.keepAlive()
            if let c = self.movieOut.connection(with: .video), c.isVideoOrientationSupported {
                c.videoOrientation = .portrait
            }
            // 录制开始前再确认一次镜像和防抖：切镜头会重建连接，这两样都挂在连接上
            self.applyMirror()
            self.applyStabilization()

            // 没有可用的视频连接时 startRecording 会直接抛 Objective-C 异常（闪退），先确认再开
            guard let vc = self.movieOut.connection(with: .video), vc.isEnabled else {
                DispatchQueue.main.async {
                    self.recording = false
                    self.recordingError = "画面还没准备好，再点一次"
                }
                return
            }

            // 音频连接在不在，决定了这条片子有没有声音
            let micOK: Bool
            if let ac = self.movieOut.connection(with: .audio) {
                micOK = ac.isEnabled && self.audioIn != nil
            } else {
                micOK = false
            }

            try? FileManager.default.removeItem(at: url)
            // 先真开录，再把「正在录」这套状态发到界面。
            // 以前是在 startRecording 之前 main.async 置状态，那个异步块可能晚于开录执行，
            // 会把开录后看门狗刚写进去的提示又冲掉（或反过来冲掉它的提示），
            // 变成「有时提示在、有时不在」。顺序定死：先落盘开录 → 再推状态。
            self.startNativeWatch()
            self.movieOut.startRecording(to: url, recordingDelegate: self)
            // 注意用 async 不用 sync：cfgQ 上同步等主线程，主线程若正卡在等 cfgQ 就会死锁
            DispatchQueue.main.async {
                self.recordingError = micOK ? "" : "麦克风没接上，这条可能没有声音"
                self.recording = true
            }
        }
    }

    /// 开录时把上一次 beauty 留下的备份清干净，并开始盯音频。
    ///
    /// 为什么要清：native 根本不写备份，可「音轨校验」那条兜底会去读 backupURL ——
    /// 上一次美颜录制的旧 WAV 要是还在，就可能把上一段的声音合成到这条片子上。
    private func startNativeWatch() {
        audioQ.async {
            self.backupOn = false
            // 先把可能还开着的句柄关掉（上一次 beauty 被中断时留下的），再清地址和计数
            self.closeBackupFile()
            self.backupURL = nil
            self.backupFrames = 0

            self.watchOn = true
            self.audioWarned = false
            self.audioNextRetry = 0
            // 用「现在」当基准，别拿上一次录制留下的旧时间戳算断流
            self.lastAudioFrameAt = CACurrentMediaTime()

            self.nativeWatch?.cancel()
            let t = DispatchSource.makeTimerSource(queue: self.audioQ)
            t.schedule(deadline: .now() + 1.2, repeating: 0.5)
            t.setEventHandler { [weak self] in
                guard let self, self.watchOn else { return }
                let now = CACurrentMediaTime()
                let gap = now - self.lastAudioFrameAt
                // 最多每 2 秒抢一次：反复 setCategory 本身就会打断采集
                guard gap > 1.2, now >= self.audioNextRetry else { return }
                self.audioNextRetry = now + 2.0
                // 只重新激活音频路由，绝不动 session —— 一停就把这段录制收尾了
                let changed = AudioSession.enforceForCamera()
                if !self.audioWarned {
                    self.audioWarned = true
                    Diag.note(String(format: "原相机录音断流 %.1fs，已重新激活音频路由%@",
                                     gap, changed ? "（换了类别）" : ""))
                }
            }
            self.nativeWatch = t
            t.resume()
        }
    }

    private func stopNativeWatch() {
        audioQ.async {
            self.watchOn = false
            self.nativeWatch?.cancel()
            self.nativeWatch = nil
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
            stopNativeWatch()
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

            // 麦克风这条路单独启动，和相机没有关系
            self.startMic()

            // 录制中盯着麦克风。阈值收到 0.7 秒：识别一句话说完会重开请求，
            // 那一下最容易把音频会话带偏，早一点抢回来还有救，晚两秒就整段哑了。
            self.audioWarned = false
            self.audioNextRetry = 0
            let t = DispatchSource.makeTimerSource(queue: self.audioQ)
            t.schedule(deadline: .now() + 0.6, repeating: 0.4)
            t.setEventHandler { [weak self] in
                guard let self, self.backupOn else { return }

                // 硬件配置变了（插拔耳机、系统重配）：引擎这时候已经停了，
                // 但不报错、只是不再出数据。要立刻重开，不能等断流判断。
                if !self.micFailed, self.mic.needsRestart {
                    let ok = self.mic.restart()
                    Diag.note("音频硬件配置变了，重开引擎\(ok ? "成功" : "失败")")
                    if !ok {
                        self.micFailed = true
                        self.fallbackToSessionAudio()
                    }
                    return
                }

                // 一帧都没来过时按「从开录算到现在」算，否则永远进不了恢复逻辑
                let now = CACurrentMediaTime()
                let gap = self.lastAudioAt > 0 ? now - self.lastAudioAt : now - self.recordStartAt
                // 最多每 1.5 秒抢一次：反复 setCategory 本身就会打断采集，
                // 抢得太勤反而把刚恢复的 I/O 又踹一脚。
                guard gap > 0.7, now >= self.audioNextRetry else { return }
                self.audioNextRetry = now + 1.5

                if self.micFailed {
                    let changed = AudioSession.enforceForCamera()
                    if !self.audioWarned {
                        self.audioWarned = true
                        Diag.note(String(format: "录音断流 %.1fs，已强制恢复音频路由%@",
                                         gap, changed ? "（换了类别）" : ""))
                    }
                    return
                }

                // 独立引擎不出数据了：它跟相机无关，重开一次基本就能回来。
                // 时间基准固定不动，重开前后接在同一条时间轴上。
                let ok = self.mic.restart()
                Diag.note(String(format: "录音断流 %.1fs，重开独立引擎%@", gap, ok ? "成功" : "失败"))
                if !ok {
                    self.micFailed = true
                    self.fallbackToSessionAudio()
                }
            }
            self.audioWatch?.cancel()
            self.audioWatch = t
            t.resume()
        }
    }

    // MARK: - 独立麦克风

    /// 启动独立麦克风引擎，把每一帧接到备份文件上。
    private func startMic() {
        mic.onBuffer = { [weak self] pcm, sec in
            guard let self else { return }
            self.audioQ.async {
                self.lastAudioFrameAt = CACurrentMediaTime()
                self.audioFrameCount += 1
                self.handleMicBuffer(pcm, at: sec)
            }
        }

        if mic.start(videoStartHost: audioStartHost) {
            micFailed = false
            Diag.note("麦克风：独立引擎已启动 \(Int(mic.sampleRate))Hz/\(mic.channels)ch")
        } else {
            micFailed = true
            Diag.note("麦克风：独立引擎起不来（\(mic.lastError)），退回相机音频")
            fallbackToSessionAudio()
        }
    }

    /// 独立引擎来的一帧：按它自己的时间戳落位写进备份。
    private func handleMicBuffer(_ pcm: AVAudioPCMBuffer, at sec: Double) {
        guard backupOn else { return }
        let fmt = pcm.format
        let ch = Int(fmt.channelCount)
        guard ch > 0, fmt.sampleRate > 8000 else { return }

        if firstAudioPts < 0 {
            // 第一帧才知道「比视频晚多少」（引擎启动本身要几十毫秒）。
            // 把这段空档补成静音，备份的时间轴就从视频的 0 秒开始算。
            primeBackup(rate: fmt.sampleRate, channels: ch, pad: sec)
        }
        appendAudioBackup(pcm, pts: CMTime(seconds: max(0, sec), preferredTimescale: 600_000))

        // 这一帧同时喂给语音识别（提词跟读）。
        // 以前 onAudio 是靠相机会话的音频输出回调触发的；麦克风搬到独立引擎后，
        // 相机那条路不再有音频帧，这里不补一句，跟读就等于聋了。
        onAudio?(pcm)
    }

    /// 给备份文件定格式，并把开头那段「引擎还没启动完」的空档补成静音。
    private func primeBackup(rate: Double, channels: Int, pad: Double) {
        guard backupOn, let h = backupHandle, firstAudioPts < 0 else { return }
        guard rate > 8000, channels > 0 else { return }

        backupRate = rate
        backupChannels = channels
        firstAudioPts = 0
        offsetFixed = true
        backupOffset = 0

        let frames = Int((min(max(pad, 0), 1.0) * rate).rounded())
        if frames > 0 {
            writeZeros(frames, channels: channels, handle: h)
        }
    }

    /// 独立引擎彻底起不来时的退路：把音频接回相机会话（老路径）。
    private func fallbackToSessionAudio() {
        cfgQ.async {
            guard self.audioIn == nil else { return }
            self.session.beginConfiguration()
            let ok = self.addAudioInput()
            self.session.commitConfiguration()
            Diag.note("回退：音频挂回相机会话\(ok ? "成功" : "失败")")
            if ok { AudioSession.enforceForCamera() }
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
        // 先停独立麦克风，保证不再往队列里塞新帧；
        // 已经排队的帧会在下面这段之前写完。
        mic.onBuffer = nil
        mic.stop()
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

        guard let data = Self.pcm16Data(pcm) else {
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

    /// 任意 PCM → 16 位小端交错。
    ///
    /// 旧版是「每个采样点调一次 `withUnsafeBytes` 再 append 到 Data」：48kHz 单声道
    /// 一秒就是 4.8 万次闭包 + 4.8 万次 Data 扩容判断，全压在录音线程上。
    /// 录几分钟机身一热，这条线程跟不上，表现就是声音断流、备份缺帧。
    /// 现在先一次分配 Int16 数组、裸指针写入，最后整块转 Data，量一样但开销降一个数量级。
    private static func pcm16Data(_ pcm: AVAudioPCMBuffer) -> Data? {
        let fmt = pcm.format
        let frames = Int(pcm.frameLength)
        let ch = Int(fmt.channelCount)
        guard frames > 0, ch > 0 else { return nil }

        var samples = [Int16](repeating: 0, count: frames * ch)
        let ok = samples.withUnsafeMutableBufferPointer { out -> Bool in
            guard let dst = out.baseAddress else { return false }

            switch fmt.commonFormat {
            case .pcmFormatFloat32:
                guard let src = pcm.floatChannelData else { return false }
                if fmt.isInterleaved {
                    let p = src[0]
                    for i in 0..<(frames * ch) {
                        let v = max(-1, min(1, p[i]))
                        dst[i] = Int16(v * 32767)
                    }
                } else {
                    for c in 0..<ch {
                        let p = src[c]
                        for i in 0..<frames {
                            let v = max(-1, min(1, p[i]))
                            dst[i * ch + c] = Int16(v * 32767)
                        }
                    }
                }
                return true

            case .pcmFormatInt16:
                guard let src = pcm.int16ChannelData else { return false }
                if fmt.isInterleaved {
                    let p = src[0]
                    for i in 0..<(frames * ch) { dst[i] = p[i] }
                } else {
                    for c in 0..<ch {
                        let p = src[c]
                        for i in 0..<frames { dst[i * ch + c] = p[i] }
                    }
                }
                return true

            default:
                return false
            }
        }
        guard ok else { return nil }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
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

    // MARK: - 原相机停录后的自检

    /// native 停录后只做一件事：确认这条 mp4 里到底有没有音轨。
    ///
    /// 正常情况下 session 挂着麦克风、movieOut 把音视频一起写，这一步是「读一下文件头」
    /// 级别的开销，**不做任何合成**，所以停录即可交付 —— 用户抱怨的「存半天」就是
    /// 以前那条无条件补音链路。
    ///
    /// 万一音轨真的没写进去（极少见：音频连接恰好在这一条开始时没建起来），
    /// 有备份就用备份合成，没有就把话说清楚，绝不静默交付一条哑片。
    private func verifyNativeAudio(_ video: URL, done: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let asset = AVURLAsset(url: video)
            let hasAudio = !asset.tracks(withMediaType: .audio).isEmpty
            let len = asset.duration.seconds
            Diag.note("原相机成片：\(String(format: "%.1f", len))s 音轨="
                      + (hasAudio ? "有（直接交付，不合成）" : "无（走兜底）"))

            guard !hasAudio else {
                DispatchQueue.main.async {
                    // 成片确实有声，就把开录时看门狗 / 中断路径留下的旧提示清掉 ——
                    // 否则用户会看到「明明有声音，界面还在喊没声音」。
                    self.recordingError = ""
                    done(video)
                }
                return
            }

            // 走到这里说明这一条确实是哑的，只能走老路：有备份就补，没备份就报清楚。
            // 提示直接换成这一条的事实描述，不要把旧文案（比如「麦克风没在出数据」）留在界面上。
            DispatchQueue.main.async {
                self.recordingError = "这条没录到声音，画面已保存"
                self.tidying = true
                self.repairAudioIfNeeded(video) { url in
                    self.tidying = false
                    done(url)
                }
            }
        }
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
                let av = AVURLAsset(url: video)
                let hasAudio = !av.tracks(withMediaType: .audio).isEmpty
                Diag.note("没有可用备份，成片音轨=\(hasAudio ? "有" : "无")")
                if !hasAudio {
                    DispatchQueue.main.async { self.recordingError = "这条没录到声音，建议重录" }
                }
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
                     mustFix: Bool, preferPCM: Bool = false,
                     done: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // ① 备份是 WAV（PCM），mp4 容器装不了。先单独编码成 AAC——
            //    只要音轨是 AAC，整个片子就能走 passthrough：视频一个像素都不重编码。
            //    旧版一律 HighestQuality，4K 片子要重压十几秒，用户以为卡死了。
            let t0 = CACurrentMediaTime()
            // preferPCM：上一轮 AAC 音轨插不进合成时的兜底，直接用原始 WAV。
            // mp4 装不了 PCM，会走重编码，慢一些但基本不会失败。
            let aac = preferPCM ? nil : self.encodeAAC(audio)
            Diag.note("音频准备：\(preferPCM ? "改用 WAV 原始音频" : "AAC")"
                      + (aac == nil && !preferPCM ? "失败" : "成功")
                      + "，耗时 " + String(format: "%.1fs", CACurrentMediaTime() - t0))
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
            do {
                try vt2.insertTimeRange(CMTimeRange(start: .zero, duration: vd), of: vt, at: .zero)
            } catch {
                Diag.note("合成失败：视频轨插入出错 \(error.localizedDescription)")
                DispatchQueue.main.async { done(video) }
                return
            }
            vt2.preferredTransform = vt.preferredTransform

            // 音轨按「视频还剩多长」和「备份实际多长」里较短的那个插。
            // 旧版只按视频算长度：备份短了几十毫秒，insertTimeRange 就会整段失败，
            // try? 把错误吞掉之后成片干脆没有音轨——「补了个寂寞」就是这么来的。
            let start = CMTime(seconds: offset, preferredTimescale: 600)
            let aRange = at.timeRange
            let room = max(0, vd.seconds - offset)
            let len = min(room, aRange.duration.seconds)
            // 这里以前是 try?：插入失败被吞掉，日志照样打「实插 13.6s」，
            // 结果导出一条没有音轨的片子，用户听到的就是「补了还是没声音」。
            var inserted = false
            var insertError = ""
            if len > 0.1 {
                do {
                    try at2.insertTimeRange(CMTimeRange(start: aRange.start,
                                                        duration: CMTime(seconds: len, preferredTimescale: 600)),
                                            of: at,
                                            at: start)
                    inserted = true
                } catch {
                    insertError = error.localizedDescription
                }
            } else {
                insertError = "可用长度不足（\(String(format: "%.2f", len))s）"
            }
            Diag.note("合成：视频 \(String(format: "%.1f", vd.seconds))s 备份 "
                      + "\(String(format: "%.1f", aRange.duration.seconds))s 偏移 "
                      + String(format: "%.2f", offset) + "s 实插 "
                      + String(format: "%.1f", len) + "s "
                      + (inserted ? "音轨已插入" : "音轨插入失败：\(insertError)"))

            // 没插上就别导出了：导出来的一定是一条没声的片子。如果这次用的是
            // AAC，先退回原始 WAV 再试一次——AAC 轨道偶尔会因容器差异插不进去，
            // PCM 没这个问题（代价是整片重编码，短片子很快）。
            guard inserted else {
                if !preferPCM {
                    Diag.note("AAC 音轨插入失败，改用 WAV 原始音频再试一次")
                    self.mux(video: video, audio: audio, offset: offset,
                             mustFix: true, preferPCM: true, done: done)
                    return
                }
                DispatchQueue.main.async {
                    self.recordingError = "补音轨没成功（插入失败），这条可能没声音"
                    done(video)
                }
                return
            }

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
            // 替换完再验一遍。只看到「导出成功」是不够的：replaceItemAt 有可能不抛错
            // 却没真正换上去，也可能换上去的文件音轨是空的。用户要的只有一件事——
            // 这条到底有没有声音，所以直接读最终文件确认。
            let check = SilenceCut.statsSampled(video)
            let audible = check.duration >= vd.seconds * 0.9 && check.peak > -52
            Diag.note("成片自检：音轨="
                      + String(format: "%.1fs/%.0fdB", check.duration, check.peak)
                      + " 视频=\(String(format: "%.1fs", vd.seconds))"
                      + " 替换=\(replaced ? "成功" : "失败")"
                      + " 判定=\(audible ? "有声" : "仍然没声")")

            DispatchQueue.main.async {
                if audible {
                    // 成功就静默——用户只需要听到声音，不需要知道过程
                    self.recordingError = ""
                } else if !replaced {
                    self.recordingError = "音轨补好了，但没能替换进成片，去作品里删掉这条重录"
                } else {
                    self.recordingError = "补完音轨还是没声音，建议重录一条"
                }
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

        // native 这一路只负责两件事：把格式/时间戳记下来，并把 PCM 交给跟读识别。
        // 录制的音轨由 movieOut 自己从同一个音频输入写，这里不碰（backupOn 在 native 恒为 false）。
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
        let errMsg = msg
        let video = outputFileURL

        // 这里在系统自己的线程上，不能直接读 modeFlag（约定是只在 cfgQ 上读写）。
        // 直接读是数据竞争：极端情况下正好赶上切模式，会把 beauty 的片子当 native 处理
        // （少一次补音，成片是哑的）。所以分流整段挪到 cfgQ 上做决定。
        // 注意：只往 main / audioQ 里 async，绝不 sync 回 cfgQ，否则自己等自己死锁。
        cfgQ.async {
            let wasNative = self.modeFlag == .native
            if wasNative { self.stopNativeWatch() }

            DispatchQueue.main.async {
                self.recording = false
                if !errMsg.isEmpty { self.recordingError = errMsg }
                guard finished else {
                    self.endAudioBackup { _, _ in }
                    self.deliver(nil)
                    return
                }

                if wasNative {
                    // 系统相机同款：音视频本来就在同一个文件里，确认音轨在就立刻交付。
                    self.verifyNativeAudio(video) { url in
                        self.deliver(url)
                    }
                    return
                }

                // 美颜这条路保持原样：writer 的音轨可能缺，靠备份 PCM 补
                self.repairAudioIfNeeded(video) { url in
                    self.deliver(url)
                }
            }
        }
    }

    /// 会话被中断时系统会把正在写的这段暂停一下。恢复由 recoverSession 做，
    /// 这里只留记录，方便对着诊断日志看中断时间点。
    func fileOutput(_ output: AVCaptureFileOutput,
                    didPauseRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        Diag.note("录制被暂停（相机会话中断）")
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didResumeRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        Diag.note("录制已接着录")
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
