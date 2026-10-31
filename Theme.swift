import SwiftUI
import Foundation

/// 浅色主题，和安卓版保持一致
enum T {
    static let bg = Color(hex: 0xF4F5FA)
    static let surface = Color.white
    static let accent = Color(hex: 0x6C5CE7)
    static let ink = Color(hex: 0x1B1E28)
    static let sub = Color(hex: 0x8A90A2)
    static let line = Color(hex: 0xE6E8F0)
    static let danger = Color(hex: 0xE5484D)
    static let ok = Color(hex: 0x12B76A)

    /// 拍摄页的浮层色
    static let overlay = Color.black.opacity(0.55)
    static let overlaySoft = Color.black.opacity(0.35)
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

/// 浅色圆角卡片
struct CardModifier: ViewModifier {
    var pad: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(pad)
            .background(T.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(T.line, lineWidth: 1)
            )
    }
}

extension View {
    func card(pad: CGFloat = 16) -> some View { modifier(CardModifier(pad: pad)) }
}
