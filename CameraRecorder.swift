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

    @Published private(set) var ready = false
    @Published private(set) var recording = false
    @Published private(set) var presetText = "—"
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

    func start(front: Bool) {
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

        // 能 4K 就 4K，不行退 1080，再不行 720
        if session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
        } else if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
        }

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

        // 预设是结构体不是枚举，用 rawValue 判断，别写 switch
        let raw = session.sessionPreset.rawValue
        let label: String
        if raw.contains("3840") {
            label = "4K"
        } else if raw.contains("1920") {
            label = "1080P"
        } else if raw.contains("1280") {
            label = "720P"
        } else {
            label = "自动"
        }
        DispatchQueue.main.async {
            self.presetText = label
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
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInDualCamera, .builtInUltraWideCamera]
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
