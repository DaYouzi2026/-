import SwiftUI
import AVFoundation
import UIKit

enum ScriptMetrics {
    static func topInset(_ h: CGFloat) -> CGFloat { h * 0.26 }
    static func bottomInset(_ h: CGFloat) -> CGFloat { h * 0.48 }
}

// MARK: - 提词文字层

struct ScriptTextView: UIViewRepresentable {
    let prepared: PreparedScript
    let readEnd: Int
    let fontSize: CGFloat
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
        tv.textContainerInset = UIEdgeInsets(top: 0, left: 22, bottom: 0, right: 22)
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
            let key = "\(parent.prepared.text.count)|\(parent.readEnd)|\(Int(parent.fontSize))"
            guard key != lastKey else { return }
            lastKey = key

            let ps = NSMutableParagraphStyle()
            ps.lineSpacing = parent.fontSize * 0.42
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
                               value: UIColor.white.withAlphaComponent(0.26),
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

    @State private var cameraOn = true
    @State private var followOn = true
    @State private var autoScroll = false
    @State private var mirror = false
    @State private var fontSize: CGFloat = 34
    @State private var speed: CGFloat = 42
    @State private var statusText = "准备中"
    @State private var tip: String?
    @State private var recSec = 0
    @State private var savedName: String?
    @State private var textView: UITextView?
    @State private var ticker: Timer?
    @State private var recStart = Date()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if cameraOn {
                    CameraPreview(session: cam.session)
                        .ignoresSafeArea()
                    Color.black.opacity(0.26)
                }

                ScriptTextView(prepared: engine.prepared,
                               readEnd: engine.readEnd,
                               fontSize: fontSize,
                               mirror: mirror,
                               viewHeight: geo.size.height,
                               onReady: { tv in textView = tv })
                    .padding(.top, 44)
                    .padding(.bottom, 110)

                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    if let t = tip { banner(t) }
                    if let n = savedName { banner("已保存到作品：" + n) }
                    bottomBar
                }

                if cam.recording {
                    VStack {
                        Spacer()
                        Rectangle()
                            .fill(T.danger)
                            .frame(height: 3)
                            .opacity(0.9)
                    }
                    .ignoresSafeArea()
                }
            }
        }
        .statusBarHidden(true)
        .onAppear(perform: boot)
        .onDisappear(perform: bye)
        .onChange(of: engine.cursor) { c in
            scrollTo(c)
        }
    }

    // MARK: 顶部 / 底部

    private var statusLine: String {
        if engine.prepared.isEmpty { return "台本是空的" }
        let p = "\(engine.percent)%"
        if followOn {
            return p + "  " + engine.upcoming
        }
        return p + "  " + statusText
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(T.overlay)
                    .clipShape(Circle())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(script.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(statusLine)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
            }

            Spacer()

            if cam.recording {
                HStack(spacing: 5) {
                    Circle().fill(T.danger).frame(width: 7, height: 7)
                    Text(recSec.mmss)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(T.overlay)
                .clipShape(Capsule())
            }

            Button {
                cam.switchCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(T.overlay)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private func banner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.72))
            .clipShape(Capsule())
            .padding(.bottom, 10)
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                pill(followOn ? "跟读 开" : "跟读 关", active: followOn) { toggleFollow() }
                pill(autoScroll ? "匀速 开" : "匀速 关", active: autoScroll) { autoScroll.toggle() }
                pill(mirror ? "镜像 开" : "镜像 关", active: mirror) { mirror.toggle() }
                pill("A-", active: false) { fontSize = max(20, fontSize - 2) }
                pill("A+", active: false) { fontSize = min(64, fontSize + 2) }
            }

            HStack {
                Spacer()
                Button {
                    toggleRecord()
                } label: {
                    recordButton
                }
                Spacer()
            }
        }
        .padding(.bottom, 24)
    }

    private var recordButton: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 4)
                .frame(width: 76, height: 76)
            RoundedRectangle(cornerRadius: cam.recording ? 8 : 31, style: .continuous)
                .fill(T.danger)
                .frame(width: cam.recording ? 30 : 62, height: cam.recording ? 30 : 62)
        }
        .animation(.easeInOut(duration: 0.18), value: cam.recording)
    }

    private func pill(_ text: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(active ? .white : .white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(active ? T.accent.opacity(0.9) : Color.black.opacity(0.45))
                .clipShape(Capsule())
        }
    }

    // MARK: - 生命周期

    private func boot() {
        engine.reset(script.content)
        startTicker()
        if cameraOn {
            openCamera()
        }
        if followOn && !engine.prepared.isEmpty {
            startFollow()
        }
    }

    private func bye() {
        ticker?.invalidate()
        ticker = nil
        speech.stop()
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
                tip = "相机或麦克风权限被拒，现在只能纯提词"
                return
            }
            cam.onAudio = { buf in speech.feed(buf) }
            cam.onFinish = { url in handleFinish(url) }
            cam.start(front: true)
        }
    }

    private func handleFinish(_ url: URL?) {
        if let url = url {
            store.refreshWorks()
            savedName = url.lastPathComponent
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                savedName = nil
            }
        } else {
            tip = cam.recordingError.isEmpty ? "录制失败，再试一次" : cam.recordingError
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            if autoScroll, let tv = textView {
                let maxY = max(0, tv.contentSize.height + tv.contentInset.bottom - tv.bounds.height)
                var y = tv.contentOffset.y + speed / 30.0
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
        } else {
            followOn = true
            startFollow()
        }
    }

    private func startFollow() {
        SpeechFollower.requestAuth { ok, msg in
            guard ok else {
                followOn = false
                autoScroll = true
                tip = msg + "，已改成匀速滚动"
                return
            }
            speech.onText = { text in
                engine.feed(text)
            }
            speech.onFail = { m in
                statusText = m
            }
            speech.start()
        }
    }

    // MARK: - 滚动

    private func scrollTo(_ c: Int) {
        guard let tv = textView else { return }
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
        let tar = rect.origin.y + tv.textContainerInset.top - tv.bounds.height * 0.26
        let maxY = max(0, tv.contentSize.height + tv.contentInset.bottom - tv.bounds.height)
        let y = min(max(tar, -tv.contentInset.top), maxY)
        UIView.animate(withDuration: 0.4,
                       delay: 0,
                       options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
            tv.contentOffset = CGPoint(x: 0, y: y)
        }
    }

    // MARK: - 录制

    private func toggleRecord() {
        if cam.recording {
            cam.stopRecording()
            return
        }
        guard cam.ready else {
            tip = "镜头还没准备好，等一秒再点"
            return
        }
        recStart = Date()
        recSec = 0
        cam.startRecording(to: store.newWorkURL())
        if followOn && !speech.running {
            startFollow()
        }
    }
}
