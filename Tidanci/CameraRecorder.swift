import Foundation
import AVFoundation
import Combine
import UIKit
import SwiftUI

/// 相机 + 录制。一路 AVCaptureSession 同时干三件事：
/// 预览、录视频（含声音）、把音频吐给语音识别。
/// 所以边录边跟读不需要抢麦克风。
final class CameraRecorder: NSObject, ObservableObject {

    let session = AVCaptureSession()

    private let movieOut = AVCaptureMovieFileOutput()
    private let audioOut = AVCaptureAudioDataOutput()
    private var videoIn: AVCaptureDeviceInput?
    private var audioIn: AVCaptureDeviceInput?

    private let cfgQ = DispatchQueue(label: "tidanci.cam.config")
    private let audioQ = DispatchQueue(label: "tidanci.cam.audio")

    /// 只在 cfgQ 上读写，用来判断「下一次该切哪个镜头」，避免和 Published 打架
    private var frontFlag = true
    private var quality: VideoQuality = .uhd
    private var fps: Int = 30

    @Published private(set) var ready = false
    @Published private(set) var recording = false
    /// 实际生效的画质，比如 "4K·30"
    @Published private(set) var presetText = "—"
    /// 实际分辨率，比如 "3840×2160"
    @Published private(set) var detailText = ""
    @Published private(set) var isFront = true
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

    func start(front: Bool, quality: VideoQuality, fps: Int) {
        self.quality = quality
        self.fps = fps
        cfgQ.async {
            if self.session.inputs.isEmpty {
                self.configure(front: front)
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            DispatchQueue.main.async { self.ready = true }
        }
    }

    func stop() {
        cfgQ.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
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

    /// 不录的时候改画质，立刻生效
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

        if let mic = AVCaptureDevice.default(for: .audio),
           let ai = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(ai) {
            session.addInput(ai)
            audioIn = ai
        }

        applyFormat(dev)

        if !hasOutput(movieOut), session.canAddOutput(movieOut) {
            session.addOutput(movieOut)
            movieOut.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        }

        if !hasOutput(audioOut), session.canAddOutput(audioOut) {
            audioOut.setSampleBufferDelegate(self, queue: audioQ)
            session.addOutput(audioOut)
        }

        if let c = movieOut.connection(with: .video), c.isVideoOrientationSupported {
            c.videoOrientation = .portrait
        }

        publishActual(dev, front: front)
    }

    /// 先按「短边 + 帧率」在镜头支持的格式里挑一个，挑不到再退回系统预设
    private func applyFormat(_ dev: AVCaptureDevice) {
        if session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
        }

        if let f = bestFormat(dev, short: quality.shortSide, fps: fps) {
            do {
                try dev.lockForConfiguration()
                dev.activeFormat = f
                let dur = CMTime(value: 1, timescale: CMTimeScale(fps))
                dev.activeVideoMinFrameDuration = dur
                dev.activeVideoMaxFrameDuration = dur
                dev.unlockForConfiguration()
                return
            } catch {
                // 掉到下面的预设兜底
            }
        }

        if quality == .uhd, session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
        } else if quality != .hd, session.canSetSessionPreset(.hd1920x1080) {
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
            if f.isVideoHDRSupported { score += 1 }
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

    private func hasOutput(_ o: AVCaptureOutput) -> Bool {
        for x in session.outputs where x === o { return true }
        return false
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
        cfgQ.async {
            guard self.movieOut.isRecording == false else { return }
            if let c = self.movieOut.connection(with: .video), c.isVideoOrientationSupported {
                c.videoOrientation = .portrait
            }
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                self.recordingError = ""
                self.recording = true
            }
            self.movieOut.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        cfgQ.async {
            if self.movieOut.isRecording {
                self.movieOut.stopRecording()
            }
        }
    }
}

// MARK: - 录制回调

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
            self.onFinish?(finished ? outputFileURL : nil)
        }
    }
}

// MARK: - 音频回调（喂给语音识别）

extension CameraRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pcm = CameraRecorder.toPCM(sampleBuffer) else { return }
        onAudio?(pcm)
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

// MARK: - 预览

final class PreviewLayerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewLayerView {
        let v = PreviewLayerView()
        v.backgroundColor = .black
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewLayerView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        if let c = uiView.previewLayer.connection, c.isVideoOrientationSupported {
            c.videoOrientation = .portrait
        }
    }
}
