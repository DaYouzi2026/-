import Foundation
import Speech
import AVFoundation
import Combine

/// 语音识别（Apple 自带 SFSpeechRecognizer）。
/// 音频来自相机的 AVCaptureAudioDataOutput，不另外开 AVAudioEngine，避免抢麦。
///
/// ── v1.8 重写：修「识别很不准」───────────────────────────────
/// v1.7 这里有个致命的死循环：`newRequest()` 一进来就 `task?.cancel()`，而被取消的
/// 任务必定回调一个 "cancelled" 错误；回调里看到错误又去 `restartSoon()` —— 于是
/// **每 0.35 秒就把识别请求重建一次**。识别器永远攒不到一段完整的音频，只能吐出
/// 几个字、甚至一个字都吐不出来，界面上的「跟读」自然一步都不走。
///
/// 现在做了六件事：
///   ① 每个请求带一个代号（gen），旧请求的回调一律丢弃，取消不再触发重建；
///   ② 把台本里游标附近的原句作为 contextualStrings 喂给识别器，
///      同音字、人名、专有名词的命中率会明显提高（读稿场景收益最大）；
///   ③ 默认走 Apple 的在线识别（中文比离线模型准一截），连续失败自动退回离线；
///   ④ 音频统一重采样成 16kHz 单声道 float 再喂（相机给的是 44.1k/48k，转一下更稳）；
///   ⑤ 看门狗：单请求 55 秒换新（系统有时长上限）、20 秒没结果就重开、
///      6 秒收不到音频就明说「没收到麦克风」，不再假装在工作；
///   ⑥ 识别到的原文挂在 `heard` 上，状态条可以直接看到它认成了什么。
final class SpeechFollower: ObservableObject {

    @Published private(set) var status = ""
    @Published private(set) var running = false
    /// true = 离线（本机模型），false = 在线（Apple 服务器）
    @Published private(set) var onDevice = false
    /// 刚听到的一句原文，方便用户/我确认它到底认成了什么
    @Published private(set) var heard = ""

    var onText: ((String) -> Void)?
    var onFail: ((String) -> Void)?

    /// 台本里游标附近的一批短句，用来当识别提示词。每次换请求取一次。
    var hints: (() -> [String])?

    private let recognizer: SFSpeechRecognizer? = {
        let r = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        r?.defaultTaskHint = .dictation
        return r
    }()

    /// 只保护 request 这一个跨线程共享对象；其它状态全在主线程
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var gen = 0
    private var wantRun = false
    private var usingOnDevice = false
    private var forceOnDevice = false
    private var fails = 0
    private var startedAt = Date()
    private var lastResultAt = Date()
    private var lastAudioAt = Date()
    private var lastRestartAt = Date.distantPast
    private var timer: Timer?
    /// 上一句识别结果的尾巴。识别请求一重开，transcript 就从零开始——
    /// 这时探针只剩两三个字，对齐根本不敢往前挪（这就是「读了不翻页」的机器原因）。
    /// 把上一句最后十个字留作前缀，探针就永远是十几个字，能立刻追上。
    private var carry = ""
    private var lastText = ""
    private var lastTextAt = Date.distantPast

    // 重采样到 16k 单声道
    private let pcm16k = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 16000,
                                      channels: 1,
                                      interleaved: false)
    private var conv: AVAudioConverter?
    private var convIn: AVAudioFormat?
    /// nil = 这一段请求还没喂过音频；true/false = 这一段统一用转换后 / 原始格式
    private var convOK: Bool?

    // MARK: - 权限

    static func requestAuth(_ done: @escaping (Bool, String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { st in
            DispatchQueue.main.async {
                switch st {
                case .authorized:
                    done(true, "")
                case .denied:
                    done(false, "语音识别权限被关了，去 设置 › 提词大师 打开")
                case .restricted:
                    done(false, "这台设备限制了语音识别")
                case .notDetermined:
                    done(false, "还没给语音识别权限")
                @unknown default:
                    done(false, "语音识别不可用")
                }
            }
        }
    }

    // MARK: - 启停

    func start() {
        guard let rec = recognizer else {
            onFail?("这台设备的系统没有中文语音识别")
            return
        }
        guard rec.isAvailable else {
            onFail?("语音识别暂时不可用，稍等再试")
            return
        }
        // 设置里勾了「只用本机识别」就一直走离线模型，不再为了准去偷跑联网。
        // 这是隐私承诺：开关打开时，音频一个字节都不出这台手机。
        if UserDefaults.standard.bool(forKey: Pref.speechOnDevice) {
            if rec.supportsOnDeviceRecognition {
                forceOnDevice = true
            } else {
                onFail?("这台设备还没装中文离线模型，关掉「只用本机识别」才能跟读")
                return
            }
        } else {
            forceOnDevice = false
        }
        if wantRun && running { return }
        carry = ""
        lastText = ""
        wantRun = true
        running = true
        fails = 0
        heard = ""
        lastAudioAt = Date()
        newRequest(rec)
        startTimer()
    }

    func stop() {
        wantRun = false
        running = false
        gen += 1                     // 让所有在途回调失效
        timer?.invalidate()
        timer = nil
        lock.lock()
        let r = request
        let t = task
        request = nil
        task = nil
        lock.unlock()
        r?.endAudio()
        t?.cancel()
        carry = ""
        lastText = ""
        status = ""
        heard = ""
    }

    // MARK: - 请求

    private func newRequest(_ rec: SFSpeechRecognizer) {
        gen += 1
        let my = gen

        lock.lock()
        let old = task
        request = nil
        task = nil
        lock.unlock()
        // 用 finish 而不是 cancel：cancel 会让识别器立刻收摊，顺手把音频会话也放掉，
        // 相机那一路采集就跟着断了——这正是「录三秒还有声、录久了就没声」的现场。
        // finish 是温和收尾，音频资源不会当场被回收。
        old?.finish()

        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        r.addsPunctuation = false
        r.taskHint = .dictation
        r.requiresOnDeviceRecognition = forceOnDevice
        usingOnDevice = forceOnDevice
        onDevice = usingOnDevice
        if let list = hints?(), !list.isEmpty {
            r.contextualStrings = Array(list.prefix(60))
        }

        // 把上一句的尾巴接过来当上下文（太久以前的就丢掉，免得跑到别的段落还被拽回来）
        let stale = Date().timeIntervalSince(lastTextAt) > 12
        let kept = lastText.filter { PreparedScript.keep($0) }
        carry = (stale || kept.isEmpty) ? "" : String(kept.suffix(10))
        lastText = ""

        // 换请求就重来一遍格式判断，别让上一段的转换状态漏过来
        conv = nil
        convIn = nil
        convOK = nil

        lock.lock()
        request = r
        lock.unlock()

        startedAt = Date()
        lastResultAt = Date()

        let t = rec.recognitionTask(with: r) { [weak self] result, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.gen == my, self.wantRun else { return }
                if let result = result {
                    self.fails = 0
                    self.lastResultAt = Date()
                    let text = result.bestTranscription.formattedString
                    if !text.isEmpty {
                        self.heard = text
                        self.lastText = text
                        self.lastTextAt = Date()
                        self.status = self.usingOnDevice ? "离线识别中" : "在线识别中"
                        self.onText?(self.composed(text))
                    }
                    if result.isFinal {
                        // 一句话说完了，系统这个请求也结束了，换一个新的接着听。
                        // 空结果又秒结束的，多半是刚开就没收到音频，缓一拍再开，别空转。
                        let lived = Date().timeIntervalSince(self.startedAt)
                        let wait: TimeInterval = (text.isEmpty && lived < 1) ? 0.6 : 0.15
                        self.scheduleRestart(rec, after: wait)
                    }
                } else if let error = error {
                    self.handle(error as NSError, rec: rec)
                }
            }
        }

        lock.lock()
        task = t
        lock.unlock()

        // 录制中重开识别：给它 0.2 秒落定，再把音频路由抢回「录视频」那一套。
        // 不做这一步的话，识别每说完一句就把会话带偏一次，相机的麦克风再也回不来。
        if AudioSession.cameraBusy {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard self?.wantRun == true, AudioSession.cameraBusy else { return }
                AudioSession.enforceForCamera()
            }
        }
    }

    /// 新请求刚开头的两三个字，前面补上上一句的尾巴，凑够能被信任的探针长度。
    /// 一旦这一句自己长到六个字以上，就不需要拐杖了，果断丢掉。
    ///
    /// v1.13：重开请求时识别器偶尔会先把上一句的尾巴再吐一遍，拼起来就是
    /// 「今天我们来聊」+「聊今天我们来聊」这种重复片段。对齐那边看到两遍同样的字，
    /// 会以为人已经念到下一处相同的话了，位置就飘了。这里把重复的头砍掉。
    /// v6：这里原来还会把 `carry`（上一句的最后十个字）**拼到新句子前面**，当「探针拐杖」。
    ///
    /// 那是个坏主意，原因在 Align 那边：它只取累积文本的**最后 14 个字**做模糊匹配。
    /// 新句刚开口两三个字时，这 14 个字里十来个是上一句的尾巴 —— 而上一句的尾巴在
    /// 当前位置是完美匹配的，于是「读完了它不动」；更糟的是「上句尾巴＋新句开头」这种
    /// 混合串在台本别处找到更便宜的匹配，光标就整段跳过去。这就是「到处跑」。
    ///
    /// 现在只做一件事：把重开请求时识别器重复吐出来的上一句尾巴砍掉。
    /// 新句开头探针短，推进慢一点（一次两三个字），但位置不会错。
    private func composed(_ text: String) -> String {
        var kept = String(text.filter { PreparedScript.keep($0) })
        if carry.isEmpty { return kept }

        let c = Array(carry)
        var overlap = 0
        var len = min(c.count, kept.count)
        while len >= 3 {
            if Array(c.suffix(len)) == Array(kept.prefix(len)) {
                overlap = len
                break
            }
            len -= 1
        }
        if overlap > 0 { kept = String(kept.dropFirst(overlap)) }
        return kept
    }

    private func handle(_ e: NSError, rec: SFSpeechRecognizer) {
        // 216 = 请求被自己取消，1110 = 没听到语音就结束了。都不是真故障
        if e.domain == "kAFAssistantErrorDomain" && e.code == 216 { return }
        if e.domain == "kAFAssistantErrorDomain" && e.code == 1110 {
            scheduleRestart(rec, after: 0.4)
            return
        }

        fails += 1

        // 在线识别不通（没网 / 被限流）：换本机离线模型，不要一失败就整个停掉
        if !usingOnDevice && fails >= 2 && rec.supportsOnDeviceRecognition {
            forceOnDevice = true
            status = "网络识别不通，已换离线"
            scheduleRestart(rec, after: 0.3)
            return
        }
        if fails >= 5 {
            wantRun = false
            running = false
            status = ""
            onFail?("语音识别反复失败：" + e.localizedDescription)
            return
        }
        scheduleRestart(rec, after: 0.35)
    }

    private func scheduleRestart(_ rec: SFSpeechRecognizer, after: TimeInterval) {
        guard wantRun else { return }
        let now = Date()
        if now.timeIntervalSince(lastRestartAt) < 0.2 { return }   // 防抖
        lastRestartAt = now
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
            guard let self = self, self.wantRun else { return }
            self.newRequest(rec)
        }
    }

    // MARK: - 看门狗

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard wantRun, let rec = recognizer else { return }
        let now = Date()

        // 单个请求有 1 分钟上下的上限，到点主动换，别等它自己断
        if now.timeIntervalSince(startedAt) > 55 {
            scheduleRestart(rec, after: 0)
            return
        }

        // 二十秒一个字都没有：识别器在后台死了（切后台、来电、系统回收）
        if now.timeIntervalSince(lastResultAt) > 20 {
            status = "识别没反应，正在重开"
            lastResultAt = now
            scheduleRestart(rec, after: 0)
            return
        }

        // 麦克风彻底没数据：相机没开 / 权限被收走
        if audioAge() > 6 {
            status = "没收到麦克风音频"
        }
    }

    private func audioAge() -> TimeInterval {
        lock.lock()
        let t = lastAudioAt
        lock.unlock()
        return Date().timeIntervalSince(t)
    }

    // MARK: - 音频

    /// 相机每来一帧音频就喂进来（在相机自己的音频队列上调用）
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard running, buffer.frameLength > 0 else { return }
        lock.lock()
        let r = request
        if r != nil { lastAudioAt = Date() }
        lock.unlock()
        guard let req = r else { return }

        // 同一段请求里只允许一种格式，混着喂会让识别器直接罢工
        if convOK == false {
            req.append(buffer)
            return
        }
        if convOK == nil {
            if let out = resample(buffer) {
                convOK = true
                req.append(out)
            } else {
                convOK = false
                req.append(buffer)
            }
            return
        }
        if let out = resample(buffer) { req.append(out) }
    }

    /// 转成 16kHz 单声道 float。转不了就返回 nil（调用方自己决定要不要退回原格式）
    private func resample(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let tgt = pcm16k else { return nil }
        let f = buf.format
        if f.sampleRate == tgt.sampleRate,
           f.channelCount == 1,
           f.commonFormat == .pcmFormatFloat32 {
            return buf
        }
        if conv == nil || convIn != f {
            conv = AVAudioConverter(from: f, to: tgt)
            convIn = f
        }
        guard let c = conv else { return nil }

        let ratio = tgt.sampleRate / f.sampleRate
        let cap = AVAudioFrameCount((Double(buf.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: tgt, frameCapacity: cap) else { return nil }

        var fed = false
        var err: NSError?
        let st = c.convert(to: out, error: &err) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buf
        }
        if st == .error || err != nil || out.frameLength == 0 { return nil }
        return out
    }
}
