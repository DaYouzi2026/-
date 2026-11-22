import SwiftUI
import UIKit

// MARK: - 提词文字（UITextView 承载，匀速滚动）

final class MiniScrollDriver: ObservableObject {
    @Published private(set) var running = false
    var speed: Double = 45          // 每秒滚动的像素
    weak var textView: UITextView?
    private var timer: Timer?

    func attach(_ tv: UITextView) { textView = tv }

    func play() {
        guard textView != nil, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.step()
        }
        running = true
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        running = false
    }

    func rewind() {
        guard let tv = textView else { return }
        tv.contentOffset = CGPoint(x: 0, y: -tv.contentInset.top)
    }

    private func step() {
        guard let tv = textView else { pause(); return }
        let maxY = tv.contentSize.height + tv.contentInset.bottom - tv.bounds.height
        var y = tv.contentOffset.y + CGFloat(speed) / 30.0
        if y >= maxY {
            y = max(0, maxY)
            tv.contentOffset = CGPoint(x: tv.contentOffset.x, y: y)
            pause()
            return
        }
        tv.contentOffset = CGPoint(x: tv.contentOffset.x, y: y)
    }
}

struct MiniPrompterText: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let mirror: Bool
    let boxHeight: CGFloat
    let driver: MiniScrollDriver

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.backgroundColor = .clear
        tv.isEditable = false
        tv.isSelectable = false
        tv.showsVerticalScrollIndicator = false
        tv.textContainerInset = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        context.coordinator.lastKey = ""
        driver.attach(tv)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let key = "\(text.count)-\(text.hashValue)-\(Int(fontSize))"
        if context.coordinator.lastKey != key {
            context.coordinator.lastKey = key
            let ps = NSMutableParagraphStyle()
            ps.lineSpacing = fontSize * 0.35
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: ps
            ]
            let off = tv.contentOffset
            tv.attributedText = NSAttributedString(string: text, attributes: attrs)
            tv.contentOffset = off
        }
        let h = max(boxHeight, 80)
        let top = h * 0.40
        let bottom = max(0, h - top)
        if abs(tv.contentInset.top - top) > 1.5 || abs(tv.contentInset.bottom - bottom) > 1.5 {
            tv.contentInset = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        }
        tv.transform = mirror ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastKey = "" }
}

// MARK: - 可拖动 / 缩放的提词框

struct MiniBoxLayout: Equatable {
    var x: CGFloat
    var y: CGFloat
    var w: CGFloat
    var h: CGFloat

    static let standard = MiniBoxLayout(x: 0.07, y: 0.12, w: 0.86, h: 0.30)

    func rect(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height,
               width: w * size.width, height: h * size.height)
    }

    func clamped() -> MiniBoxLayout {
        var l = self
        l.w = min(max(l.w, 0.40), 0.96)
        l.h = min(max(l.h, 0.12), 0.62)
        l.x = min(max(l.x, 0.02), 0.98 - l.w)
        l.y = min(max(l.y, 0.05), 0.86 - l.h)
        return l
    }
}

struct MiniBox<Content: View>: View {
    @Binding var layout: MiniBoxLayout
    let canvas: CGSize
    var bordered: Bool
    let content: (CGSize) -> Content

    @State private var live: MiniBoxLayout?
    @State private var moveBase: MiniBoxLayout?
    @State private var sizeBase: MiniBoxLayout?

    private var shown: MiniBoxLayout { live ?? layout }

    var body: some View {
        let r = shown.rect(in: canvas)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(bordered ? 0.34 : 0.0))
            content(CGSize(width: r.width, height: r.height))
                .frame(width: r.width, height: r.height)
                .mask(
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white, location: 0.08),
                        .init(color: .white, location: 0.92),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                )
            if bordered {
                Rectangle()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: max(0, r.width - 28), height: 1)
                    .offset(x: 14, y: r.height * 0.40)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: r.width, height: r.height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(bordered ? 0.22 : 0), lineWidth: 1)
        )
        .overlay(alignment: .top) {
            Capsule().fill(Color.white.opacity(0.55))
                .frame(width: 40, height: 4)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
                .gesture(moveGesture)
                .opacity(bordered ? 1 : 0)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.16)))
                .padding(4)
                .contentShape(Circle())
                .gesture(resizeGesture)
                .opacity(bordered ? 1 : 0)
        }
        .position(x: r.midX, y: r.midY)
    }

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
            .onEnded { _ in commit() }
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
            .onEnded { _ in commit() }
    }

    private func commit() {
        moveBase = nil
        sizeBase = nil
        if let v = live { layout = v }
        live = nil
    }
}

// MARK: - 主界面

struct MiniPrompterView: View {
    @StateObject private var cam = MiniCam()
    @StateObject private var driver = MiniScrollDriver()

    @AppStorage("mini.text") private var scriptText = "把你的台词粘贴到这里。\n\n点下方「台词」可以编辑、粘贴或清空。\n\n点「播放」，文字就会匀速往上滚；拖动提词框顶部的横条可以移动位置，拖右下角可以改大小。"
    @AppStorage("mini.font") private var fontSize = 30.0
    @AppStorage("mini.speed") private var speed = 45.0
    @AppStorage("mini.mirror") private var mirror = false
    @AppStorage("mini.border") private var bordered = true
    @AppStorage("mini.showBox") private var showBox = true
    @AppStorage("mini.box.x") private var boxX = 0.07
    @AppStorage("mini.box.y") private var boxY = 0.12
    @AppStorage("mini.box.w") private var boxW = 0.86
    @AppStorage("mini.box.h") private var boxH = 0.30

    @State private var editing = false
    @State private var showTools = true

    private var box: Binding<MiniBoxLayout> {
        Binding(
            get: { MiniBoxLayout(x: CGFloat(boxX), y: CGFloat(boxY),
                                 w: CGFloat(boxW), h: CGFloat(boxH)) },
            set: { boxX = Double($0.x); boxY = Double($0.y)
                   boxW = Double($0.w); boxH = Double($0.h) }
        )
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                MiniPreview(session: cam.session, mirrored: cam.isFront)
                    .ignoresSafeArea()

                if showBox {
                    MiniBox(layout: box, canvas: geo.size, bordered: bordered) { size in
                        MiniPrompterText(text: scriptText, fontSize: fontSize,
                                         mirror: mirror, boxHeight: size.height,
                                         driver: driver)
                    }
                    .allowsHitTesting(bordered)
                }

                // 顶部状态
                VStack {
                    HStack {
                        Label(cam.isFront ? "前置" : "后置", systemImage: "camera")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(Color.black.opacity(0.45)))
                        Spacer()
                        if cam.recording {
                            HStack(spacing: 6) {
                                Circle().fill(Color.red).frame(width: 8, height: 8)
                                Text("录制中").font(.caption.weight(.medium))
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(Color.black.opacity(0.45)))
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    Spacer()
                }
                .allowsHitTesting(false)

                if !cam.message.isEmpty {
                    VStack {
                        Spacer()
                        Text(cam.message)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                            .padding(.bottom, 190)
                    }
                    .allowsHitTesting(false)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { cam.message = "" }
                    }
                }

                // 底部工具栏
                if showTools {
                    VStack(spacing: 14) {
                        HStack(spacing: 10) {
                            toolButton("doc.text", "台词") { editing = true }
                            toolButton(driver.running ? "pause.fill" : "play.fill",
                                       driver.running ? "暂停" : "播放") {
                                driver.running ? driver.pause() : driver.play()
                            }
                            toolButton("backward.end.fill", "回开头") { driver.rewind() }
                            toolButton("arrow.triangle.2.circlepath", "翻转") { cam.flip() }
                            toolButton(showBox ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle",
                                       showBox ? "隐藏提词" : "显示提词") {
                                showBox.toggle()
                                if !showBox { driver.pause() }
                            }
                        }

                        HStack(spacing: 16) {
                            stepperButton("-", "font") { fontSize = max(16, fontSize - 2) }
                            Text("字号 \(Int(fontSize))").font(.caption).foregroundColor(.white.opacity(0.85))
                            stepperButton("+", "font") { fontSize = min(56, fontSize + 2) }
                            Divider().frame(height: 18).background(Color.white.opacity(0.25))
                            stepperButton("-", "speed") { speed = max(8, speed - 8); driver.speed = speed }
                            Text("速度 \(Int(speed))").font(.caption).foregroundColor(.white.opacity(0.85))
                            stepperButton("+", "speed") { speed = min(160, speed + 8); driver.speed = speed }
                        }

                        HStack(spacing: 26) {
                            toggleChip("镜像", mirror) { mirror.toggle() }
                            Button {
                                if cam.recording { cam.stopRecord() } else { cam.startRecord() }
                            } label: {
                                ZStack {
                                    Circle().stroke(Color.white, lineWidth: 3).frame(width: 74, height: 74)
                                    Circle().fill(Color.red)
                                        .frame(width: cam.recording ? 30 : 58, height: cam.recording ? 30 : 58)
                                        .clipShape(RoundedRectangle(cornerRadius: cam.recording ? 6 : 29))
                                }
                            }
                            toggleChip("边框", bordered) { bordered.toggle() }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color.black.opacity(0.55).ignoresSafeArea(edges: .bottom))
                }

                // 收起/展开工具栏
                VStack {
                    Spacer()
                    HStack { Spacer()
                        Button {
                            withAnimation { showTools.toggle() }
                        } label: {
                            Image(systemName: showTools ? "chevron.down" : "chevron.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Circle().fill(Color.black.opacity(0.5)))
                        }
                        Spacer()
                    }
                    .padding(.bottom, showTools ? 218 : 16)
                }
                .allowsHitTesting(true)
            }
        }
        .onAppear { driver.speed = speed }
        .sheet(isPresented: $editing) {
            TextEditView(text: $scriptText)
        }
    }

    private func toolButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 19))
                Text(title).font(.system(size: 11))
            }
            .foregroundColor(.white)
            .frame(minWidth: 52)
        }
    }

    private func stepperButton(_ symbol: String, _ tag: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol).font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.16)))
        }
    }

    private func toggleChip(_ title: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium))
                .foregroundColor(on ? .white : .white.opacity(0.55))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(on ? Color.white.opacity(0.22) : Color.white.opacity(0.08)))
        }
    }
}

// MARK: - 台词编辑

struct TextEditView: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.system(size: 18))
                .padding(8)
                .navigationTitle("台词")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button("粘贴") {
                            if let s = UIPasteboard.general.string { text = s }
                        }
                    }
                }
        }
    }
}
