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
    /// 插入顺序，用来做容量上限的淘汰（一部 4K 竖屏片子的缩略图解码后约 1MB）
    private var order: [URL] = []
    private let cap = 60

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
                if let img = img {
                    self.images[url] = img
                    self.order.append(url)
                    self.evictIfNeeded()
                }
                if secs.isFinite && secs > 0 { self.durations[url] = secs }
            }
        }
    }

    func forget(_ url: URL) {
        images.removeValue(forKey: url)
        durations.removeValue(forKey: url)
        pending.remove(url)
        order.removeAll { $0 == url }
    }

    /// 列表重新出现时调用：只剔掉已经不存在的文件。
    ///
    /// 以前这里调 `reset()` 全清，于是每次切 Tab 回来，几十个缩略图全部重新解码 ——
    /// 不但白等一秒，主线程还会被一屏 `UIImage` 顶得发卡。
    func prune(keeping urls: Set<URL>) {
        images = images.filter { urls.contains($0.key) }
        durations = durations.filter { urls.contains($0.key) }
        pending = pending.intersection(urls)
        order.removeAll { !urls.contains($0) }
    }

    func reset() {
        images.removeAll()
        durations.removeAll()
        pending.removeAll()
        order.removeAll()
    }

    private func evictIfNeeded() {
        guard order.count > cap else { return }
        let drop = order.count - cap + 10
        for u in order.prefix(drop) {
            images.removeValue(forKey: u)
        }
        order.removeFirst(min(drop, order.count))
    }
}
