import AVFoundation
import Vision
import UIKit
import Photos
import ImageIO

/// 相机引擎：预览 + 拍照 + 录像 + 前后摄 + 变焦 + 对焦 + 闪光灯 + Vision 人脸检测
/// 检测偏移回调给跟随引擎，用于云台自动跟踪
final class GCCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                      AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {

    let session = AVCaptureSession()

    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    private var requests: [VNRequest] = []
    private let queue = DispatchQueue(label: "gc.camera", qos: .userInitiated)

    /// 人脸检测回调：dx/dy 归一化偏移 [-1,1]（右/下为正），landscape 是否横屏构图
    var onFace: ((Float, Float, Bool) -> Void)?
    /// 拍照/录像完成回调（是否成功）
    var onPhotoSaved: ((Bool) -> Void)?
    var onVideoSaved: ((Bool) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    /// 相机就绪/权限状态
    var onStatus: ((String) -> Void)?

    private(set) var position: AVCaptureDevice.Position = .front
    private(set) var isRecording = false
    private var flashMode: AVCaptureDevice.FlashMode = .off
    private var currentPhotoSettings: AVCapturePhotoSettings?
    private var recordingURL: URL?

    override init() {
        super.init()
        setupVision()
        // 保证回调异步，避免 onStatus 尚未被外部赋值就触发
        requestCameraPermissionAsync { [weak self] granted in
            guard let self = self else { return }
            if granted {
                self.setupCamera()
                self.start()
                self.onStatus?("相机就绪")
            } else {
                self.onStatus?("需要相机权限：请在设置中开启")
            }
        }
    }

    // MARK: - 权限
    private func requestCameraPermissionAsync(_ completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                DispatchQueue.main.async { completion(true) }
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async { completion(granted) }
                }
            default:
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    // MARK: - Vision
    private func setupVision() {
        let req = VNDetectFaceRectanglesRequest { [weak self] request, _ in
            guard let self = self,
                  let results = request.results as? [VNFaceObservation],
                  let face = results.first else { return }
            let b = face.boundingBox
            let dx = Float(b.midX - 0.5) * 2
            let dy = Float(0.5 - b.midY) * 2
            let ratio = b.width / max(b.height, 0.001)
            self.onFace?(dx, dy, ratio > 1.15)
        }
        requests = [req]
    }

    // MARK: - 相机搭建
    private func setupCamera() {
        session.beginConfiguration()
        session.sessionPreset = .high

        // 视频输入
        if let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           let input = try? AVCaptureDeviceInput(device: dev),
           session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
        }

        // 音频输入（录像用）
        if let audio = AVCaptureDevice.default(for: .audio),
           let ain = try? AVCaptureDeviceInput(device: audio),
           session.canAddInput(ain) {
            session.addInput(ain)
            audioInput = ain
        }

        // 人脸检测数据输出
        videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoDataOutput) { session.addOutput(videoDataOutput) }

        // 拍照输出
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            if photoOutput.isHighResolutionCaptureEnabled {
                photoOutput.isHighResolutionCaptureEnabled = true
            }
        }

        // 录像输出
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }

        session.commitConfiguration()
    }

    func start() { if !session.isRunning { session.startRunning() } }
    func stop() { if session.isRunning { session.stopRunning() } }

    // MARK: - 切换前后摄
    func switchCamera() {
        guard let current = videoInput else { return }
        let newPos: AVCaptureDevice.Position = position == .front ? .back : .front
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPos),
              let newInput = try? AVCaptureDeviceInput(device: dev) else { return }

        session.beginConfiguration()
        session.removeInput(current)
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            videoInput = newInput
            position = newPos
        } else {
            session.addInput(current) // 回滚
        }
        session.commitConfiguration()
    }

    // MARK: - 变焦 / 对焦 / 闪光灯
    func setZoom(_ factor: CGFloat) {
        guard let dev = videoInput?.device else { return }
        let maxZoomValue = min(dev.activeFormat.videoMaxZoomFactor, 6.0)
        let f = Swift.max(1.0, Swift.min(maxZoomValue, factor))
        try? dev.lockForConfiguration()
        dev.videoZoomFactor = f
        dev.unlockForConfiguration()
    }

    var zoomFactor: CGFloat { videoInput?.device.videoZoomFactor ?? 1.0 }
    var maxZoom: CGFloat { min(videoInput?.device.activeFormat.videoMaxZoomFactor ?? 2, 6.0) }

    func focus(at point: CGPoint) {
        guard let dev = videoInput?.device, dev.isFocusPointOfInterestSupported else { return }
        try? dev.lockForConfiguration()
        dev.focusPointOfInterest = point
        dev.focusMode = .autoFocus
        if dev.isExposurePointOfInterestSupported {
            dev.exposurePointOfInterest = point
            dev.exposureMode = .autoExpose
        }
        dev.unlockForConfiguration()
    }

    func setFlash(_ on: Bool) {
        flashMode = on ? .on : .off
        guard let dev = videoInput?.device, dev.hasFlash else { return }
        try? dev.lockForConfiguration()
        if dev.isFlashModeSupported(flashMode) { dev.flashMode = flashMode }
        dev.unlockForConfiguration()
    }
    var flashOn: Bool { flashMode == .on }

    // MARK: - 拍照
    func takePhoto() {
        guard photoOutput.connection(with: .video) != nil else {
            onPhotoSaved?(false); return
        }
        let settings = AVCapturePhotoSettings()
        settings.flashMode = flashMode
        currentPhotoSettings = settings
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            onPhotoSaved?(false); return
        }
        PHPhotoLibrary.shared().performChanges {
            let req = PHAssetChangeRequest.creationRequestForAsset(from: UIImage(data: data) ?? UIImage())
            _ = req.placeholderForCreatedAsset
        } completionHandler: { [weak self] ok, _ in
            DispatchQueue.main.async { self?.onPhotoSaved?(ok) }
        }
    }

    // MARK: - 录像
    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        guard !movieOutput.isRecording else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gimbal_\(Int(Date().timeIntervalSince1970)).mp4")
        recordingURL = url
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        onRecordingChanged?(true)
    }

    private func stopRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
        isRecording = false
        onRecordingChanged?(false)
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        let success = error == nil
        if success {
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
            } completionHandler: { [weak self] ok, _ in
                try? FileManager.default.removeItem(at: outputFileURL)
                DispatchQueue.main.async { self?.onVideoSaved?(ok) }
            }
        } else {
            DispatchQueue.main.async { [weak self] in self?.onVideoSaved?(false) }
        }
    }

    // MARK: - 人脸检测帧
    func captureOutput(_ output: AVCaptureOutput, didOutput sbuf: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sbuf) else { return }
        let orientation: CGImagePropertyOrientation = position == .front ? .upMirrored : .up
        let handler = VNImageRequestHandler(cvPixelBuffer: px, orientation: orientation, options: [:])
        try? handler.perform(requests)
    }
}
