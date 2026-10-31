import Foundation
import UIKit
import CoreImage
import Metal
import CoreVideo

// MARK: - 滤镜预设

enum BeautyFilterPreset: Int, CaseIterable, Identifiable {
    case none = 0
    case natural
    case bright
    case pink
    case warm
    case film
    case cool
    case mono

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .none: return "原图"
        case .natural: return "自然"
        case .bright: return "白皙"
        case .pink: return "粉嫩"
        case .warm: return "元气"
        case .film: return "胶片"
        case .cool: return "冷调"
        case .mono: return "黑白"
        }
    }

    /// R/G/B 增益，和安卓版 BeautyParams.filterTint 一一对应
    var tint: (Double, Double, Double) {
        switch self {
        case .natural: return (1.02, 1.00, 0.99)
        case .bright: return (1.06, 1.04, 1.05)
        case .pink: return (1.08, 0.98, 1.02)
        case .warm: return (1.07, 1.00, 0.90)
        case .film: return (1.02, 0.99, 0.94)
        case .cool: return (0.94, 1.00, 1.09)
        default: return (1.00, 1.00, 1.00)
        }
    }

    /// 界面上滤镜圆点的底色
    var swatch: UIColor {
        switch self {
        case .none: return UIColor(red: 0.62, green: 0.64, blue: 0.70, alpha: 1)
        case .natural: return UIColor(red: 0.93, green: 0.84, blue: 0.77, alpha: 1)
        case .bright: return UIColor(red: 0.98, green: 0.94, blue: 0.92, alpha: 1)
        case .pink: return UIColor(red: 0.99, green: 0.82, blue: 0.86, alpha: 1)
        case .warm: return UIColor(red: 0.99, green: 0.84, blue: 0.62, alpha: 1)
        case .film: return UIColor(red: 0.80, green: 0.76, blue: 0.66, alpha: 1)
        case .cool: return UIColor(red: 0.68, green: 0.80, blue: 0.95, alpha: 1)
        case .mono: return UIColor(red: 0.55, green: 0.55, blue: 0.57, alpha: 1)
        }
    }
}

// MARK: - 参数

struct BeautyParams {
    var smooth: Double = 0.36
    var whiten: Double = 0.26
    var rosy: Double = 0.14
    var slim: Double = 0.0
    var eye: Double = 0.0
    var preset: BeautyFilterPreset = .natural

    var isNeutral: Bool {
        smooth < 0.01 && whiten < 0.01 && rosy < 0.01
            && slim < 0.01 && eye < 0.01 && preset == .none
    }
}

// MARK: - 渲染管线

/// 一路 Core Image 管线，预览和录制共用同一份参数。
/// 磨皮走高斯模糊 + CIDissolveTransition 混合，瘦脸/大眼走 CIBumpDistortion，
/// 都是 GPU 原生滤镜，30fps 1080P 不会有压力。
final class BeautyPipeline {
    static let shared = BeautyPipeline()

    let context: CIContext
    private let space = CGColorSpaceCreateDeviceRGB()

    private let lock = NSLock()
    private var _params = BeautyParams()

    var params: BeautyParams {
        get {
            lock.lock(); defer { lock.unlock() }
            return _params
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _params = newValue
        }
    }

    private init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device,
                                options: [CIContextOption.cacheIntermediates: false])
        } else {
            context = CIContext(options: [CIContextOption.useSoftwareRenderer: false])
        }
    }

    func makeBuffer(_ pixel: CVPixelBuffer) -> CIImage {
        CIImage(cvPixelBuffer: pixel)
    }

    /// 主处理链。顺序和安卓一致：先美型，再磨皮美白，最后套滤镜。
    func process(_ src: CIImage, dims: CGSize) -> CIImage {
        let p = params
        var img = src

        if p.slim > 0.01 || p.eye > 0.01 {
            img = shape(img, dims: dims, slim: p.slim, eye: p.eye)
        }

        if p.smooth > 0.01 {
            let radius = CGFloat(2.0 + p.smooth * 9.0)
            let blur = img
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: img.extent)
            img = img.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: blur,
                kCIInputTimeKey: CGFloat(p.smooth * 0.70)
            ])
        }

        if p.whiten > 0.01 || p.rosy > 0.01 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: CGFloat(p.whiten * 0.11),
                kCIInputSaturationKey: CGFloat(1.0 - p.whiten * 0.06),
                kCIInputContrastKey: CGFloat(1.0 + p.whiten * 0.03)
            ])
        }

        if p.rosy > 0.01 {
            let r = p.rosy
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(1.0 + r * 0.10), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(1.0 - r * 0.04), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(1.0 - r * 0.06), w: 0),
                "inputBiasVector": CIVector(x: CGFloat(r * 0.015), y: 0, z: 0, w: 0)
            ])
        }

        let t = p.preset.tint
        if t.0 != 1.0 || t.1 != 1.0 || t.2 != 1.0 {
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(t.0), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(t.1), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(t.2), w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        }

        if p.preset == .mono {
            img = img.applyingFilter("CIColorMonochrome", parameters: [
                kCIInputColorKey: CIColor(red: 0.93, green: 0.93, blue: 0.94),
                kCIInputIntensityKey: CGFloat(0.88)
            ])
        }

        return img.cropped(to: CGRect(origin: .zero, size: dims))
    }

    /// 美型。自拍时人脸基本在画面中间偏上，所以按固定的椭圆区域挤压，
    /// 不跑人脸检测——省掉每帧的 Vision 开销，也不会因为没有关键点就整段失效。
    private func shape(_ img: CIImage, dims: CGSize, slim: Double, eye: Double) -> CIImage {
        var out = img
        let w = dims.width
        let h = dims.height
        let short = min(w, h)

        if slim > 0.01 {
            let r = short * 0.24
            let scale = CGFloat(-slim * 0.42)
            for dx in [CGFloat(-0.19), CGFloat(0.19)] {
                let c = CIVector(x: w * (0.5 + dx), y: h * 0.60)
                out = out.applyingFilter("CIBumpDistortion", parameters: [
                    kCIInputCenterKey: c,
                    kCIInputRadiusKey: r,
                    kCIInputScaleKey: scale
                ])
            }
        }

        if eye > 0.01 {
            let r = short * 0.085
            let scale = CGFloat(eye * 0.34)
            for dx in [CGFloat(-0.075), CGFloat(0.075)] {
                let c = CIVector(x: w * (0.5 + dx), y: h * 0.685)
                out = out.applyingFilter("CIBumpDistortion", parameters: [
                    kCIInputCenterKey: c,
                    kCIInputRadiusKey: r,
                    kCIInputScaleKey: scale
                ])
            }
        }

        return out.cropped(to: CGRect(origin: .zero, size: dims))
    }

    /// 渲染进给定的像素缓冲（录制用）
    func render(_ img: CIImage, into buffer: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        context.render(img,
                       to: buffer,
                       bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       colorSpace: space)
    }

    /// 渲染成一张 CGImage（预览兜底）
    func makeCGImage(_ img: CIImage) -> CGImage? {
        context.createCGImage(img, from: img.extent)
    }
}
