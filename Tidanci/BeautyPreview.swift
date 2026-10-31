import Foundation
import AVFoundation
import UIKit
import SwiftUI

/// 把处理后的帧推进预览层。用 AVSampleBufferDisplayLayer 而不是 Metal，
/// 少一层渲染目标管理，也不会因为 drawable 拿不到而掉帧。
final class PreviewSink {
    static let shared = PreviewSink()

    private weak var layer: AVSampleBufferDisplayLayer?
    private var format: CMVideoFormatDescription?
    private var cachedW = 0
    private var cachedH = 0

    func attach(_ l: AVSampleBufferDisplayLayer) {
        layer = l
        l.videoGravity = .resizeAspectFill
        if l.status == .failed { l.flush() }
    }

    func detach(_ l: AVSampleBufferDisplayLayer) {
        if layer === l { layer = nil }
    }

    func push(_ pixel: CVPixelBuffer, pts: CMTime) {
        guard let layer = layer else { return }
        if layer.status == .failed {
            layer.flush()
        }
        guard let fmt = formatFor(pixel) else { return }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        let st = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                          imageBuffer: pixel,
                                                          formatDescription: fmt,
                                                          sampleTiming: &timing,
                                                          sampleBufferOut: &sb)
        guard st == noErr, let buffer = sb else { return }
        layer.enqueue(buffer)
    }

    private func formatFor(_ pixel: CVPixelBuffer) -> CMVideoFormatDescription? {
        let w = CVPixelBufferGetWidth(pixel)
        let h = CVPixelBufferGetHeight(pixel)
        if w == cachedW, h == cachedH, let f = format { return f }

        var f: CMVideoFormatDescription?
        let st = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                              imageBuffer: pixel,
                                                              formatDescriptionOut: &f)
        guard st == noErr else { return nil }
        cachedW = w
        cachedH = h
        format = f
        return f
    }
}

final class SampleBufferUIView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var sbLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        sbLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            PreviewSink.shared.attach(sbLayer)
        } else {
            PreviewSink.shared.detach(sbLayer)
        }
    }
}

struct FilterPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> SampleBufferUIView {
        SampleBufferUIView()
    }

    func updateUIView(_ uiView: SampleBufferUIView, context: Context) {}
}
