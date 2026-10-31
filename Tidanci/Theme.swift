import SwiftUI
import Foundation

/// 设计令牌。浅色为主，拍摄页单独用暗色覆盖层。
enum T {
    static let bg = Color(hex: 0xF3F4FA)
    static let surface = Color.white
    static let surface2 = Color(hex: 0xF7F8FC)
    static let accent = Color(hex: 0x6C5CE7)
    static let accent2 = Color(hex: 0x4B7BFF)
    static let ink = Color(hex: 0x15181F)
    static let ink2 = Color(hex: 0x3F4557)
    static let sub = Color(hex: 0x8A90A2)
    static let line = Color(hex: 0xE7E9F2)
    static let danger = Color(hex: 0xF0444B)
    static let ok = Color(hex: 0x12B76A)
    static let warn = Color(hex: 0xF79009)

    /// 拍摄页浮层
    static let overlay = Color.black.opacity(0.52)
    static let overlaySoft = Color.black.opacity(0.32)

    static let grad = LinearGradient(colors: [Color(hex: 0x6C5CE7), Color(hex: 0x4B7BFF)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing)

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
