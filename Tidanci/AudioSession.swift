import Foundation
import AVFoundation

/// App 里有两条路都要用麦克风：相机会话（录制）和语音识别（跟读）。
/// 两边都会去改系统的 audio session，改来改去很容易把相机这一路弄哑。
///
/// 这里的策略很简单：**只做最小改动**。
/// * 类别本来就是 `playAndRecord` 就一个字都不动（反复 setCategory 会触发路由变更，
///   相机正在跑的音频 I/O 会被打断，甚至被系统掐掉——之前「第一条视频没声音」就是被这个坑咬过）。
/// * 需要改的时候才改，改完激活。
/// * 释放时吞掉所有错误：此时 I/O 可能还没停干净，报错是正常的。
enum AudioSession {

    /// 录视频用：既要录麦克风，又要能外放（不然回放没声）
    static func forCamera() {
        let s = AVAudioSession.sharedInstance()
        if s.category != .playAndRecord {
            do {
                try s.setCategory(.playAndRecord,
                                  mode: .videoRecording,
                                  options: [.defaultToSpeaker, .mixWithOthers])
            } catch {
                // 个别机型不接受 mixWithOthers，退回最朴素的一套也要把路打开
                try? s.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
            }
        }
        // 重复激活是幂等的，便宜且安全
        try? s.setActive(true, options: [])
    }

    /// 跟读用：只要录音输入，别把别的声音掐掉
    static func forSpeech() {
        let s = AVAudioSession.sharedInstance()
        if s.category != .playAndRecord {
            do {
                try s.setCategory(.playAndRecord,
                                  mode: .measurement,
                                  options: [.defaultToSpeaker, .mixWithOthers])
            } catch {
                try? s.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            }
        }
        try? s.setActive(true, options: [])
    }

    /// 录制过程中只做「补激活」：不换类别、不动模式。
    /// 类别每改一次，系统会重建一次音频路由，正在跑的采集被这么一折腾就会哑掉。
    static func keepAlive() {
        let s = AVAudioSession.sharedInstance()
        guard s.category == .playAndRecord else { return }
        try? s.setActive(true, options: [])
    }

    /// 退出提词页时放掉，免得切到别的 App 还在占麦克风
    static func release() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [])
    }
}
