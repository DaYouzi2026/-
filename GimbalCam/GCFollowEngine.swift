import Foundation
import SwiftUI

/// 全新跟随算法：死区过滤 + 非线性增益 + 低通平滑，参数实时可调
final class GCFollowEngine: ObservableObject {

    @Published var gain: Float = 1.4          // 灵敏度
    @Published var deadzone: Float = 0.06     // 死区
    @Published var smoothing: Float = 0.35    // 平滑系数
    @Published var invertX = false
    @Published var invertY = false
    @Published var enabled = false

    private var lastYaw: Float = 0, lastPitch: Float = 0

    func compute(dx: Float, dy: Float) -> (Int, Int)? {
        guard enabled else { lastYaw = 0; lastPitch = 0; return nil }
        var x = invertX ? -dx : dx
        var y = invertY ? -dy : dy

        if abs(x) < deadzone { x = 0 }
        if abs(y) < deadzone { y = 0 }
        if x == 0 && y == 0 { lastYaw = 0; lastPitch = 0; return nil }

        let ty = sign(x) * pow(abs(x), 0.75) * gain * 1000
        let tp = sign(y) * pow(abs(y), 0.75) * gain * 1000

        lastYaw += smoothing * (ty - lastYaw)
        lastPitch += smoothing * (tp - lastPitch)

        let yaw = max(-1000, min(1000, Int(lastYaw)))
        let pitch = max(-1000, min(1000, Int(lastPitch)))
        return (yaw, pitch)
    }

    private func sign(_ v: Float) -> Float { v >= 0 ? 1 : -1 }
    func reset() { lastYaw = 0; lastPitch = 0 }

    // 横竖屏锁定（防抖滞回）
    private(set) var orientationLocked = false
    private var lastOrientation = 0
    private var stableCount = 0
    private var unlockCount = 0
    private let lockFrames = 12
    private let unlockFrames = 30

    @discardableResult
    func updateOrientation(landscape: Bool) -> Int {
        let cur = landscape ? 1 : 0
        if orientationLocked {
            if cur != lastOrientation {
                unlockCount += 1
                if unlockCount >= unlockFrames {
                    orientationLocked = false; lastOrientation = cur
                    stableCount = 0; unlockCount = 0
                }
            } else { unlockCount = 0 }
        } else {
            if cur == lastOrientation {
                stableCount += 1
                if stableCount >= lockFrames { orientationLocked = true; unlockCount = 0 }
            } else { lastOrientation = cur; stableCount = 0 }
        }
        return lastOrientation
    }

    func manualUnlock() { orientationLocked = false; stableCount = 0; unlockCount = 0 }
}
