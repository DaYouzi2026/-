import AVFoundation
import Vision
import UIKit

/// 相机预览 + Vision 人脸检测，检测偏移回调给跟随引擎
final class GCCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var requests: [VNRequest] = []
    private let queue = DispatchQueue(label: "gc.camera", qos: .userInitiated)

    /// 检测到人脸时回调归一化偏移 [-1,1]（右/下为正）与人脸宽高比
    var onFace: ((Float, Float, Bool) -> Void)?

    override init() {
        super.init()
        setupVision()
        setupCamera()
    }

    private func setupVision() {
        let req = VNSequenceFaceDetectionRequest { request, error in
            guard let results = request.results as? [VNFaceObservation],
                  let face = results.first else { return }
            let b = face.boundingBox
            // Vision 坐标原点左下，x 右正、y 上正 → 转成"下为正"
            let dx = Float(b.midX - 0.5) * 2
            let dy = Float(0.5 - b.midY) * 2
            let ratio = b.width / max(b.height, 0.001)
            self.onFace?(dx, dy, ratio > 1.15)
        }
        requests = [req]
    }

    private func setupCamera() {
        session.beginConfiguration()
        session.sessionPreset = .medium
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else { session.commitConfiguration(); return }
        session.addInput(input)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    func start() { if !session.isRunning { session.startRunning() } }
    func stop() { if session.isRunning { session.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sbuf: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sbuf) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: px, orientation: .upMirrored, options: [:])
        try? handler.perform(requests)
    }
}
