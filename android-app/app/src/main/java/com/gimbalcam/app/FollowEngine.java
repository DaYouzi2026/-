package com.gimbalcam.app;

/**
 * 全新跟随算法：检测目标在画面中的偏移 → 死区过滤 → 比例增益 → 低通平滑 → 转头指令
 * 让"灵敏度/死区/平滑"都可实时调节，替代 Gimbal Play 锁死的迟钝算法。
 */
public class FollowEngine {

    // 可调参数（用户滑块）
    public float gain = 1.4f;          // 跟随增益（越大越灵敏）
    public float deadzone = 0.06f;     // 死区（目标偏移小于此值不动作，防抖）
    public float smoothing = 0.35f;    // 低通平滑系数（0-1，越小越平滑）
    public boolean invertX = false;    // 水平方向反转
    public boolean invertY = false;    // 俯仰方向反转
    public boolean enabled = false;

    private float lastYaw = 0, lastPitch = 0;

    /**
     * @param dx 目标中心相对画面中心的归一化水平偏移 [-1,1]，右为正
     * @param dy 归一化垂直偏移 [-1,1]，下为正
     * @return 转头指令 {yaw, pitch}，无动作返回 null
     */
    public int[] compute(float dx, float dy) {
        if (!enabled) { lastYaw = lastPitch = 0; return null; }

        if (invertX) dx = -dx;
        if (invertY) dy = -dy;

        // 死区过滤
        if (Math.abs(dx) < deadzone) dx = 0;
        if (Math.abs(dy) < deadzone) dy = 0;
        if (dx == 0 && dy == 0) { lastYaw = lastPitch = 0; return null; }

        // 非线性增益：小偏移更积极（解决"痴呆"），大偏移限幅
        float targetYaw = signPreserve(dx, (float) Math.pow(Math.abs(dx), 0.75f)) * gain * 1000f;
        float targetPitch = signPreserve(dy, (float) Math.pow(Math.abs(dy), 0.75f)) * gain * 1000f;

        // 低通平滑
        lastYaw = lastYaw + smoothing * (targetYaw - lastYaw);
        lastPitch = lastPitch + smoothing * (targetPitch - lastPitch);

        int yaw = clamp(Math.round(lastYaw), -1000, 1000);
        int pitch = clamp(Math.round(lastPitch), -1000, 1000);
        return new int[]{yaw, pitch};
    }

    private float signPreserve(float orig, float mag) {
        return orig >= 0 ? mag : -mag;
    }

    private int clamp(int v, int lo, int hi) { return Math.max(lo, Math.min(hi, v)); }

    public void reset() { lastYaw = lastPitch = 0; }

    // ---------------- 横竖屏姿态锁定（防抖滞回）----------------
    // 用户痛点：摆好横/竖屏后，动作稍变又切回去。
    // 方案：检测到姿态后连续 N 帧稳定才确认切换；锁定后需连续 M 帧相反的强信号才解锁。
    private boolean orientationLocked = false;
    private int lastOrientation = 0;   // 0=竖 1=横
    private int stableCount = 0;
    private int unlockCount = 0;
    private static final int LOCK_CONFIRM_FRAMES = 12;   // 约 0.4 秒稳定才锁定
    private static final int UNLOCK_CONFIRM_FRAMES = 30; // 解锁需更强、更久的信号

    /** @param landscape 当前画面/目标判定是否倾向于横屏 */
    public int updateOrientation(boolean landscape) {
        int cur = landscape ? 1 : 0;
        if (orientationLocked) {
            if (cur != lastOrientation) {
                unlockCount++;
                if (unlockCount >= UNLOCK_CONFIRM_FRAMES) {
                    orientationLocked = false;
                    lastOrientation = cur;
                    stableCount = 0; unlockCount = 0;
                }
            } else {
                unlockCount = 0;   // 抖动回原方向，取消解锁
            }
        } else {
            if (cur == lastOrientation) {
                stableCount++;
                if (stableCount >= LOCK_CONFIRM_FRAMES) {
                    orientationLocked = true;
                    unlockCount = 0;
                }
            } else {
                lastOrientation = cur;
                stableCount = 0;
            }
        }
        return lastOrientation;
    }

    public boolean isOrientationLocked() { return orientationLocked; }
    public void manualUnlock() { orientationLocked = false; stableCount = 0; unlockCount = 0; }
}
