import Foundation
import AVFoundation
import CoreVideo
import CoreImage
import UIKit
import SwiftUI

/// 前后同拍（画中画）合成器。
///
/// iOS 不允许前后摄同时接进一个 AVCaptureSession，所以这里开一条**独立的副摄会话**：
/// 主路（CameraRecorder.session）照常拍你选的镜头 + 音频，副摄会话专门拍另一颗镜头，
/// 只取视频帧、不碰麦克风（音频仍由主路负责，绝不会两路抢麦）。
///
/// 写帧前，把副摄最新一帧裁成圆角小窗画到主帧右上角，再交给 MovieWriter，
/// 成片里因此同时有两颗镜头的画面 —— 主画面是你拍的场景，小窗是你自己（或反过来）。
///
/// 任何一步失败（副摄打不开、取不到帧、合成异常）都返回 nil，
/// 让调用方直接写原主帧：**同拍坏了也不能把正常录制搞崩**。
final class DualCameraPip: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    static let shared = DualCameraPip()
    private override init() {}

    private let session = AVCaptureSession()
    private let videoOut = AVCaptureVideoDataOutput()
    private let cfgQ = DispatchQueue(label: "tidanci.pip.config")
    private let frameQ = DispatchQueue(label: "tidanci.pip.frame")
    private let lock = NSLock()

    /// 两个 CIContext 分开用，避免采集队列与写入队列同时渲染同一个 context
    private let captureCtx = CIContext(options: [.workingColorSpace: NSNull()])
    private let renderCtx = CIContext(options: [.workingColorSpace: NSNull()])

    private var deviceIn: AVCaptureDeviceInput?
    private var running = false
    private var pipIsFront = false
    /// 副摄最新一帧，引用的是**独占** CVPixelBuffer（不参与 AVCapture 的 buffer 复用），
    /// 合成时读到的永远是稳定画面，不会花屏。
    private var latest: CIImage?
    private var latestSize = CGSize.zero
    /// 副摄帧节流：小窗画面更新到 ~20fps 就够，省内存与算力
    private var lastFreezeAt: CFTimeInterval = 0

    private(set) var available = false

    // MARK: - 生命周期

    /// front = true 表示副摄用前置（主路此时拍的是后置场景）。
    /// 重复调用会先停旧会话再按新方向重建，切镜头时直接再调一次即可。
    func start(front: Bool) {
        cfgQ.async { self.buildLocked(front: front) }
    }

    func stop() {
        cfgQ.async { self.stopLocked() }
    }

    /// 在 cfgQ 上同步执行：先彻底停掉，再按方向建会话
    private func buildLocked(front: Bool) {
        stopLocked()
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            Diag.note("同拍：没有相机权限")
            return
        }
        let pos: AVCaptureDevice.Position = front ? .front : .back
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos) else {
            Diag.note("同拍：找不到\(front ? "前置" : "后置")副摄")
            return
        }
        self.pipIsFront = front

        self.session.beginConfiguration()
        if self.session.canSetSessionPreset(.hd1280x720) {
            self.session.sessionPreset = .hd1280x720   // 小窗够用，省性能，主路画质不受影响
        }
        if let old = self.deviceIn { self.session.removeInput(old); self.deviceIn = nil }
        do {
            let inp = try AVCaptureDeviceInput(device: dev)
            guard self.session.canAddInput(inp) else {
                self.session.commitConfiguration()
                Diag.note("同拍：副摄输入加不进会话")
                return
            }
            self.session.addInput(inp)
            self.deviceIn = inp
        } catch {
            self.session.commitConfiguration()
            Diag.note("同拍：副摄输入建不起来 \(error.localizedDescription)")
            return
        }

        for o in self.session.outputs { self.session.removeOutput(o) }
        self.videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                        Int(kCVPixelFormatType_32BGRA)]
        self.videoOut.alwaysDiscardsLateVideoFrames = true
        self.videoOut.setSampleBufferDelegate(self, queue: self.frameQ)
        guard self.session.canAddOutput(self.videoOut) else {
            self.session.commitConfiguration()
            Diag.note("同拍：副摄输出加不进会话")
            return
        }
        self.session.addOutput(self.videoOut)
        self.session.commitConfiguration()
        self.session.startRunning()
        self.running = true
        DispatchQueue.main.async { self.available = true }
        Diag.note("同拍：副摄已启动（\(front ? "前置" : "后置")）")
    }

    /// 必须在 cfgQ 上调用
    private func stopLocked() {
        guard running else { return }
        session.stopRunning()
        if let d = deviceIn { session.removeInput(d); deviceIn = nil }
        running = false
        lock.lock(); latest = nil; lock.unlock()
        DispatchQueue.main.async { self.available = false }
        Diag.note("同拍：副摄已停")
    }

    /// 取景框预览用的会话（界面拿它渲染一个小取景层）
    var previewSession: AVCaptureSession { session }

    // MARK: - 副摄帧采集

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // 节流：~20fps 更新一次小窗即可，避免每帧都新建 buffer
        let now = CACurrentMediaTime()
        guard now - lastFreezeAt >= 1.0 / 20.0 else { return }
        lastFreezeAt = now

        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let w = CVPixelBufferGetWidth(px)
        let h = CVPixelBufferGetHeight(px)
        guard w > 0, h > 0 else { return }

        // 按实际宽高判断方向：横帧转竖，竖帧保持，避免机型差异
        var img = CIImage(cvPixelBuffer: px)
        if w > h { img = img.oriented(.right) }
        if pipIsFront { img = img.oriented(.upMirrored) }   // 前置小窗照镜子

        let outW = w > h ? h : w
        let outH = w > h ? w : h
        let target = CGRect(x: 0, y: 0, width: outW, height: outH)
        let fitted = img.cropped(to: target)

        // 渲染到独占 buffer 冻结，防止 AVCapture 复用底层像素导致小窗花屏
        var frozen: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: outW,
            kCVPixelBufferHeightKey as String: outH,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, outW, outH, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &frozen) == kCVReturnSuccess,
              let buf = frozen else { return }
        captureCtx.render(fitted, to: buf)
        let still = CIImage(cvPixelBuffer: buf)
        lock.lock()
        latest = still
        latestSize = CGSize(width: outW, height: outH)
        lock.unlock()
    }

    // MARK: - 合成

    /// 把主帧 + 副摄小窗合成成 BGRA CMSampleBuffer 交给写入器。
    /// 返回 nil 表示失败，调用方应直接写原帧（降级）。
    func composite(main: CMSampleBuffer) -> CMSampleBuffer? {
        guard let mainPx = CMSampleBufferGetImageBuffer(main) else { return nil }
        let mw = CVPixelBufferGetWidth(mainPx)
        let mh = CVPixelBufferGetHeight(mainPx)
        guard mw > 0, mh > 0 else { return nil }

        let mainImg = CIImage(cvPixelBuffer: mainPx)
        var out = mainImg

        lock.lock()
        let pip = latest
        lock.unlock()

        if let pip = pip, pip.extent.width > 0, pip.extent.height > 0 {
            let short = min(CGFloat(mw), CGFloat(mh))
            let side = short * 0.30
            let margin = short * 0.045
            let radius = side * 0.22

            // 副摄帧居中裁正方形 → 原点到 (0,0) → 缩到小窗尺寸
            let ext = pip.extent
            let s = min(ext.width, ext.height)
            let crop = CGRect(x: ext.midX - s / 2, y: ext.midY - s / 2, width: s, height: s)
            let zeroed = pip.cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.origin.x, y: -crop.origin.y))
            let scaled = zeroed.transformed(by: CGAffineTransform(scaleX: side / s, y: side / s))

            // 圆角遮罩：白色实心圆角矩形，用 sourceIn 裁出圆角画面
            let mask = Self.filledRound(size: side, radius: radius)
            let roundPip = Self.blend(scaled, mode: "CISourceInCompositing", over: mask)

            // 白色描边：外圆角矩形 sourceOut 内圆角矩形 = 中空边框
            let pad = max(2, side * 0.015)
            let outer = Self.filledRound(size: side, radius: radius)
            let inner = Self.filledRound(size: side - pad * 2, radius: max(0, radius - pad))
                .transformed(by: CGAffineTransform(translationX: pad, y: pad))
            let border = Self.blend(outer, mode: "CISourceOutCompositing", over: inner)

            // 放到主帧右上角（CI 坐标原点在左下）
            let ox = CGFloat(mw) - side - margin
            let oy = CGFloat(mh) - side - margin
            let shift = CGAffineTransform(translationX: ox, y: oy)

            out = roundPip.transformed(by: shift).composited(over: out)
            out = border.transformed(by: shift).composited(over: out)
        }

        // 渲染回 BGRA PixelBuffer（和 BeautyWriter 同格式，写入器稳定）
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: mw,
            kCVPixelBufferHeightKey as String: mh,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, mw, mh, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }
        renderCtx.render(out, to: buffer)

        // 用主帧的 timing 包装新 sample buffer，PTS 完全对齐主帧（音画不会错拍）
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(main),
                                        presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(main),
                                        decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(main))
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                           imageBuffer: buffer,
                                                           formatDescriptionOut: &format) == noErr,
              let fmt = format else { return nil }
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: buffer,
                                                 dataReady: true,
                                                 makeDataReadyCallback: nil,
                                                 refcon: nil,
                                                 formatDescription: fmt,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &result) == noErr,
              let sb = result else { return nil }
        return sb
    }

    // MARK: - 图元

    private static func blend(_ a: CIImage, mode: String, over b: CIImage) -> CIImage {
        guard let f = CIFilter(name: mode) else { return a }
        f.setValue(a, forKey: kCIInputImageKey)
        f.setValue(b, forKey: kCIInputBackgroundImageKey)
        return f.outputImage ?? a
    }

    /// 白色实心圆角矩形，extent = (0,0,size,size)
    private static func filledRound(size: CGFloat, radius: CGFloat) -> CIImage {
        let s = max(1, Int(size.rounded()))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.opaque = false
        fmt.scale = 1
        let ui = UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: fmt).image { ctx in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                         cornerRadius: max(0, radius)).fill()
        }
        return CIImage(image: ui) ?? CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: s, height: s))
    }
}

// MARK: - 副摄取景小窗

/// 把副摄会话渲染成一个预览层（无交互），叠在主画面右上角。
struct PipPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var mirrored: Bool = false

    func makeUIView(context: Context) -> PipPreviewLayerView {
        let v = PipPreviewLayerView()
        v.backgroundColor = .black
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.mirrored = mirrored
        return v
    }

    func updateUIView(_ uiView: PipPreviewLayerView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        uiView.mirrored = mirrored
        uiView.syncMirror()
    }
}

final class PipPreviewLayerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    var mirrored: Bool = false {
        didSet { syncMirror() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncMirror()
    }

    func syncMirror() {
        guard let c = previewLayer.connection else { return }
        if c.isVideoMirroringSupported {
            if c.automaticallyAdjustsVideoMirroring { c.automaticallyAdjustsVideoMirroring = false }
            if c.isVideoMirrored != mirrored { c.isVideoMirrored = mirrored }
        }
    }
}
