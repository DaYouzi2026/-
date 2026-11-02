import Foundation
import AVFoundation

/// App 里有两条路都要用麦克风：相机会话（录制）和语音识别（跟读）。
///
/// 系统默认让 `AVCaptureSession` 自己配置 audio session（`automaticallyConfiguresApplicationAudioSession`），
/// 只在 `startRunning()` 那一刻配一次。可语音识别在启动时也会把 audio session 改成「只录音」那一套，
/// 抢在相机前面就把配置换掉了 —— 结果是**相机这一路拿不到音频**，录出来的第一条视频没有声音；
/// 等识别自己停了、session 被别人重新激活，后面的视频又有声音了。
/// 这跟权限无关（权限已经给了），纯粹是两条路互相覆盖对方的环境。
///
/// 所以这里统一管：相机关掉自动配置，由我们显式设成「播放+录音 / 视频录制」；
/// 录制开始前再激活一次，把语音识别可能留下的配置纠正回来。
enum AudioSession {

    /// 录视频用：既要录麦克风，又要能外放（不然回放没声）
    static func forCamera() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord,
                              mode: .videoRecording,
                              options: [.defaultToSpeaker, .mixWithOthers])
        } catch {
            // 个别机型不接受 mixWithOthers，退回最朴素的一套也要把路打开
            try? s.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
        }
        try? s.setActive(true, options: [])
    }

    /// 跟读用：只要录音输入，别把别的声音掐掉
    static func forSpeech() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord,
                              mode: .measurement,
                              options: [.defaultToSpeaker, .mixWithOthers])
            try s.setActive(true, options: [])
        } catch {
        }
    }

    /// 退出提词页时放掉，免得切到别的 App 还在占麦克风
    static func release() {
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: [.notifyOthersOnDeactivation])
    }
}
