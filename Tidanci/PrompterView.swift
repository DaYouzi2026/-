import SwiftUI
import AVFoundation
import UIKit

enum ScriptMetrics {
    /// 视线焦点落在屏幕高度的这个位置
    static let focusY: CGFloat = 0.26

    static func topInset(_ h: CGFloat) -> CGFloat { max(120, h * focusY) }
    static func bottomInset(_ h: CGFloat) -> CGFloat { max(180, h * 0.46) }
}

// MARK: - 提词文字层

struct ScriptTextView: UIViewRepresentable {
    let prepared: PreparedScript
    let readEnd: Int
    let fontSize: CGFloat
    let lineGap: CGFloat
    let mirror: Bool
    let viewHeight: CGFloat
    let onReady: (UITextView) -> Void

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.backgroundColor = .clear
        tv.isEditable = false
        tv.isSelectable = false
        tv.showsVerticalScrollIndicator = false
        tv.alwaysBounceVertical = true
        tv.textContainerInset = UIEdgeInsets(top: 0, left: 24, bottom: 0, right: 24)
        let top = ScriptMetrics.topInset(viewHeight)
        tv.contentInset = UIEdgeInsets(top: top,
                                       left: 0,
                                       bottom: ScriptMetrics.bottomInset(viewHeight),
                                       right: 0)
        tv.contentOffset = CGPoint(x: 0, y: -top)
        // 别在视图更新过程中改 State，延到下一个 runloop
        DispatchQueue.main.async { onReady(tv) }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(tv)
        tv.transform = mirror ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator {
        var parent: ScriptTextView
        private var lastKey = ""

        init(_ p: ScriptTextView) { parent = p }

        func apply(_ tv: UITextView) {
            let key = "\(parent.prepared.text.count)|\(parent.readEnd)|\(Int(parent.fontSize))|\(Int(parent.lineGap * 100))"
            guard key != lastKey else { return }
            lastKey = key

            let ps = NSMutableParagraphStyle()
            ps.lineSpacing = parent.fontSize * parent.lineGap
            ps.lineBreakMode = .byWordWrapping

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: parent.fontSize, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: ps
            ]
            let s = NSMutableAttributedString(string: parent.prepared.text, attributes: attrs)
            let total = parent.prepared.text.utf16.count
            let end = max(0, min(parent.readEnd, total))
            if end > 0 {
                s.addAttribute(.foregroundColor,
                               value: UIColor.white.withAlphaComponent(0.24),
                               range: NSRange(location: 0, length: end))
            }
            let off = tv.contentOffset
            tv.attributedText = s
            tv.contentOffset = off
        }
    }
}

// MARK: - 拍摄页

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

    @State private var followOn = true
    @State private var autoScroll = false
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
    @State private var askQuit = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if cameraOn {
                    CameraPreview(session: cam.session)
                        .ignoresSafeArea()
                    LinearGradient(colors: [Color.black.opacity(0.60),
                                            Color.black.opacity(0.10),
                                            Color.black.opacity(0.10),
                                            Color.black.opacity(0.72)],
                                   startPoint: .top,
                                   endPoint: .bottom)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                ScriptTextView(prepared: engine.prepared,
                               readEnd: engine.readEnd,
                               fontSize: CGFloat(fontSize),
                               lineGap: CGFloat(lineGap),
                               mirror: mirror,
                               viewHeight: geo.size.height,
                               onReady: { tv in textView = tv })

                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    if let t = tip {
                        Toast(text: t)
                            .padding(.bottom, 10)
                    }
                    bottomPanel
                }
            }
            .overlay {
                countdownOverlay
            }
        }
        .statusBarHidden(true)
        .onAppear(perform: boot)
        .onDisappear(perform: bye)
        .onChange(of: engine.cursor) { c in scrollTo(c) }
        .onChange(of: qualityRaw) { _ in applyQuality() }
        .onChange(of: fpsSetting) { _ in applyQuality() }
        .sheet(isPresented: $showSettings) { settingsSheet }
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

    // MARK: 顶部

    private var statusLine: String {
        if engine.prepared.isEmpty { return "台本是空的" }
        if followOn && speech.running {
            return "\(speech.onDevice ? "离线跟读" : "跟读") · " + engine.upcoming
        }
        if autoScroll { return "匀速滚动中" }
        return statusText
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                tryClose()
            } label: {
                RoundIconButton(icon: "xmark")
            }
            .pressable()

            VStack(alignment: .leading, spacing: 2) {
                Text(script.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.70))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text("\(engine.percent)%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.45))
                .clipShape(Capsule())

            Button {
                cam.switchCamera()
            } label: {
                RoundIconButton(icon: "arrow.triangle.2.circlepath")
                    .opacity(cam.recording ? 0.4 : 1)
            }
            .disabled(cam.recording)
            .pressable()
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    // MARK: 底部

    private var bottomPanel: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Text(cam.presetText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.92))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.16))
                    .clipShape(Capsule())

                if cam.recording {
                    HStack(spacing: 5) {
                        Circle().fill(T.danger).frame(width: 7, height: 7)
                        Text(recSec.mmss)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Capsule())
                }

                Spacer()
            }
            .padding(.horizontal, 20)

            HStack(spacing: 7) {
                chipButton("跟读", followOn) { toggleFollow() }
                chipButton("匀速", autoScroll) { toggleAuto() }
                chipButton(mirror ? "镜像开" : "镜像", mirror) { mirror.toggle() }
                chipButton("A-") { fontSize = max(20, fontSize - 2) }
                chipButton("A+") { fontSize = min(64, fontSize + 2) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)

            HStack {
                Button {
                    showSettings = true
                } label: {
                    RoundIconButton(icon: "slider.horizontal.3", size: 44)
                }
                .pressable()

                Spacer()

                recordButton

                Spacer()

                Button {
                    restart()
                } label: {
                    RoundIconButton(icon: "arrow.counterclockwise", size: 44)
                }
                .pressable()
            }
            .padding(.horizontal, 34)
        }
        .padding(.bottom, 22)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.0), Color.black.opacity(0.55)],
                           startPoint: .top,
                           endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
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
    }

    private func chipButton(_ text: String, _ active: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Chip(text: text, active: active)
        }
        .pressable()
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
                }
                .padding(18)
            }
        }
        .background(T.bg.ignoresSafeArea())
        .presentationDetents([.height(430)])
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

    // MARK: - 生命周期

    private func boot() {
        engine.reset(script.content)
        followOn = followOnStored
        autoScroll = !followOn
        startTicker()
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
            cam.start(front: true, quality: q, fps: fpsSetting)
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
            showTip("已保存 " + url.lastPathComponent)
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
            speech.start()
        }
    }

    // MARK: - 滚动

    private func scrollTo(_ c: Int) {
        guard let tv = textView, !autoScroll else { return }
        let p = engine.prepared
        let n = p.offsets.count
        guard n > 0 else { return }
        let off = c >= n ? p.text.utf16.count : p.offsets[max(0, c)]
        let len = (tv.text as NSString).length
        let loc = min(off, len)
        let lm = tv.layoutManager
        let gr = lm.glyphRange(forCharacterRange: NSRange(location: loc, length: 0),
                               actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: gr, in: tv.textContainer)
        let tar = rect.origin.y + tv.textContainerInset.top - tv.bounds.height * ScriptMetrics.focusY
        let maxY = max(0, tv.contentSize.height + tv.contentInset.bottom - tv.bounds.height)
        let y = min(max(tar, -tv.contentInset.top), maxY)
        UIView.animate(withDuration: 0.4,
                       delay: 0,
                       options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
            tv.contentOffset = CGPoint(x: 0, y: y)
        }
    }

    private func restart() {
        Haptics.tap()
        engine.reset(script.content)
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
        countdownLeft = n
        countTimer?.invalidate()
        countTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if countdownLeft > 1 {
                countdownLeft -= 1
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
    static func tap() {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.prepare()
        g.impactOccurred()
    }

    static func success() {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.success)
    }
}
