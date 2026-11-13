import SwiftUI

/// 圆形图标按钮（拍摄页浮层用）
struct RoundIconButton: View {
    let icon: String
    var size: CGFloat = 36
    var bg: Color = T.overlay
    var fg: Color = .white

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundColor(fg)
            .frame(width: size, height: size)
            .background(bg)
            .clipShape(Circle())
            // 视觉上还是 38，但点按区域补到 44 —— 单手举着手机按，差 6pt 就是按不中
            .frame(minWidth: T.touch, minHeight: T.touch)
            .contentShape(Rectangle())
    }
}

/// 拍摄页的胶囊开关
struct Chip: View {
    let text: String
    var active: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(active ? .white : Color.white.opacity(0.92))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(active ? T.accent : Color.white.opacity(0.16))
            .clipShape(Capsule())
    }
}

/// 列表里的小标签
struct Tag: View {
    let text: String
    var bg: Color = T.bg
    var fg: Color = T.sub

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(bg)
            .clipShape(Capsule())
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let sub: String

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(T.accent.opacity(0.10)).frame(width: 78, height: 78)
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .light))
                    .foregroundColor(T.accent)
            }
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(T.ink)
            Text(sub)
                .font(.system(size: 13))
                .foregroundColor(T.sub)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
        .padding(.horizontal, 34)
    }
}

/// 带标题的白色分组卡片
struct GroupCard<Content: View>: View {
    private let title: String?
    private let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let t = title {
                Text(t)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(T.sub)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) { content }
                .background(T.surface)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(T.line, lineWidth: 1)
                )
        }
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(T.line)
            .frame(height: 1)
            .padding(.leading, 16)
    }
}

struct ScreenHeader: View {
    let title: String
    var sub: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(T.ink)
            if let s = sub {
                Text(s)
                    .font(.system(size: 12))
                    .foregroundColor(T.sub)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Toast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.75))
            .clipShape(Capsule())
    }
}
