import AVFoundation
import Foundation

/// 独立麦克风采集。
///
/// ── 为什么要单独一路 ──────────────────────────────────────────
/// 以前音频是挂在 AVCaptureSession 上的（AVCaptureAudioDataOutput）。
/// 问题在于：这个 session 是「视频 + 音频」一起跑的，只要它整体出状况——
/// 来电、蓝牙耳机断开、切后台、录 4K 录久了机身发热限流——音频连接会先被牺牲，
/// 画面还在写，声音这条路就死了。而且死了之后 `AVAudioSession` 怎么重设类别
/// 都救不回来，因为 AVCaptureSession 的 audio connection 不会自己重建。
///
/// 所以这里把麦克风彻底搬出来：AVAudioEngine 的 inputNode 直接拿 PCM，
/// 不经过相机那条管线。相机崩了、降频了、被中断了，录音照走。
///
/// 对外只做一件事：把每一小块 PCM 和它「相对开录时刻」的秒数交出去。
final class MicTap {

    private let engine = AVAudioEngine()
    private var tapInstalled = false

    /// 开录那一刻的 hostTime。所有音频时间都相对它算，重启引擎也不会漂。
    private var startHost: UInt64 = 0

    private(set) var running = false
    private(set) var bufferCount = 0
    private(set) var lastBufferAt: CFTimeInterval = 0
    private(set) var lastError = ""
    private(set) var sampleRate: Double = 0
    private(set) var channels: Int = 0

    /// 系统把音频硬件配置改了（插拔耳机、切路由、相机抢占后重配）。
    /// 这时候引擎已经停了，但不会报错，只是不再出数据 —— 得有人来重启它。
    private(set) var needsRestart = false
    private var configObserver: NSObjectProtocol?

    /// 第二参数是相对开录时刻的秒数（用于对齐视频时间轴）
    var onBuffer: ((AVAudioPCMBuffer, Double) -> Void)?

    /// 开始采集。videoStartHost 传开录时刻的 `mach_absolute_time()`。
    @discardableResult
    func start(videoStartHost: UInt64) -> Bool {
        stop()
        startHost = videoStartHost
        lastError = ""
        bufferCount = 0
        needsRestart = false

        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                self?.needsRestart = true
            }
        }

        // 先把音频会话点亮，否则 inputNode 报出来的格式是 0Hz/0ch。
        // 这里不判断「别的 App 正在放音」——录制优先，宁可打断它。
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            lastError = "音频会话起不来：\(error.localizedDescription)"
        }

        let input = engine.inputNode
        var fmt = input.outputFormat(forBus: 0)
        if fmt.sampleRate < 8000 || fmt.channelCount == 0 {
            // 有些机型刚切完路由，这里要等一拍才报正常格式，退到硬件格式再试
            fmt = input.inputFormat(forBus: 0)
        }
        guard fmt.sampleRate > 8000, fmt.channelCount > 0 else {
            lastError = "麦克风格式不可用（\(Int(fmt.sampleRate))Hz/\(fmt.channelCount)ch）"
            return false
        }
        sampleRate = fmt.sampleRate
        channels = Int(fmt.channelCount)

        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, time in
            guard let self else { return }
            self.lastBufferAt = CACurrentMediaTime()
            self.bufferCount += 1
            self.onBuffer?(buf, self.seconds(of: time, fallbackRate: fmt.sampleRate))
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
            running = true
            return true
        } catch {
            lastError = "引擎启动失败：\(error.localizedDescription)"
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            return false
        }
    }

    /// 断流之后重开。时间基准保持不变，所以重启前后的音频还能接在同一条时间轴上。
    @discardableResult
    func restart() -> Bool {
        start(videoStartHost: startHost)
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        running = false
    }

    /// 把这一帧的时间换算成「距离开录多少秒」。
    /// hostTime 是最准的；拿不到就退回采样点数，两者都拿不到就当 0。
    private func seconds(of time: AVAudioTime, fallbackRate: Double) -> Double {
        if time.isHostTimeValid, startHost > 0, time.hostTime >= startHost {
            return AVAudioTime.seconds(forHostTime: time.hostTime - startHost)
        }
        if time.isSampleTimeValid, fallbackRate > 0 {
            return Double(time.sampleTime) / fallbackRate
        }
        return 0
    }
}
