import SwiftUI
import AVFoundation
import UIKit

// MARK: - 提词文字层

/// 框内滚动的文字。真正的裁剪由外层 PrompterBox 负责，这里只管排版和滚动。
struct ScriptTextView: UIViewRepresentable {
    /// 当前朗读行落在框内的位置（0=顶，1=底）
    static let focus: CGFloat = 0.40

    let prepared: PreparedScript
    let readEnd: Int
    let fontSize: CGFloat
    let lineGap: CGFloat
    let mirror: Bool
    let boxHeight: CGFloat
    let onReady: (UITextView) -> Void
    let onResize: (UITextView) -> Void
    /// 双击某一行：把跟读起点挪到那一句。
    /// 识别再怎么设限也可能被一段重复的话带偏，给用户一个「我自己指」的出口，
    /// 比让他退出去重录一条强。
    var onLocate: ((Int) -> Void)? = nil

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.backgroundColor = .clear
        tv.isEditable = false
        tv.isSelectable = false
        tv.showsVerticalScrollIndicator = false
        tv.alwaysBounceVertical = true
        tv.textContainerInset = UIEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.numberOfTapsRequired = 2
        tv.addGestureRecognizer(tap)

        let h = max(boxHeight, 90)
        let top = h * ScriptTextView.focus
        tv.contentInset = UIEdgeInsets(top: top, left: 0, bottom: h - top, right: 0)
        tv.contentOffset = CGPoint(x: 0, y: -top)

        context.coordinator.lastHeight = h
        // 别在视图更新过程中改 State，延到下一个 runloop
        DispatchQueue.main.async { onReady(tv) }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncInset(tv)
        context.coordinator.apply(tv)
        tv.transform = mirror ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: ScriptTextView
        var lastHeight: CGFloat = 0
        private var lastTextKey = ""
        private var lastReadEnd = -1

        init(_ p: ScriptTextView) {
            parent = p
            super.init()
        }

        /// 双击：算出点到的是第几个字符，交给外面换算成台本位置
        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let tv = g.view as? UITextView else { return }
            let p = g.location(in: tv)
            let inText = CGPoint(x: p.x - tv.textContainerInset.left,
                                 y: p.y - tv.textContainerInset.top)
            let idx = tv.layoutManager.characterIndex(for: inText,
                                                     in: tv.textContainer,
                                                     fractionOfDistanceBetweenInsertionPoints: nil)
            parent.onLocate?(idx)
        }

        /// 框被拖动改大改小时，内边距要跟着变，否则焦点线会跑偏
        func syncInset(_ tv: UITextView) {
            let h = max(parent.boxHeight, 90)
            guard abs(h - lastHeight) > 1.5 else { return }
            let oldTop = tv.contentInset.top
            let top = h * ScriptTextView.focus
            tv.contentInset = UIEdgeInsets(top: top, left: 0, bottom: h - top, right: 0)
            // 补偿位移，拖动过程中文字不会乱跳
            tv.contentOffset = CGPoint(x: 0, y: tv.contentOffset.y + (top - oldTop))
            lastHeight = h
            let cb = parent.onResize
            DispatchQueue.main.async { cb(tv) }
        }

        /// 排版只在「文本 / 字号 / 行距」变了时重建；已读高亮单独走 textStorage。
        ///
        /// v6：原来把 readEnd 也放进了 key，于是每认出一个字就 `tv.attributedText = s`
        /// 整篇重设一次。给 attributedText 赋值会重置 contentOffset、并取消正在跑的
        /// 滚动动画 —— 高亮（改颜色）立刻生效，滚动被反复打断停在原地。
        /// 这就是「框已经跳到下一行、页面却不翻」的机器原因。
        func apply(_ tv: UITextView) {
            let textKey = "\(parent.prepared.text.count)|\(Int(parent.fontSize))|\(Int(parent.lineGap * 100))"
            if textKey != lastTextKey {
                lastTextKey = textKey
                lastReadEnd = -1        // 重新载入后整篇颜色要重刷一遍

                let ps = NSMutableParagraphStyle()
                ps.lineSpacing = parent.fontSize * parent.lineGap
                ps.lineBreakMode = .byWordWrapping

                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: parent.fontSize, weight: .semibold),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: ps
                ]
                let s = NSMutableAttributedString(string: parent.prepared.text, attributes: attrs)
                let off = tv.contentOffset
                tv.attributedText = s
                tv.contentOffset = off
            }

            let total = (tv.text as NSString).length
            let end = max(0, min(parent.readEnd, total))
            guard end != lastReadEnd else { return }
            let prev = lastReadEnd
            lastReadEnd = end

            // v1.21：只改「变化的那一段」。
            // 以前每认出一个字，就把整篇 n 个字全部重新上色两遍（白一遍、压暗一遍）。
            // 一分钟的台本三四百字，跟读时一秒更新好几次，等于每秒给 textStorage
            // 打几千次属性补丁 —— 布局管理器跟着失效，滚动就掉帧。
            // 绝大多数时候光标只往前挪两三个字，增量刷这点就够了。
            tv.textStorage.beginEditing()
            if prev < 0 || end < prev {
                // 重排 / 回退 / 双击跳转：整篇刷白，再把已读段压暗
                tv.textStorage.addAttribute(.foregroundColor,
                                            value: UIColor.white,
                                            range: NSRange(location: 0, length: total))
                if end > 0 {
                    tv.textStorage.addAttribute(.foregroundColor,
                                                value: UIColor.white.withAlphaComponent(0.28),
                                                range: NSRange(location: 0, length: end))
                }
            } else if end > prev {
                tv.textStorage.addAttribute(.foregroundColor,
                                            value: UIColor.white.withAlphaComponent(0.28),
                                            range: NSRange(location: prev, length: end - prev))
            }
            tv.textStorage.endEditing()
        }
    }
}

// MARK: - 拍摄页

/// 滚动目标缓存。
///
/// 算一次目标位置要 `ensureLayout` 整篇、再查一次行片段；跟读时它一秒被叫 30 次，
/// 而光标一秒只往前挪几次 —— 两次识别之间目标根本没变，等于白排了二十几次版。
/// 缓存 key 只有三个：光标、框高、文本长度。命中就直接返回上次的值。
private final class ScrollTargetCache {
    private var valid = false
    private var cursor = -1
    private var boxHeight: CGFloat = -1
    private var textLength = -1
    private var cached: CGFloat = 0

    func hit(cursor c: Int, height: CGFloat, textLength len: Int) -> CGFloat? {
        guard valid, cursor == c, textLength == len, abs(boxHeight - height) < 0.5 else { return nil }
        return cached
    }

    func store(_ v: CGFloat, cursor c: Int, height: CGFloat, textLength len: Int) {
        valid = true
        cursor = c
        boxHeight = height
        textLength = len
        cached = v
    }

    func invalidate() { valid = false }
}

struct PrompterView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    let script: Script

    @StateObject private var cam = CameraRecorder()
    @StateObject private var speech = SpeechFollower()
    @StateObject private var engine = PrompterEngine()

    @AppStorage(Pref.fontSize) private var fontSize = 34.0
    @AppStorage(Pref.lineGap) private var lineGap = 0.42
    @AppStorage(Pref.speed) private var speed = 46.0
    @AppStorage(Pref.mirror) private var mirror = false
    @AppStorage(Pref.quality) private var qualityRaw = "uhd"
    @AppStorage(Pref.fps) private var fpsSetting = 60
    @AppStorage(Pref.countdown) private var countdown = 3
    @AppStorage(Pref.autoSave) private var autoSave = true
    @AppStorage(Pref.followOn) private var followOnStored = true
    @AppStorage(Pref.mirrorSave) private var mirrorSave = true

    @AppStorage(Pref.beautyOn) private var beautyOn = false
    @AppStorage(Pref.bSmooth) private var bSmooth = 0.36
    @AppStorage(Pref.bWhiten) private var bWhiten = 0.26
    @AppStorage(Pref.bRosy) private var bRosy = 0.14
    @AppStorage(Pref.bSlim) private var bSlim = 0.0
    @AppStorage(Pref.bEye) private var bEye = 0.0
    @AppStorage(Pref.bPreset) private var bPreset = 1

    // 提词框：布局用 State（拖动时高频变化），落地值用 AppStorage（拖动结束才写）
    @State private var boxLayout = BoxLayout.standard
    @AppStorage(Pref.boxX) private var savedX = 0.07
    @AppStorage(Pref.boxY) private var savedY = 0.15
    @AppStorage(Pref.boxW) private var savedW = 0.86
    @AppStorage(Pref.boxH) private var savedH = 0.295
    @AppStorage(Pref.boxBorder) private var boxBorder = true
    @AppStorage(Pref.boxFocus) private var boxFocus = true

    @State private var followOn = true
    @State private var autoScroll = false
    /// 双击定位的首次提示，只出现一次
    @State private var locateHintShown = false
    @State private var lastCursorForHint = 0
    @State private var cameraOn = true
    @State private var statusText = "准备中"
    @State private var tip: String?
    @State private var recSec = 0
    @State private var recStart = Date()
    @State private var textView: UITextView?
    @State private var ticker: Timer?
    @State private var countTimer: Timer?
    @State private var countdownLeft = 0
    @State private var showSettings = false
    @State private var showBeauty = false
    @State private var askQuit = false
    @State private var ignoreBeautyChange = false
    /// 滚动目标缓存（引用类型，改它不会触发 SwiftUI 重绘）
    @State private var scrollCache = ScrollTargetCache()

    var body: some View {
        GeometryReader { geo in
            let canvas = CGSize(width: geo.size.width, height: geo.size.height)

            ZStack {
                Color.black
                cameraLayer
                vignette

                PrompterBox(layout: $boxLayout,
                            canvas: canvas,
                            bordered: boxBorder,
                            focusLine: boxFocus,
                            onCommit: saveBox) { size in
                    ScriptTextView(prepared: engine.prepared,
                                   readEnd: engine.readEnd,
                                   fontSize: CGFloat(fontSize),
                                   lineGap: CGFloat(lineGap),
                                   mirror: mirror,
                                   boxHeight: size.height,
                                   onReady: { tv in textView = tv },
                                   onResize: { tv in
                                       textView = tv
                                       scrollTo(engine.cursor)
                                   },
                                   onLocate: { off in
                                       let i = engine.normIndex(forUTF16: off)
                                       engine.jump(to: i)
                                       Haptics.tap()
                                       showTip(followOn ? "从这句开始跟" : "位置已挪到这里")
                                   })
                }

                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    if let t = tip {
                        Toast(text: t)
                            .padding(.bottom, 12)
                    }
                    bottomPanel
                }
            }
            .overlay { countdownOverlay }
        }
        .statusBarHidden(true)
        .onAppear(perform: boot)
        .onDisappear(perform: bye)
        .onChange(of: engine.cursor) { c in
            // 不再在这里滚动：跟读的滚动由 30Hz 的 followTick 连续驱动。
            // 以前是「游标一变就发一次动画」，动画被改字/重排打断一次就永久停住。
            // 一次跳了几十个字：多半是被重复的话带偏了。这时候告诉用户「能自己指」，
            // 比让他顶着错位继续念、或者退出去重录强。
            if !locateHintShown && abs(c - lastCursorForHint) > 60 {
                locateHintShown = true
                showTip("位置跳远了？双击文字可以指定从哪句开始")
            }
            lastCursorForHint = c
        }
        .onChange(of: qualityRaw) { _ in applyQuality() }
        .onChange(of: fpsSetting) { _ in applyQuality() }
        .onChange(of: mirrorSave) { v in cam.setMirrorSave(v) }
        .onChange(of: beautyOn) { v in switchMode(v) }
        .onChange(of: bSmooth) { _ in pushBeauty() }
        .onChange(of: bWhiten) { _ in pushBeauty() }
        .onChange(of: bRosy) { _ in pushBeauty() }
        .onChange(of: bSlim) { _ in pushBeauty() }
        .onChange(of: bEye) { _ in pushBeauty() }
        .onChange(of: bPreset) { _ in pushBeauty() }
        // 字号/行距一变，整篇重新排版，缓存的滚动目标就作废
        .onChange(of: fontSize) { _ in scrollCache.invalidate() }
        .onChange(of: lineGap) { _ in scrollCache.invalidate() }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showBeauty) { BeautyPanel() }
        .confirmationDialog("正在录制，退出会丢掉这段视频",
                            isPresented: $askQuit,
                            titleVisibility: .visible) {
            Button("停止并退出", role: .destructive) {
                cam.stopRecording()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { dismiss() }
            }
            Button("继续拍", role: .cancel) {}
        }
    }

    // MARK: 画面

    @ViewBuilder
    private var cameraLayer: some View {
        if cameraOn {
            Group {
                if cam.mode == .beauty {
                    FilterPreview()
                } else {
                    CameraPreview(session: cam.session, mirrored: cam.isFront && mirrorSave)
                }
            }
            .ignoresSafeArea()
        }
    }

    private var vignette: some View {
        LinearGradient(colors: [Color.black.opacity(0.55),
                                Color.black.opacity(0.06),
                                Color.black.opacity(0.06),
                                Color.black.opacity(0.70)],
                       startPoint: .top,
                       endPoint: .bottom)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    // MARK: 顶部

    private var statusLine: String {
        if engine.prepared.isEmpty { return "台本是空的" }
        if followOn && speech.running {
            let s = speech.status
            // 异常提示（没收到麦克风 / 正在重开 / 换离线）优先显示，别让用户以为它还在工作
            if !s.isEmpty && s != "在线识别中" && s != "离线识别中" { return s }
            return (speech.onDevice ? "离线跟读 · " : "在线跟读 · ") + engine.upcoming
        }
        if autoScroll { return "匀速滚动中" }
        return statusText
    }

    /// 状态灯的语义：绿=正常跟读，蓝=匀速滚动，黄=有异常要处理，灰=待机
    private var statusDot: Color {
        if engine.prepared.isEmpty { return T.warn }
        if followOn && speech.running {
            let s = speech.status
            if !s.isEmpty && s != "在线识别中" && s != "离线识别中" { return T.warn }
            return T.ok
        }
        if autoScroll { return T.accent2 }
        return Color.white.opacity(0.35)
    }

    private var topBar: some View {
        VStack(spacing: 9) {
            HStack(spacing: 11) {
                Button {
                    tryClose()
                } label: {
                    RoundIconButton(icon: "xmark", size: 38, bg: Color.black.opacity(0.42))
                }
                .pressable()
                .accessibilityLabel("退出拍摄")

                VStack(alignment: .leading, spacing: 3) {
                    Text(script.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusDot)
                            .frame(width: 5, height: 5)
                        Text(statusLine)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.72))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                Text("\(engine.percent)%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.90))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.42))
                    .clipShape(Capsule())

                Button {
                    cam.switchCamera()
                } label: {
                    RoundIconButton(icon: "arrow.triangle.2.circlepath",
                                    size: 38,
                                    bg: Color.black.opacity(0.42))
                        .opacity(cam.recording ? 0.35 : 1)
                }
                .disabled(cam.recording)
                .pressable()
                .accessibilityLabel("切换前后镜头")
            }

            progressBar
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.58), Color.black.opacity(0.0)],
                           startPoint: .top,
                           endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    private var progressBar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                Capsule()
                    .fill(LinearGradient(colors: [Color.white.opacity(0.95), Color(hex: 0xB6AEFF)],
                                         startPoint: .leading,
                                         endPoint: .trailing))
                    .frame(width: max(5, g.size.width * CGFloat(engine.percent) / 100))
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 4)
    }

    // MARK: 底部

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                pill(cam.presetText, mono: true)

                if cam.recording {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(T.danger)
                            .frame(width: 7, height: 7)
                        Text(recSec.mmss)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.48))
                    .clipShape(Capsule())
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)

            toolBar

            HStack {
                Button {
                    showBeauty = true
                } label: {
                    RoundIconButton(icon: "sparkles",
                                    size: 46,
                                    bg: beautyOn ? T.accent : Color.black.opacity(0.44))
                }
                .pressable()
                .accessibilityLabel(beautyOn ? "美颜已开" : "打开美颜")

                Spacer()

                recordButton

                Spacer()

                Button {
                    showSettings = true
                } label: {
                    RoundIconButton(icon: "slider.horizontal.3",
                                    size: 46,
                                    bg: Color.black.opacity(0.44))
                }
                .pressable()
                .accessibilityLabel("提词设置")
            }
            .padding(.horizontal, 38)
            .padding(.top, 2)
        }
        .padding(.bottom, 20)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.0), Color.black.opacity(0.62)],
                           startPoint: .top,
                           endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    private var toolBar: some View {
        HStack(spacing: 2) {
            toolItem("waveform", "跟读", followOn) { toggleFollow() }
            toolItem("arrow.down.to.line", "匀速", autoScroll) { toggleAuto() }
            toolItem("arrow.left.arrow.right", "镜像", mirror) { mirror.toggle() }
            toolItem("rectangle.dashed", "提词框", false) { showSettings = true }
            toolItem("arrow.counterclockwise", "重来", false) { restart() }
        }
        .padding(4)
        .background(Color.black.opacity(0.44))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private func toolItem(_ icon: String,
                          _ label: String,
                          _ active: Bool,
                          _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(height: 18)
                Text(label)
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(active ? .white : Color.white.opacity(0.80))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(active ? T.accent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .pressable()
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func pill(_ text: String, mono: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 10,
                          weight: .semibold,
                          design: mono ? .monospaced : .default))
            .foregroundColor(.white.opacity(0.92))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.48))
            .clipShape(Capsule())
    }

    private var recordButton: some View {
        Button {
            tapRecord()
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    .frame(width: 90, height: 90)
                Circle()
                    .stroke(Color.white.opacity(0.92), lineWidth: 4)
                    .frame(width: 78, height: 78)
                RoundedRectangle(cornerRadius: cam.recording ? 9 : 32, style: .continuous)
                    .fill(T.danger)
                    .frame(width: cam.recording ? 32 : 64, height: cam.recording ? 32 : 64)
            }
            .animation(.easeInOut(duration: 0.18), value: cam.recording)
        }
        .pressable()
        .accessibilityLabel(cam.recording ? "停止录制" : "开始录制")
    }

    private var countdownOverlay: some View {
        ZStack {
            if countdownLeft > 0 {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                Text("\(countdownLeft)")
                    .font(.system(size: 136, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: Color.black.opacity(0.45), radius: 20)
                    .id(countdownLeft)
                    .transition(.scale(scale: 1.35).combined(with: .opacity))
            }
            // 长视频要重建音轨，直通也要几秒。不给点动静，用户会以为「录完什么都没发生」
            if cam.tidying {
                VStack {
                    Spacer()
                    VStack(spacing: 2) {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.75)
                            Text("正在整理音轨…")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                        }
                        Text("可以退出，好了会自动保存")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.72))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(.bottom, 168)
                }
                .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(countdownLeft > 0)
    }

    // MARK: - 设置面板

    private var settingsSheet: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(T.line)
                .frame(width: 38, height: 4)
                .padding(.top, 10)

            ScrollView {
                VStack(spacing: 18) {
                    boxSection

                    sheetSlider("字号", $fontSize, 20...60, 2, "\(Int(fontSize))")
                    sheetSlider("行距", $lineGap, 0.10...0.90, 0.04, String(format: "%.2f", lineGap))
                    sheetSlider("匀速速度", $speed, 12...100, 2, "\(Int(speed))")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("画质")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(T.sub)

                        Picker("", selection: $qualityRaw) {
                            ForEach(VideoQuality.allCases) { q in
                                Text(q.title).tag(q.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)

                        Picker("", selection: $fpsSetting) {
                            ForEach(FrameRate.allCases) { f in
                                Text(f.title).tag(f.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text("当前生效 \(cam.presetText) · \(cam.detailText)")
                            .font(.system(size: 11))
                            .foregroundColor(T.sub)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("画面")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(T.sub)

                        Toggle(isOn: $mirrorSave) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("前置镜像保存")
                                    .font(.system(size: 13))
                                    .foregroundColor(T.ink2)
                                Text("成片和取景框同方向。关掉会存真实方向，自拍左右会反过来")
                                    .font(.system(size: 11))
                                    .foregroundColor(T.sub)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .tint(T.accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(18)
                .padding(.bottom, 24)
            }
        }
        .background(T.bg.ignoresSafeArea())
        .presentationDetents([.height(560)])
    }

    private var boxSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("提词框")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(T.ink)
                Spacer()
                Text("可直接拖动")
                    .font(.system(size: 11))
                    .foregroundColor(T.sub)
            }

            HStack(spacing: 8) {
                ForEach(BoxPreset.allCases) { p in
                    Button {
                        applyPreset(p)
                    } label: {
                        Text(p.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(BoxPreset.nearest(boxLayout) == p ? .white : T.ink2)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(BoxPreset.nearest(boxLayout) == p ? T.accent : T.surface2)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .pressable()
                }
            }

            Toggle(isOn: $boxBorder) {
                Text("显示框体")
                    .font(.system(size: 13))
                    .foregroundColor(T.ink2)
            }
            .tint(T.accent)

            Toggle(isOn: $boxFocus) {
                Text("焦点线")
                    .font(.system(size: 13))
                    .foregroundColor(T.ink2)
            }
            .tint(T.accent)

            Text("拖框顶部的白色把手移动，拖右下角圆点改大小。读完一行，它就停在焦点线上。")
                .font(.system(size: 11))
                .foregroundColor(T.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(T.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(T.line, lineWidth: 1)
        )
    }

    private func sheetSlider(_ title: String,
                             _ value: Binding<Double>,
                             _ range: ClosedRange<Double>,
                             _ step: Double,
                             _ text: String) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(T.ink2)
                Spacer()
                Text(text)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(T.accent)
            }
            Slider(value: value, in: range, step: step)
                .tint(T.accent)
        }
    }

    // MARK: - 提词框

    private func saveBox(_ l: BoxLayout) {
        savedX = Double(l.x)
        savedY = Double(l.y)
        savedW = Double(l.w)
        savedH = Double(l.h)
    }

    private func applyPreset(_ p: BoxPreset) {
        Haptics.tap()
        withAnimation(.easeOut(duration: 0.24)) {
            boxLayout = p.layout
        }
        saveBox(p.layout)
    }

    // MARK: - 生命周期

    private func boot() {
        boxLayout = BoxLayout(x: CGFloat(savedX),
                              y: CGFloat(savedY),
                              w: CGFloat(savedW),
                              h: CGFloat(savedH)).clamped()
        engine.reset(script.content)
        followOn = followOnStored
        autoScroll = !followOn
        startTicker()
        pushBeauty()
        UIApplication.shared.isIdleTimerDisabled = true
        if cameraOn { openCamera() }
        if followOn && !engine.prepared.isEmpty {
            startFollow()
        }
    }

    private func bye() {
        ticker?.invalidate()
        ticker = nil
        countTimer?.invalidate()
        countTimer = nil
        speech.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        saveBox(boxLayout)
        if cam.recording {
            // 先收尾再关会话，否则文件可能没写完
            cam.stopRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                cam.stop()
            }
        } else {
            cam.stop()
        }
    }

    private func openCamera() {
        CameraRecorder.ensurePermissions { ok in
            guard ok else {
                cameraOn = false
                followOn = false
                autoScroll = true
                showTip("相机或麦克风权限被拒，现在只能纯提词")
                return
            }
            let q = VideoQuality(rawValue: qualityRaw) ?? .uhd
            cam.onAudio = { buf in speech.feed(buf) }
            cam.onFinish = { url in handleFinish(url) }
            cam.setMirrorSave(mirrorSave)
            cam.start(front: true,
                      quality: q,
                      fps: fpsSetting,
                      mode: beautyOn ? .beauty : .native)
        }
    }

    private func handleFinish(_ url: URL?) {
        if let url = url {
            store.refreshWorks()
            ThumbStore.shared.load(url)
            Haptics.success()
            if autoSave {
                PhotoSaver.save(url) { _, _ in }
            }
            showTip(cam.recordingError.isEmpty ? "已保存 " + url.lastPathComponent : cam.recordingError)
        } else {
            showTip(cam.recordingError.isEmpty ? "录制失败，再试一次" : cam.recordingError)
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            if autoScroll, let tv = textView {
                let maxY = max(0, tv.contentSize.height + tv.contentInset.bottom - tv.bounds.height)
                var y = tv.contentOffset.y + CGFloat(speed) / 30.0
                if y > maxY { y = maxY }
                tv.contentOffset = CGPoint(x: 0, y: y)
            }
            // 跟读：滚动由帧驱动，不再靠「游标一变发一次动画」——
            // 那条路只要动画被打断一次（改字、拖框、系统重排），页面就永久停在原地。
            if followOn, !autoScroll, let tv = textView {
                followTick(tv)
            }
            if cam.recording {
                recSec = Int(Date().timeIntervalSince(recStart))
            }
        }
    }

    // MARK: - 跟读

    private func toggleFollow() {
        if followOn {
            followOn = false
            speech.stop()
            statusText = "跟读已关"
            Haptics.tap()
        } else {
            followOn = true
            autoScroll = false
            startFollow()
        }
    }

    private func toggleAuto() {
        Haptics.tap()
        autoScroll.toggle()
        if autoScroll && followOn {
            followOn = false
            speech.stop()
        }
    }

    private func startFollow() {
        SpeechFollower.requestAuth { ok, msg in
            guard ok else {
                followOn = false
                autoScroll = true
                showTip(msg + "，已改成匀速滚动")
                return
            }
            speech.onText = { text in engine.feed(text) }
            speech.onFail = { m in statusText = m }
            // 把接下来要念的原句当识别提示词，同音字/人名会准很多
            speech.hints = {
                let p = engine.prepared
                if p.isEmpty { return [] }
                return p.nearbySentences(cursor: engine.cursor)
            }
            speech.start()
        }
    }

    // MARK: - 滚动

    /// 光标所在行应该落到框里的哪个 contentOffset。滚动、跳转、改框大小都从这里取目标。
    ///
    /// v6 这里是「框跳了、页面不翻」的真凶：原来用
    /// `boundingRect(forGlyphRange: 长度为 0 的范围)` 量位置，零长度范围的返回值不可靠
    /// （常见是零矩形 / 空矩形）。返回 y=0 时目标算成 `-contentInset.top`，正好等于起点，
    /// 于是 offset 永远被钉在开头 —— 高亮是另一条线，照常往下走，看起来就是「框到下一行、
    /// 页面不翻」。现在直接取所在行的 `lineFragmentRect`，跟长度无关，不会退化成 0。
    private func targetOffset(for c: Int, in tv: UITextView) -> CGFloat {
        let p = engine.prepared
        let n = p.offsets.count
        let minY = -tv.contentInset.top
        guard n > 0 else { return minY }

        let len = (tv.text as NSString).length
        guard len > 0 else { return minY }

        // 同一个光标 + 同样的框高/文本，答案一定一样，不用再排一遍版
        if let hit = scrollCache.hit(cursor: c, height: tv.bounds.height, textLength: len) {
            return hit
        }

        let off = c >= n ? p.text.utf16.count : p.offsets[max(0, c)]
        let loc = min(max(0, off), len - 1)      // 行位置按「最后一个字」取

        let lm = tv.layoutManager
        // 不先排版，还没排到的段落会量出零高度 —— 目标就算成「回到顶部」
        lm.ensureLayout(for: tv.textContainer)
        let gi = lm.glyphIndexForCharacter(at: loc)
        let frag = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
        let focusY = tv.bounds.height * ScriptTextView.focus
        let tar = frag.origin.y + tv.textContainerInset.top - focusY

        let used = lm.usedRect(for: tv.textContainer).height
        let contentH = used + tv.textContainerInset.top + tv.textContainerInset.bottom
        let maxY = max(minY, contentH + tv.contentInset.bottom - tv.bounds.height)
        let result = min(max(tar, minY), maxY)
        scrollCache.store(result, cursor: c, height: tv.bounds.height, textLength: len)
        return result
    }

    /// 一拍跟随：每帧朝目标缓动。
    /// 跟读的滚动原来是「游标一变就发一次动画」，动画被打断就永远停在原地；
    /// 现在改成由帧驱动，任何一次被外部重置的 offset，下一帧都会被拉回来。
    private func followTick(_ tv: UITextView) {
        // 手指正按着拖字，不抢
        guard !tv.isTracking, !tv.isDragging, !tv.isDecelerating else { return }
        let y = targetOffset(for: engine.cursor, in: tv)
        let dy = y - tv.contentOffset.y
        if abs(dy) < 0.5 { return }
        tv.contentOffset = CGPoint(x: 0, y: tv.contentOffset.y + dy * 0.30)
    }

    /// 立刻把画面挪到某一行。只给「离散跳转」用（双击定位、拖动提词框）；
    /// 跟读过程中不要调它，滚动一律交给 followTick —— 两套东西同时写 contentOffset
    /// 会互相打断，正是原来「框跳了、页面停住」的现场。
    private func scrollTo(_ c: Int) {
        guard let tv = textView, !autoScroll else { return }
        tv.contentOffset = CGPoint(x: 0, y: targetOffset(for: c, in: tv))
    }

    private func restart() {
        Haptics.tap()
        engine.reset(script.content)
        scrollCache.invalidate()
        if let tv = textView {
            UIView.animate(withDuration: 0.3) {
                tv.contentOffset = CGPoint(x: 0, y: -tv.contentInset.top)
            }
        }
        showTip("已回到开头")
    }

    // MARK: - 录制

    private func tapRecord() {
        if cam.recording {
            cam.stopRecording()
            return
        }
        // 上一条还在重建音轨就开新录，会把备份文件和会话搅在一起
        if cam.tidying {
            showTip("上一条还在整理音轨，稍等一下")
            return
        }
        guard cam.ready else {
            showTip("镜头还没准备好，等一秒再点")
            return
        }
        Haptics.tap()
        if countdown > 0 {
            startCountdown(countdown)
        } else {
            beginRecord()
        }
    }

    private func startCountdown(_ n: Int) {
        withAnimation(.easeOut(duration: 0.22)) { countdownLeft = n }
        countTimer?.invalidate()
        countTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if countdownLeft > 1 {
                withAnimation(.easeOut(duration: 0.22)) { countdownLeft -= 1 }
                Haptics.tap()
            } else {
                timer.invalidate()
                countdownLeft = 0
                beginRecord()
            }
        }
    }

    private func beginRecord() {
        recStart = Date()
        recSec = 0
        cam.startRecording(to: store.newWorkURL())
        if followOn && !speech.running {
            startFollow()
        }
    }

    private func applyQuality() {
        guard !cam.recording else { return }
        let q = VideoQuality(rawValue: qualityRaw) ?? .uhd
        cam.updateFormat(quality: q, fps: fpsSetting)
    }

    // MARK: - 美颜

    private func pushBeauty() {
        BeautyPipeline.shared.params = BeautyParams(smooth: bSmooth,
                                                    whiten: bWhiten,
                                                    rosy: bRosy,
                                                    slim: bSlim,
                                                    eye: bEye,
                                                    preset: BeautyFilterPreset(rawValue: bPreset) ?? .natural)
    }

    private func switchMode(_ on: Bool) {
        if ignoreBeautyChange {
            ignoreBeautyChange = false
            return
        }
        guard !cam.recording else {
            ignoreBeautyChange = true
            beautyOn = !on
            showTip("录制中不能切模式，停了再切")
            return
        }
        Haptics.tap()
        cam.setMode(on ? .beauty : .native)
        pushBeauty()
    }

    private func tryClose() {
        if cam.recording {
            askQuit = true
        } else {
            dismiss()
        }
    }

    private func showTip(_ t: String) {
        tip = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if tip == t { tip = nil }
        }
    }
}

// MARK: - 触感

enum Haptics {
    // 每次点击新建一个生成器，第一次震动会有几十毫秒延迟（要现去唤醒 Taptic Engine）。
    // 这里复用两个长生命周期的实例，点哪都跟手。
    private static let impact = UIImpactFeedbackGenerator(style: .light)
    private static let notify = UINotificationFeedbackGenerator()

    static func tap() {
        impact.prepare()
        impact.impactOccurred()
    }

    static func success() {
        notify.prepare()
        notify.notificationOccurred(.success)
    }
}

// MARK: - 美颜面板

struct BeautyPanel: View {
    @AppStorage(Pref.beautyOn) private var on = false
    @AppStorage(Pref.bSmooth) private var smooth = 0.36
    @AppStorage(Pref.bWhiten) private var whiten = 0.26
    @AppStorage(Pref.bRosy) private var rosy = 0.14
    @AppStorage(Pref.bSlim) private var slim = 0.0
    @AppStorage(Pref.bEye) private var eye = 0.0
    @AppStorage(Pref.bPreset) private var preset = 1

    var body: some View {
        VStack(spacing: 12) {
            Capsule()
                .fill(T.line)
                .frame(width: 38, height: 4)
                .padding(.top, 10)

            Picker("", selection: $on) {
                Text("原相机").tag(false)
                Text("经典美颜").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 18)

            filterStrip

            VStack(spacing: 10) {
                HStack {
                    Text("皮肤")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(T.sub)
                    Spacer()
                    Text("锁定面部")
                        .font(.system(size: 10))
                        .foregroundColor(T.accent)
                }

                bar("磨皮", $smooth)
                bar("美白", $whiten)
                bar("红润", $rosy)

                HStack {
                    Text("轮廓")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(T.sub)
                    Spacer()
                    Text("跟随人脸")
                        .font(.system(size: 10))
                        .foregroundColor(T.accent)
                }
                .padding(.top, 6)

                bar("瘦脸", $slim)
                bar("大眼", $eye)
            }
            .padding(.horizontal, 18)
            .opacity(on ? 1 : 0.4)
            .disabled(!on)

            Text(noteText)
                .font(.system(size: 10))
                .foregroundColor(T.sub)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 22)
                .padding(.bottom, 6)
        }
        .background(T.bg.ignoresSafeArea())
        .presentationDetents([.height(560)])
    }

    private var noteText: String {
        if !on { return "美颜关着，拍的是原相机画面，可用 4K" }
        return "磨皮、美白、红润只作用在脸上，头发、衣服、背景不受影响。瘦脸沿真实脸颊轮廓收，大眼锁住瞳孔位置，歪头、靠近、退远都跟得住。镜头里没有人脸时会退回整幅处理。美颜最高 1080P，要 4K 请切回原相机。"
    }

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(BeautyFilterPreset.allCases) { p in
                    Button {
                        preset = p.rawValue
                        Haptics.tap()
                    } label: {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(Color(uiColor: p.swatch))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Circle()
                                        .stroke(preset == p.rawValue ? T.accent : Color.clear, lineWidth: 2.5)
                                        .padding(-3)
                                )
                            Text(p.title)
                                .font(.system(size: 10, weight: preset == p.rawValue ? .semibold : .regular))
                                .foregroundColor(preset == p.rawValue ? T.ink : T.sub)
                        }
                    }
                    .pressable()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 2)
        }
        .opacity(on ? 1 : 0.4)
        .disabled(!on)
    }

    private func bar(_ title: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(T.ink2)
                .frame(width: 30, alignment: .leading)
            Slider(value: value, in: 0...1)
                .tint(T.accent)
            Text("\(Int(value.wrappedValue * 100))")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(T.accent)
                .frame(width: 26, alignment: .trailing)
        }
    }
}
