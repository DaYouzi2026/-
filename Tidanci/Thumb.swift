import Foundation
import AVFoundation
import UIKit
import Combine

/// 作品缩略图和时长缓存（后台生成，主线程刷新）
final class ThumbStore: ObservableObject {
    static let shared = ThumbStore()

    @Published private(set) var images: [URL: UIImage] = [:]
    @Published private(set) var durations: [URL: Double] = [:]
    private var pending: Set<URL> = []

    private let q = DispatchQueue(label: "tidanci.thumb", qos: .userInitiated)

    func load(_ url: URL) {
        if images[url] != nil || pending.contains(url) { return }
        pending.insert(url)
        q.async { [weak self] in
            let asset = AVURLAsset(url: url)
            let secs = CMTimeGetSeconds(asset.duration)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 420, height: 420)
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            let t = CMTime(seconds: 0.1, preferredTimescale: 600)
            let cg = try? gen.copyCGImage(at: t, actualTime: nil)
            let img = cg.map { UIImage(cgImage: $0) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pending.remove(url)
                if let img = img { self.images[url] = img }
                if secs.isFinite && secs > 0 { self.durations[url] = secs }
            }
        }
    }

    func forget(_ url: URL) {
        images.removeValue(forKey: url)
        durations.removeValue(forKey: url)
    }

    func reset() {
        images.removeAll()
        durations.removeAll()
        pending.removeAll()
    }
}
