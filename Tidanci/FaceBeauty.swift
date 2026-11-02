import Foundation
import UIKit
import Vision
import CoreVideo
import CoreImage

/// 一张脸在画面里的几何信息。
/// 所有坐标都是 0–1 归一化、原点左下，和 CIImage 完全一致，用的时候直接乘宽高。
struct FaceGeometry {
    var bounds: CGRect
    var leftEye: CGPoint
    var rightEye: CGPoint
    var leftEyeRadius: CGFloat
    var rightEyeRadius: CGFloat
    var leftCheek: CGPoint
    var rightCheek: CGPoint
    var contour: [CGPoint]

    /// 把「横着的相机原图」坐标换到「转正之后」的坐标。
    /// 顺时针转 90°：新 x = 原 y，新 y = 1 - 原 x
    func rotatedRight() -> FaceGeometry {
        func t(_ p: CGPoint) -> CGPoint { CGPoint(x: p.y, y: 1 - p.x) }
        var g = self
        let c1 = t(CGPoint(x: bounds.minX, y: bounds.minY))
        let c2 = t(CGPoint(x: bounds.maxX, y: bounds.maxY))
        g.bounds = CGRect(x: min(c1.x, c2.x),
                          y: min(c1.y, c2.y),
                          width: abs(c2.x - c1.x),
                          height: abs(c2.y - c1.y))
        g.leftEye = t(leftEye)
        g.rightEye = t(rightEye)
        g.leftCheek = t(leftCheek)
        g.rightCheek = t(rightCheek)
        g.contour = contour.map(t)
        return g
    }
}

/// 人脸关键点追踪。
/// 用系统 Vision（76 个关键点，跑在 Neural Engine 上），不引入任何模型文件。
/// 每 3 帧真正检一次，中间复用上一次的结果 —— 检测一次约 6–10ms，
/// 摊到每帧 2–3ms，1080P30 有余量。
final class FaceTracker {

    private var tick = 0
    private var cached: FaceGeometry?
    private var lastHit = Date.distantPast

    private let ctx = CIContext(options: [CIContextOption.cacheIntermediates: false])
    private let space = CGColorSpaceCreateDeviceRGB()
    private var small: CVPixelBuffer?

    /// 缩放检测图，1080P 缩到 480 长边
    private func shrink(_ pixel: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(pixel)
        let h = CVPixelBufferGetHeight(pixel)
        guard w > 0, h > 0 else { return nil }

        let scale = 480.0 / Double(max(w, h))
        let nw = max(64, Int(Double(w) * scale))
        let nh = max(64, Int(Double(h) * scale))

        if small == nil || CVPixelBufferGetWidth(small!) != nw || CVPixelBufferGetHeight(small!) != nh {
            var pb: CVPixelBuffer?
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: nw,
                kCVPixelBufferHeightKey as String: nh,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, nw, nh,
                                kCVPixelFormatType_32BGRA,
                                attrs as CFDictionary, &pb)
            small = pb
        }
        guard let buf = small else { return nil }
        ctx.render(CIImage(cvPixelBuffer: pixel),
                   to: buf,
                   bounds: CGRect(x: 0, y: 0, width: nw, height: nh),
                   colorSpace: space)
        return buf
    }

    /// 取当前帧的人脸。每 3 帧刷新一次；连续 0.8 秒检不到脸就当作没有。
    func geometry(pixel: CVPixelBuffer, rotate: Bool) -> FaceGeometry? {
        tick &+= 1
        if tick % 3 == 1 {
            if let g = detect(pixel: pixel) {
                cached = rotate ? g.rotatedRight() : g
                lastHit = Date()
            } else if Date().timeIntervalSince(lastHit) > 0.8 {
                cached = nil
            }
        }
        return cached
    }

    func reset() {
        cached = nil
        lastHit = .distantPast
        tick = 0
    }

    // MARK: - 检测

    private func detect(pixel: CVPixelBuffer) -> FaceGeometry? {
        guard let buf = shrink(pixel) else { return nil }

        let req = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buf, orientation: .up, options: [:])
        do {
            try handler.perform([req])
        } catch {
            return nil
        }

        guard let faces = req.results, !faces.isEmpty else { return nil }
        // 有多张脸时取最大的一张（自拍场景基本只有自己）
        let face = faces.max { a, b in
            a.boundingBox.width * a.boundingBox.height < b.boundingBox.width * b.boundingBox.height
        }
        guard let face = face, let lm = face.landmarks else { return nil }

        let box = face.boundingBox

        func toImage(_ p: CGPoint) -> CGPoint {
            CGPoint(x: box.minX + p.x * box.width,
                    y: box.minY + p.y * box.height)
        }

        /// 区域重心的整图坐标
        func center(_ r: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let r = r, r.pointCount > 0 else { return nil }
            var sx: CGFloat = 0
            var sy: CGFloat = 0
            let pts = r.normalizedPoints
            for i in 0..<r.pointCount {
                sx += CGFloat(pts[i].x)
                sy += CGFloat(pts[i].y)
            }
            let n = CGFloat(r.pointCount)
            return toImage(CGPoint(x: sx / n, y: sy / n))
        }

        /// 区域跨度（取较长边），用于推算半径
        func spread(_ r: VNFaceLandmarkRegion2D?) -> CGFloat {
            guard let r = r, r.pointCount > 1 else { return 0 }
            var minX = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude
            var minY = CGFloat.greatestFiniteMagnitude
            var maxY = -CGFloat.greatestFiniteMagnitude
            let pts = r.normalizedPoints
            for i in 0..<r.pointCount {
                let x = CGFloat(pts[i].x)
                let y = CGFloat(pts[i].y)
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
            return max(maxX - minX, maxY - minY) * box.width
        }

        guard let le = center(lm.leftPupil) ?? center(lm.leftEye),
              let re = center(lm.rightPupil) ?? center(lm.rightEye) else {
            return nil
        }

        let leR = max(spread(lm.leftEye), box.width * 0.045) * 0.85
        let reR = max(spread(lm.rightEye), box.width * 0.045) * 0.85

        // 下颌轮廓：不依赖点的方向，直接用坐标分成左右两侧，避免左右脸张冠李戴
        var contour: [CGPoint] = []
        if let c = lm.faceContour, c.pointCount > 4 {
            let pts = c.normalizedPoints
            for i in 0..<c.pointCount {
                contour.append(toImage(CGPoint(x: CGFloat(pts[i].x), y: CGFloat(pts[i].y))))
            }
        }

        let midX = box.midX
        let upper = box.minY + box.height * 0.20      // 高于下巴
        let lower = box.minY + box.height * 0.46      // 低于颧骨
        var lc: [CGPoint] = []
        var rc: [CGPoint] = []
        for p in contour where p.y > upper && p.y < lower {
            if p.x < midX { lc.append(p) } else { rc.append(p) }
        }

        func avg(_ a: [CGPoint], fallback: CGPoint) -> CGPoint {
            guard !a.isEmpty else { return fallback }
            var sx: CGFloat = 0
            var sy: CGFloat = 0
            for p in a { sx += p.x; sy += p.y }
            return CGPoint(x: sx / CGFloat(a.count), y: sy / CGFloat(a.count))
        }

        let fbL = CGPoint(x: box.minX + box.width * 0.16, y: box.minY + box.height * 0.34)
        let fbR = CGPoint(x: box.maxX - box.width * 0.16, y: box.minY + box.height * 0.34)

        return FaceGeometry(
            bounds: box,
            leftEye: le,
            rightEye: re,
            leftEyeRadius: leR,
            rightEyeRadius: reR,
            leftCheek: avg(lc, fallback: fbL),
            rightCheek: avg(rc, fallback: fbR),
            contour: contour
        )
    }
}
