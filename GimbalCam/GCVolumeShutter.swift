import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// 把云台 HID 拍照键（iOS 收到的是"音量键"事件）转成相机快门。
/// 关键：必须先激活音频会话，否则 iOS 把音量键当成铃声音量，outputVolume 不变，KVO 不触发。
final class GCVolumeShutter: NSObject {

    var onShutter: (() -> Void)?
    private var volumeObservation: NSKeyValueObservation?
    private var lastFire: TimeInterval = 0
    private var started = false
    private var isCentering = false
    private var mediaVolumeView: MPVolumeView?
    private var volumeSlider: UISlider?

    func start() {
        guard !started else { return }
        started = true

        // 关键修复：激活音频会话，让音量键作用于"媒体音量"而非铃声音量。
        // 用 .playAndRecord 以兼容录像收音；.mixWithOthers 避免打断其他声音。
        let ses = AVAudioSession.sharedInstance()
        try? ses.setCategory(.playAndRecord, mode: .default,
                             options: [.defaultToSpeaker, .mixWithOthers, .allowBluetooth])
        try? ses.setActive(true, options: [])

        // 准备一个隐藏的 MPVolumeView 用于把媒体音量静默调到中间值，
        // 保证音量 + 和 - 两个方向都能触发 KVO。
        let vv = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        vv.showsRouteButton = false
        for sub in vv.subviews {
            if let s = sub as? UISlider { volumeSlider = s; break }
        }
        mediaVolumeView = vv
        if let win = UIApplication.shared.keyWindow ?? UIApplication.shared.windows.first {
            win.addSubview(vv)
        }
        centerVolume()

        volumeObservation = ses.observe(\.outputVolume, options: [.new]) {
            [weak self] _, change in
            guard let self = self, let _ = change.newValue else { return }
            if self.isCentering { return }
            let now = Date().timeIntervalSince1970
            guard now - self.lastFire > 0.25 else { return }
            self.lastFire = now
            self.fire()
            // 触发后重新居中，避免音量到顶后按不动
            self.centerVolume()
        }

        // 蓝牙遥控的播放/暂停键也当快门
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in self?.fire(); return .success }
        cc.pauseCommand.addTarget { [weak self] _ in self?.fire(); return .success }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.fire(); return .success }
    }

    func stop() {
        volumeObservation?.invalidate()
        volumeObservation = nil
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.removeTarget(nil)
        cc.pauseCommand.removeTarget(nil)
        cc.togglePlayPauseCommand.removeTarget(nil)
        mediaVolumeView?.removeFromSuperview()
        mediaVolumeView = nil
        started = false
    }

    private func fire() {
        DispatchQueue.main.async { [weak self] in self?.onShutter?() }
    }

    private func centerVolume() {
        isCentering = true
        DispatchQueue.main.async { [weak self] in
            self?.volumeSlider?.value = 0.5
            self?.volumeSlider?.sendActions(for: .valueChanged)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.isCentering = false
        }
    }
}
