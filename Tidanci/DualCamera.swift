import Foundation
import AVFoundation
import CoreVideo
import CoreImage
import UIKit
import SwiftUI
import Combine

/// 前后同拍（画中画）副摄采集 + 合成器。
///
/// ── 为什么必须用 AVCaptureMultiCamSession ──────────────────────────────
/// 早期版本给副摄开了**独立** AVCaptureSession。iOS 不允许同一个 App 里两个
/// 采集会话同时占用摄像头：副摄一 startRunning，主摄立刻收到
/// AVCaptureSessionWasInterrupted(videoDeviceInUseByAnotherClient)，随后两者
/// 互相打断 —— 表现就是主画面黑屏 / 小窗定屏、日志刷屏「相机会话被中断」。
///
/// 现在改为：主摄 + 副摄都挂在 CameraRecorder 的**同一个** AVCaptureMultiCamSession
/// 上（Apple 官方 AVMultiCamPiP 的做法，iOS 13+，iPhone 13 的 A14 完全支持）。
/// 一个会话同时采两路，不再有互抢。class 只负责：
///   · 按多摄格式集创建副摄 input / 配置副摄 output（真正 add 由 CameraRecorder 做）
///   · 冻结副摄帧（供合成 + 小窗预览）
///   · 把副摄小窗合成到主帧右上角
/// 任何一步失败都返回 nil，让主路照常只写主画面 —— 同拍坏了也不拖垮录制。
final class DualCameraPip: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, ObservableObject {

    static let shared = DualCameraPip()
    private override init() {}

    /// 副摄视频输出。由 CameraRecorder 加进多摄会话，delegate 指向本类。
    let videoOut = AVCaptureVideoDataOutput()
    /// 副摄 input（由 makeInput 建、CameraRecorder add；持有引用便于摘除）
    private(set) var deviceIn: AVCaptureDeviceInput?

    private let frameQ = DispatchQueue(label: "tidanci.pip.frame")
    private let lock = NSLock()
    private let captureCtx = CIContext(options: [.workingColorSpace: NSNull()])
    private let renderCtx = CIContext(options: [.workingColorSpace: NSNull()])

    private var pipIsFront = false
    /// 副摄最新一帧（独占 buffer 冻结，不参与 AVCapture 复用，合成时不会花屏）
    private var latest: CIImage?
    private var lastFreezeAt: CFTimeInterval = 0

    @Published private(set) var available = false
    /// 小窗预览图：直接用冻结帧生成，方向和成片一致，不依赖多摄预览层绑定
    @Published private(set) var previewImage: UIImage?

    // MARK: - 多摄格式辅助

    /// 取指定方向的宽角摄像头（前后各一颗）
    static func camera(front: Bool) -> AVCaptureDevice? {
        let pos: AVCaptureDevice.Position = front ? .front : .back
        if let d = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos) {
            return d
        }
        let ds = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                  mediaType: .video, position: pos)
        return ds.devices.first
    }

    /// 从设备支持的**多摄兼容**格式里挑一个（multi-cam 会话只能用 isMultiCamSupported 的格式）
    static func multiCamFormat(_ dev: AVCaptureDevice, short: CGFloat, fps: Int) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestScore = -Double.greatestFiniteMagnitude
        for f in dev.formats where f.isMultiCamSupported {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let s = CGFloat(min(d.width, d.height))
            let l = CGFloat(max(d.width, d.height))
            guard s > 0 else { continue }
            let ar = l / s
            guard abs(ar - 16.0 / 9.0) < 0.06 else { continue }
            guard f.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= Double(fps) - 0.5 }) else { continue }
            var score = -Double(abs(s - short)) * 4.0
            if abs(s - short) < 1 { score += 400 }
            if score > bestScore { bestScore = score; best = f }
        }
        return best
    }

    // MARK: - 副摄 input / output

    /// 按方向建副摄 input 并锁定多摄格式。**在 cfgQ 上调用**；真正的 add 由 CameraRecorder 做。
    func makeInput(front: Bool) -> AVCaptureDeviceInput? {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            Diag.note("同拍：没有相机权限")
            return nil
        }
        guard let dev = Self.camera(front: front) else {
            Diag.note("同拍：找不到\(front ? "前置" : "后置")副摄")
            return nil
        }
        if let fmt = Self.multiCamFormat(dev, short: 720, fps: 30) {
            do {
                try dev.lockForConfiguration()
                dev.activeFormat = fmt
                let dur = CMTime(value: 1, timescale: 30)
                dev.activeVideoMinFrameDuration = dur
                dev.activeVideoMaxFrameDuration = dur
                dev.unlockForConfiguration()
            } catch {
                Diag.note("同拍：副摄格式设置失败 \(error.localizedDescription)")
            }
        }
        do {
            let inp = try AVCaptureDeviceInput(device: dev)
            deviceIn = inp
            pipIsFront = front
            return inp
        } catch {
            Diag.note("同拍：副摄 input 建不起来 \(error.localizedDescription)")
            return nil
        }
    }

    /// output 基础配置（add 之前调一次即可）
    func prepareOutput() {
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                    Int(kCVPixelFormatType_32BGRA)]
        videoOut.alwaysDiscardsLateVideoFrames = true
        videoOut.setSampleBufferDelegate(self, queue: frameQ)
    }

    /// input/output 已加进会话：标记可用
    func markAttached() {
        DispatchQueue.main.async { self.available = true }
    }

    /// 会话已摘除副摄：清帧
    func markDetached() {
        lock.lock(); latest = nil; lock.unlock()
        deviceIn = nil
        DispatchQueue.main.async {
            self.available = false
            self.previewImage = nil
        }
    }

    /// 只清冻结帧（页面离开但会话未必拆时调用）
    func clearFrames() {
        lock.lock(); latest = nil; lock.unlock()
    }

    // MARK: - 副摄帧采集

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // 节流：小窗 ~20fps 足够，避免每帧新建 buffer 造成内存抖动
        let now = CACurrentMediaTime()
        guard now - lastFreezeAt >= 1.0 / 20.0 else { return }
        lastFreezeAt = now

        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let w = CVPixelBufferGetWidth(px)
        let h = CVPixelBufferGetHeight(px)
        guard w > 0, h > 0 else { return }

        var img = CIImage(cvPixelBuffer: px)
        if w > h { img = img.oriented(.right) }              // 横帧转竖，和主画面一致
        if pipIsFront { img = img.oriented(.upMirrored) }    // 前置小窗照镜子

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
        lock.lock(); latest = still; lock.unlock()

        // 小窗预览直接用这帧（独占 buffer，延迟渲染安全）
        let ui = UIImage(ciImage: still)
        DispatchQueue.main.async { self.previewImage = ui }
    }

    // MARK: - 合成

    /// 主帧 + 副摄小窗合成成 BGRA sample buffer 交给写入器。
    /// 返回 nil 表示失败，调用方直接写原帧（降级）。
    func composite(main: CMSampleBuffer) -> CMSampleBuffer? {
        guard let mainPx = CMSampleBufferGetImageBuffer(main) else { return nil }
        let mw = CVPixelBufferGetWidth(mainPx)
        let mh = CVPixelBufferGetHeight(mainPx)
        guard mw > 0, mh > 0 else { return nil }

        var out = CIImage(cvPixelBuffer: mainPx)

        lock.lock(); let pip = latest; lock.unlock()

        if let pip = pip, pip.extent.width > 0, pip.extent.height > 0 {
            let short = min(CGFloat(mw), CGFloat(mh))
            let side = short * 0.30
            let margin = short * 0.045
            let radius = side * 0.22

            let ext = pip.extent
            let s = min(ext.width, ext.height)
            let crop = CGRect(x: ext.midX - s / 2, y: ext.midY - s / 2, width: s, height: s)
            let zeroed = pip.cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.origin.x, y: -crop.origin.y))
            let scaled = zeroed.transformed(by: CGAffineTransform(scaleX: side / s, y: side / s))

            let mask = Self.filledRound(size: side, radius: radius)
            let roundPip = Self.blend(scaled, mode: "CISourceInCompositing", over: mask)

            let pad = max(2, side * 0.015)
            let outer = Self.filledRound(size: side, radius: radius)
            let inner = Self.filledRound(size: side - pad * 2, radius: max(0, radius - pad))
                .transformed(by: CGAffineTransform(translationX: pad, y: pad))
            let border = Self.blend(outer, mode: "CISourceOutCompositing", over: inner)

            let ox = CGFloat(mw) - side - margin
            let oy = CGFloat(mh) - side - margin
            let shift = CGAffineTransform(translationX: ox, y: oy)

            out = roundPip.transformed(by: shift).composited(over: out)
            out = border.transformed(by: shift).composited(over: out)
        }

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

        // 主帧的 timing 原样复用，PTS 完全对齐（音画不错拍）
        let timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(main),
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
                                                 sampleTiming: timing,
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

// MARK: - 副摄小窗预览（直接显示冻结帧，方向/内容与成片一致）

/// 圆角小窗里显示副摄冻结帧。不依赖 AVCaptureVideoPreviewLayer 的多摄 connection 绑定，
/// 因此不会出现"主预览连到副摄"或"小窗黑屏"的问题。
struct PipPreviewView: View {
    let image: UIImage?

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.black
            }
        }
    }
}
