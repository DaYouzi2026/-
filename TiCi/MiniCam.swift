import AVFoundation
import UIKit
import Photos

/// 极简相机：取景 + 录像存相册。只用系统最稳的 AVCaptureMovieFileOutput，
/// 不碰像素缓冲区、美颜、同拍那些复杂的东西，尽量少出错。
final class MiniCam: NSObject, ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var recording = false
    @Published private(set) var isFront = true
    @Published var message = ""

    let session = AVCaptureSession()

    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private let workQueue = DispatchQueue(label: "mini.cam.queue")
    private var outputURL: URL?
    private var savedCompletion: ((Bool) -> Void)?

    override init() {
        super.init()
        requestPermissionThenSetup()
    }

    // MARK: 权限 + 建会话

    private func requestPermissionThenSetup() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setup()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                if ok { self?.setup() }
                else { DispatchQueue.main.async { self?.message = "需要相机权限才能取景" } }
            }
        default:
            DispatchQueue.main.async { self.message = "请在系统设置里允许使用相机" }
        }
    }

    private func setup() {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            self.attachCamera(front: true)
            self.attachMic()
            if self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
            }
            self.session.commitConfiguration()
            self.session.startRunning()
            DispatchQueue.main.async { self.ready = true }
        }
    }

    private func attachCamera(front: Bool) {
        if let old = videoInput { session.removeInput(old) }
        let pos: AVCaptureDevice.Position = front ? .front : .back
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else { return }
        session.addInput(input)
        videoInput = input
    }

    private func attachMic() {
        guard let dev = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else { return }
        session.addInput(input)
    }

    // MARK: 操作

    func flip() {
        guard ready, !recording else { return }
        workQueue.async { [weak self] in
            guard let self = self else { return }
            let next = !self.isFront
            self.session.beginConfiguration()
            self.attachCamera(front: next)
            self.session.commitConfiguration()
            DispatchQueue.main.async { self.isFront = next }
        }
    }

    func startRecord() {
        guard ready, !recording else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tici_\(Int(Date().timeIntervalSince1970)).mov")
        outputURL = url
        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            DispatchQueue.main.async { self.recording = true }
        }
    }

    func stopRecord() {
        guard recording else { return }
        workQueue.async { [weak self] in
            self?.movieOutput.stopRecording()
        }
    }

    // MARK: 保存相册

    private func saveToPhotos(_ url: URL, done: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                done(false)
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { ok, _ in
                done(ok)
            }
        }
    }
}

// MARK: - 录制回调

extension MiniCam: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        let success = error == nil
        if success {
            saveToPhotos(outputFileURL) { [weak self] ok in
                DispatchQueue.main.async {
                    self?.recording = false
                    self?.message = ok ? "已保存到相册" : "录好了，但没权限存相册"
                }
                try? FileManager.default.removeItem(at: outputFileURL)
            }
        } else {
            DispatchQueue.main.async {
                self.recording = false
                self.message = "录制失败，请重试"
            }
        }
    }
}

// MARK: - 预览层

struct MiniPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var mirrored: Bool

    func makeUIView(context: Context) -> PreviewContainer {
        let v = PreviewContainer()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ v: PreviewContainer, context: Context) {
        if v.preview.session !== session { v.preview.session = session }
        v.setMirrored(mirrored)
    }
}

final class PreviewContainer: UIView {
    let preview = AVCaptureVideoPreviewLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        preview.frame = bounds
    }

    func setMirrored(_ on: Bool) {
        guard let conn = preview.connection, conn.isVideoMirroringSupported else { return }
        conn.isVideoMirrored = on
    }
}
