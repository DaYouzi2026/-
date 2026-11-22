import SwiftUI

/// 悬浮提词框：拖动顶部移动、右下角缩放、匀速上滚、镜像、可隐藏边框
struct GCPrompter: View {
    @Binding var text: String
    @Binding var playing: Bool
    @Binding var speed: CGFloat
    @Binding var fontSize: CGFloat
    @Binding var mirrored: Bool
    @Binding var showBorder: Bool

    @State private var pos = CGPoint(x: UIScreen.main.bounds.width/2, y: UIScreen.main.bounds.height*0.42)
    @State private var size = CGSize(width: UIScreen.main.bounds.width*0.82, height: 240)
    @State private var scroll: CGFloat = 0
    @GestureState private var dragOffset = CGSize.zero
    @GestureState private var scaleDrag = CGSize.zero

    private let timer = Timer.publish(every: 0.03, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 内容
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: fontSize*0.5) {
                    ForEach(text.split(separator: "\n", omittingEmptySubsequences: false), id: \.self) { line in
                        Text(String(line))
                            .font(.system(size: fontSize))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
                .scaleEffect(x: mirrored ? -1 : 1, y: 1)
            }
            .frame(width: size.width, height: size.height)
            .offset(y: -scroll)
            .clipped()
            .background(Color.black.opacity(0.45))
            .overlay(
                Group {
                    if showBorder {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.85), lineWidth: 2)
                        // 焦点线
                        Rectangle().fill(Color.white.opacity(0.6))
                            .frame(height: 1)
                            .padding(.horizontal, 10)
                            .offset(y: size.height/2)
                    }
                }
            )
            .cornerRadius(14)

            // 顶部拖动条（移动整个框）
            Rectangle()
                .fill(Color.white.opacity(0.02))
                .frame(width: size.width - 50, height: 36)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .updating($dragOffset) { value, state, _ in state = value.translation }
                        .onEnded { g in pos = CGPoint(x: pos.x + g.translation.width,
                                                      y: pos.y + g.translation.height) }
                )
            // 缩放手柄（独立手势，不触发移动）
            Image(systemName: "arrowtriangle.down.right.fill")
                .foregroundColor(.white.opacity(0.8))
                .font(.system(size: 18))
                .offset(x: size.width - 24, y: size.height - 24)
                .gesture(
                    DragGesture()
                        .updating($scaleDrag) { value, state, _ in state = value.translation }
                        .onEnded { g in
                            size = CGSize(
                                width: max(160, min(UIScreen.main.bounds.width - 16, size.width + g.translation.width)),
                                height: max(100, min(UIScreen.main.bounds.height - 100, size.height + g.translation.height)))
                        }
                )
        }
        .frame(width: size.width, height: size.height)
        .position(x: pos.x + dragOffset.width, y: pos.y + dragOffset.height)
        .onReceive(timer) { _ in
            if playing { scroll += speed; if scroll > 4000 { scroll = 0 } }
        }
    }
}
