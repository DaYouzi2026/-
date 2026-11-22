import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// 把云台的 HID 拍照键（发给手机的是「音量键」事件）转成相机快门。
/// 同时接收蓝牙遥控常见的 play/pause 按键。
final class GCVolumeShutter: NSObject {

    /// 收到拍照键时的回调
    var onShutter: (() -> Void)?
    private var volumeObservation: NSKeyValueObservation?
    private var lastFire: TimeInterval = 0
    private var lastVolume: Float = 0.5
    private var started = false
    private var isCentering = false

    /// 启动监听。会把系统音量静默调到中间值，保证音量+/-两个方向都能触发。
    func start() {
        guard !started else { return }
        started = true

        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { /* 忽略：不影响监听 */ }

        centerVolume()

        // 音量键：观察系统输出音量变化
        let session = AVAudioSession.sharedInstance()
        lastVolume = session.outputVolume
        volumeObservation = session.observe(\.outputVolume, options: [.new]) {
            [weak self] observed, change in
            guard let self = self, let v = change.newValue else { return }
            if self.isCentering { self.lastVolume = v; return }
            let now = Date().timeIntervalSince1970
            guard now - self.lastFire > 0.25 else { return }
            self.lastFire = now
            self.lastVolume = v
            self.fire()
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
        started = false
    }

    private func fire() {
        DispatchQueue.main.async { [weak self] in self?.onShutter?() }
    }

    /// 借 MPVolumeView 的滑块把音量设到 0.5（纯公开 API，不调私有方法）
    private func centerVolume() {
        isCentering = true
        let volumeView = MPVolumeView(frame: .zero)
        var slider: UISlider?
        for sub in volumeView.subviews {
            if let s = sub as? UISlider { slider = s; break }
        }
        slider?.value = 0.5
        slider?.sendActions(for: .valueChanged)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.isCentering = false
            self?.lastVolume = AVAudioSession.sharedInstance().outputVolume
        }
    }
}
