import SwiftUI

/// 提词框的位置与大小。全部用相对屏幕的比例存，换机型、横竖屏都不会跑偏。
struct BoxLayout: Equatable {
    var x: CGFloat
    var y: CGFloat
    var w: CGFloat
    var h: CGFloat

    /// 中等框：宽度占 86%，高度约四分之一屏
    static let standard = BoxLayout(x: 0.07, y: 0.15, w: 0.86, h: 0.295)

    static let minW: CGFloat = 0.40
    static let minH: CGFloat = 0.13
    static let maxW: CGFloat = 0.96
    static let maxH: CGFloat = 0.62
    /// 框的最大下沿，给底部工具栏让位
    static let maxBottom: CGFloat = 0.68

    func rect(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width,
               y: y * size.height,
               width: w * size.width,
               height: h * size.height)
    }

    func clamped() -> BoxLayout {
        var l = self
        l.w = min(max(l.w, BoxLayout.minW), BoxLayout.maxW)
        l.h = min(max(l.h, BoxLayout.minH), BoxLayout.maxH)
        l.x = min(max(l.x, 0.02), 0.98 - l.w)
        l.y = min(max(l.y, 0.05), max(0.05, BoxLayout.maxBottom - l.h))
        return l
    }
}

/// 三档预设 + 满屏，点一下直接换
enum BoxPreset: String, CaseIterable, Identifiable {
    case small, medium, large, full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        case .full: return "满屏"
        }
    }

    var layout: BoxLayout {
        switch self {
        case .small:  return BoxLayout(x: 0.14, y: 0.18, w: 0.72, h: 0.20)
        case .medium: return .standard
        case .large:  return BoxLayout(x: 0.05, y: 0.11, w: 0.90, h: 0.38)
        case .full:   return BoxLayout(x: 0.02, y: 0.07, w: 0.96, h: 0.58)
        }
    }

    /// 当前布局离哪一档最近（用来高亮选中态）
    static func nearest(_ l: BoxLayout) -> BoxPreset? {
        for p in BoxPreset.allCases where abs(p.layout.h - l.h) < 0.03 && abs(p.layout.w - l.w) < 0.04 {
            return p
        }
        return nil
    }
}

/// 悬浮提词框：拖动顶部把手移动，右下角手柄改大小
struct PrompterBox<Content: View>: View {
    @Binding var layout: BoxLayout
    let canvas: CGSize
    var bordered: Bool
    var focusLine: Bool
    var onCommit: (BoxLayout) -> Void
    let content: (CGSize) -> Content

    @State private var moveBase: BoxLayout?
    @State private var sizeBase: BoxLayout?
    /// 拖动期间的本地副本，避免每帧回写父视图把相机预览也一起重算
    @State private var live: BoxLayout?

    private let radius: CGFloat = 22

    /// 父视图改了布局（比如点预设），丢弃本地副本
    private var shown: BoxLayout { live ?? layout }

    init(layout: Binding<BoxLayout>,
         canvas: CGSize,
         bordered: Bool = true,
         focusLine: Bool = true,
         onCommit: @escaping (BoxLayout) -> Void = { _ in },
         @ViewBuilder content: @escaping (CGSize) -> Content) {
        self._layout = layout
        self.canvas = canvas
        self.bordered = bordered
        self.focusLine = focusLine
        self.onCommit = onCommit
        self.content = content
    }

    var body: some View {
        let r = shown.rect(in: canvas)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(bordered ? Color.black.opacity(0.30) : Color.clear)

            content(CGSize(width: r.width, height: r.height))
                .frame(width: r.width, height: r.height)

            if focusLine {
                Rectangle()
                    .fill(
                        LinearGradient(colors: [Color.white.opacity(0.0),
                                                Color.white.opacity(0.18),
                                                Color.white.opacity(0.0)],
                                       startPoint: .leading,
                                       endPoint: .trailing)
                    )
                    .frame(width: max(0, r.width - 28), height: 1)
                    .offset(x: 14, y: r.height * ScriptTextView.focus)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: r.width, height: r.height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.white.opacity(bordered ? 0.20 : 0.0), lineWidth: 1)
        )
        .overlay(alignment: .top) { grip }
        .overlay(alignment: .bottomTrailing) { knob }
        .shadow(color: Color.black.opacity(bordered ? 0.28 : 0), radius: 16, x: 0, y: 8)
        .position(x: r.midX, y: r.midY)
        .onChange(of: layout) { _ in live = nil }
    }

    // MARK: 把手

    private var grip: some View {
        Group {
            if bordered {
                Capsule()
                    .fill(Color.white.opacity(0.62))
                    .frame(width: 40, height: 4)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                    .offset(y: -22)
                    .gesture(moveGesture)
            }
        }
    }

    // MARK: 缩放手柄

    private var knob: some View {
        Group {
            if bordered {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.18))
                    Circle()
                        .stroke(Color.white.opacity(0.50), lineWidth: 1)
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.88))
                }
                .frame(width: 26, height: 26)
                .contentShape(Circle())
                .offset(x: 9, y: 9)
                .gesture(resizeGesture)
            }
        }
    }

    // MARK: 手势

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { v in
                if moveBase == nil { moveBase = shown }
                guard let b = moveBase, canvas.width > 1, canvas.height > 1 else { return }
                var l = b
                l.x = b.x + v.translation.width / canvas.width
                l.y = b.y + v.translation.height / canvas.height
                live = l.clamped()
            }
            .onEnded { _ in
                commit()
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { v in
                if sizeBase == nil { sizeBase = shown }
                guard let b = sizeBase, canvas.width > 1, canvas.height > 1 else { return }
                var l = b
                l.w = b.w + v.translation.width / canvas.width
                l.h = b.h + v.translation.height / canvas.height
                live = l.clamped()
            }
            .onEnded { _ in
                commit()
            }
    }

    private func commit() {
        moveBase = nil
        sizeBase = nil
        if let v = live {
            layout = v
            onCommit(v)
        }
        live = nil
    }
}
