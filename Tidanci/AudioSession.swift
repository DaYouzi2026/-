import Foundation
import AVFoundation

/// App 里有两条路都要用麦克风：相机会话（录制）和语音识别（跟读）。
/// 两边都会去改系统的 audio session，改来改去很容易把相机这一路弄哑。
///
/// ── v1.13：把「成品没声音」这条死路堵上 ──────────────────────
///
/// 旧版这里有个**一直都在**的错误：`setCategory(.playAndRecord, mode: .videoRecording,
/// options: [.defaultToSpeaker, .mixWithOthers])`。`.mixWithOthers` 和
/// `.videoRecording` 这个 mode 是不兼容的，系统会直接抛
/// `AVAudioSessionErrorCodeIncompatibleCategory`（561017449），**而这次失败不会
/// 把类别改回来**——于是音频会话可能停在 `.soloAmbient`，麦克风压根没打开。
/// 视频能录（视频不需要 audio session），音频一路静默：成品没声音，备份 WAV 也
/// 是 0 帧，连兜底都兜不住。
///
/// 现在改成逐级降级，并且每次失败都记下来：
///   ① videoRecording + defaultToSpeaker（最理想，有定向收音/降噪）
///   ② default + defaultToSpeaker（兼容性最好）
///   ③ default + 无 option（只求「能录」）
///
/// 另外新增 `enforceForCamera()`：录制过程中如果类别/模式被别的模块（SFSpeech、
/// 来电、别的 App）改掉了，立刻抢回来。旧版 `keepAlive()` 有一道
/// `guard category == .playAndRecord`——类别被改掉时它直接放弃，等于看着录音死掉。
enum AudioSession {

    /// 最近一次设置的失败原因，进诊断日志用
    private(set) static var lastError = ""

    /// 相机这一路是不是正在录制。语音识别每次重开请求都可能顺手改掉音频会话，
    /// 录制中要据此立刻把路由抢回来（见 SpeechFollower.newRequest）。
    static var cameraBusy = false

    /// 录视频用：既要录麦克风，又要能外放（不然回放没声）
    static func forCamera() {
        let s = AVAudioSession.sharedInstance()
        if s.category != .playAndRecord || s.mode != .videoRecording {
            applyVideo(s)
        }
        // 激活失败绝不能吞掉：类别/模式看着都对但会话是死的，
        // 视频照录、麦克风不响 —— 「整条没声音」就是这么来的
        do {
            try s.setActive(true, options: [])
        } catch {
            lastError = "activate:\(error.localizedDescription)"
            Diag.note("音频会话激活失败：\(error.localizedDescription)")
        }
        Diag.note("音频会话 \(s.category.rawValue)/\(s.mode.rawValue)"
                  + (lastError.isEmpty ? "" : "（降级：\(lastError)）"))
    }

    /// 跟读用：只要录音输入，别把别的声音掐掉。
    /// 已经是我们需要的类别时一个字都不动——每改一次路由都会打断正在跑的采集。
    static func forSpeech() {
        let s = AVAudioSession.sharedInstance()
        if s.category != .playAndRecord {
            do {
                try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            } catch {
                try? s.setCategory(.playAndRecord, mode: .default, options: [])
            }
        }
        try? s.setActive(true, options: [])
    }

    /// 录制过程中「把音频路由抢回来」。
    ///
    /// 只要类别不在 playAndRecord、或者模式被换成了别的（`measurement`），
    /// 就重新按录视频那套设一遍。每秒最多调一次，代价可以忽略。
    @discardableResult
    static func enforceForCamera() -> Bool {
        let s = AVAudioSession.sharedInstance()
        var fixed = false
        if s.category != .playAndRecord || s.mode == .measurement {
            applyVideo(s)
            fixed = true
        }
        do {
            try s.setActive(true, options: [])
        } catch {
            lastError = "activate:\(error.localizedDescription)"
        }
        return fixed
    }

    /// 逐级降级地设置「录视频」会话。任何一级成功就停，三级全败也至少试过。
    private static func applyVideo(_ s: AVAudioSession) {
        lastError = ""

        // ① 最理想：videoRecording 模式（定向收音 + 降噪）
        do {
            try s.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
            if s.category == .playAndRecord { return }
        } catch {
            lastError = "videoRecording: \(error.localizedDescription)"
        }

        // ② 退回普通模式。这里千万别带 .mixWithOthers / .allowBluetoothA2DP：
        //    和「录音 + 外放」这套组合最容易互斥，一冲突又白设。
        do {
            try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            if s.category == .playAndRecord { return }
        } catch {
            lastError += " | default: \(error.localizedDescription)"
        }

        // ③ 最后一级：连 option 都不要，只求把麦克风打开
        do {
            try s.setCategory(.playAndRecord, mode: .default, options: [])
        } catch {
            lastError += " | plain: \(error.localizedDescription)"
        }
    }

    /// 录制中只做「补激活」：不换类别、不动模式。
    /// 类别已经不对时交给 enforceForCamera 抢回来（旧版在这里直接 return，等于放弃）。
    static func keepAlive() {
        let s = AVAudioSession.sharedInstance()
        if s.category != .playAndRecord {
            enforceForCamera()
            return
        }
        try? s.setActive(true, options: [])
    }

    /// 退出提词页时放掉，免得切到别的 App 还在占麦克风
    static func release() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [])
    }

    /// 当前是不是「能录音」的状态，诊断用
    static var canRecord: Bool {
        let s = AVAudioSession.sharedInstance()
        return s.category == .playAndRecord || s.category == .record
    }
}
