import SwiftUI
import Foundation

/// 设计令牌。「聚光灯」主题：暖白底、琥珀焦点、墨绿主按钮、大标题顶栏。
/// 拍摄页单独用暗色覆盖层。
enum T {
    static let bg = Color(hex: 0xFBF8F2)          // 暖白背景
    static let surface = Color.white
    static let surface2 = Color(hex: 0xF6F1E8)    // 暖白浅面
    static let accent = Color(hex: 0xE0932E)      // 琥珀焦点色（收藏/选中/进度）
    static let accent2 = Color(hex: 0x1F6B4F)     // 墨绿（自动滚动等次强调）
    static let ink = Color(hex: 0x25201A)         // 暖墨色主文字
    static let ink2 = Color(hex: 0x554C40)
    static let sub = Color(hex: 0x9A8F7E)
    static let line = Color(hex: 0xEAE2D5)
    static let danger = Color(hex: 0xD9483B)
    static let ok = Color(hex: 0x1F8A5B)
    static let warn = Color(hex: 0xE0932E)

    /// 拍摄页浮层
    static let overlay = Color.black.opacity(0.52)
    static let overlaySoft = Color.black.opacity(0.32)

    /// 顶栏/主按钮渐变：琥珀 → 暖橙，聚光灯感
    static let grad = LinearGradient(colors: [Color(hex: 0xE8A33D), Color(hex: 0xD97B2C)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing)

    /// 最小点按区域（HIG：44×44）
    static let touch: CGFloat = 44
    static let shadow = Color.black.opacity(0.06)

    /// 按字符串生成稳定的品牌色，用来给台本卡片上色
    static func tint(_ seed: String) -> Color {
        var h: UInt64 = 5381
        for u in seed.unicodeScalars { h = (h &* 33) &+ UInt64(u.value) }
        return Color(hue: Double(h % 360) / 360.0, saturation: 0.52, brightness: 0.92)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: 1)
    }
}

extension Int {
    /// 秒数转 00:00
    var mmss: String {
        String(format: "%02d:%02d", self / 60, self % 60)
    }
}

extension Double {
    var mmss: String {
        let s = max(0, Int(rounded()))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// 浅色圆角卡片
struct CardModifier: ViewModifier {
    var pad: CGFloat = 16
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(pad)
            .background(T.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(T.line, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.045), radius: 12, x: 0, y: 4)
    }
}

extension View {
    func card(pad: CGFloat = 16) -> some View { modifier(CardModifier(pad: pad)) }

    /// 按下时轻微缩小，给点手感
    func pressable() -> some View { buttonStyle(PressScaleStyle()) }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
