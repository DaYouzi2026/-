import Foundation
import Speech
import AVFoundation
import Combine

/// 语音识别。iOS 自带的中文离线识别（SFSpeechRecognizer + requiresOnDeviceRecognition），
/// 不用联网、不装额外模型，比安卓那套 26MB 的小模型准得多。
/// 音频来自相机的 AVCaptureAudioDataOutput，不再单独开 AVAudioEngine，避免抢麦。
final class SpeechFollower: ObservableObject {

    @Published private(set) var status = ""
    @Published private(set) var running = false
    @Published private(set) var onDevice = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastRestart = Date()
    private var wantRun = false

    var onText: ((String) -> Void)?
    var onFail: ((String) -> Void)?

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
        onDevice = rec.supportsOnDeviceRecognition
        wantRun = true
        if !running {
            newRequest(rec)
            running = true
            status = onDevice ? "离线识别已就绪" : "在线识别已就绪"
        }
    }

    func stop() {
        wantRun = false
        running = false
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        status = ""
    }

    private func newRequest(_ rec: SFSpeechRecognizer) {
        task?.cancel()
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition {
            r.requiresOnDeviceRecognition = true
        }
        request = r
        lastRestart = Date()

        task = rec.recognitionTask(with: r) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.status = self.onDevice ? "离线识别中" : "在线识别中"
                    self.onText?(text)
                }
                if result.isFinal {
                    self.restartSoon()
                }
            }
            if error != nil && self.wantRun {
                self.restartSoon()
            }
        }
    }

    private func restartSoon() {
        guard wantRun else { return }
        // 单个请求有时长上限，识别到结尾或报错就换一个新的，别让跟读断掉
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, self.wantRun, let rec = self.recognizer else { return }
            self.newRequest(rec)
        }
    }

    /// 相机每来一帧音频就喂进来
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard running, let r = request else { return }
        if Date().timeIntervalSince(lastRestart) > 50 {
            restartSoon()
            return
        }
        r.append(buffer)
    }
}
