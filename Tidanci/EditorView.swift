import SwiftUI
import AVKit

/// 作品页点「编辑」进来的后期页：降噪 + 自动字幕 + 掐气口，处理完直接存相册。
struct EditorView: View {
    @Environment(\.dismiss) private var dismiss

    let item: WorkItem

    @StateObject private var editor = VideoEditor()

    /// 字幕样式存在本机，下次进来还是上次那套
    @AppStorage("subtitle.style.v1") private var styleRaw = ""

    @State private var denoise = true
    @State private var subtitle = true
    @State private var cutSilence = true
    @State private var result: URL?
    @State private var note: String?
    @State private var player: AVPlayer?

    // 气口：先扫出来 → 弹窗让用户勾 → 再剪
    @State private var gaps: [SilenceGap] = []
    @State private var gapDuration: Double = 0
    @State private var scanning = false
    @State private var showGaps = false

    private var style: SubtitleStyle { SubtitleStyle.decode(styleRaw) }

    private func setStyle(_ s: SubtitleStyle) {
        styleRaw = s.clamped().encoded
    }

    /// 每处气口前后各留 0.12 秒，所以真正能省的是 length - 0.24
    private var saveable: Double {
        gaps.reduce(0.0) { $0 + max(0, $1.length - 0.24) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    preview

                    if result == nil {
                        options
                    } else {
                        doneCard
                    }

                    if editor.running {
                        progressCard
                    }

                    if let n = note {
                        Text(n)
                            .font(.system(size: 12))
                            .foregroundColor(T.sub)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }

                    actionButton
                }
                .padding(16)
                .padding(.bottom, 30)
            }
            .background(T.bg.ignoresSafeArea())
            .navigationTitle(result == nil ? "编辑" : "处理完成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        player?.pause()
                        dismiss()
                    }
                    .disabled(editor.running)
                }
            }
            .sheet(isPresented: $showGaps) {
                GapSheet(duration: gapDuration,
                         gaps: gaps,
                         onPreview: { g in
                             guard let p = player else { return }
                             p.seek(to: CMTime(seconds: max(0, g.start - 0.9),
                                               preferredTimescale: 600))
                             p.play()
                         },
                         onCancel: {
                             showGaps = false
                         },
                         onConfirm: { chosen in
                             showGaps = false
                             runEdit(cut: chosen)
                         })
                    .presentationDetents([.large])
            }
            .onAppear {
                if player == nil { player = AVPlayer(url: item.url) }
                if cutSilence && gapDuration == 0 { scanGapsOnly() }
            }
            .onChange(of: cutSilence) { on in
                if on && gapDuration == 0 && !scanning { scanGapsOnly() }
            }
        }
    }

    // MARK: - 预览

    private var preview: some View {
        Group {
            if let p = player {
                VideoPlayer(player: p)
            } else {
                Color.black
            }
        }
        .frame(height: 240)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 选项

    private var options: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                toggleRow(icon: "scissors",
                          title: "智能剪辑 · 掐气口",
                          sub: "自动认出换气、卡壳的停顿，处理后先列出来给你挑，再动手剪",
                          isOn: $cutSilence)

                if cutSilence {
                    gapRow
                }
            }

            toggleRow(icon: "waveform",
                      title: "AI 降噪",
                      sub: "切掉空调声、风声这类持续低频噪音，人声更突出",
                      isOn: $denoise)

            toggleRow(icon: "text.bubble",
                      title: "自动字幕",
                      sub: "识别口播内容，烧进画面。会本地、联网各识别一遍取效果好的，耗时最长，一般等于视频长度",
                      isOn: $subtitle)

            if subtitle {
                subtitleStyleCard
            }

            Text("原视频不会被改动，处理结果会另存一份到相册。")
                .font(.system(size: 11))
                .foregroundColor(T.sub)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }

    /// 气口扫描结果那一行：能看到找到几处、能省多久，也能点开重新挑
    private var gapRow: some View {
        HStack(spacing: 8) {
            if scanning {
                ProgressView().scaleEffect(0.7)
                Text("正在找气口…")
                    .font(.system(size: 11))
                    .foregroundColor(T.sub)
                Spacer()
            } else if gaps.isEmpty {
                Image(systemName: "waveform.slash")
                    .font(.system(size: 12))
                    .foregroundColor(T.sub)
                Text(gapDuration > 0 ? "没找到明显气口，节奏按原样保留" : "还没扫描")
                    .font(.system(size: 11))
                    .foregroundColor(T.sub)
                Spacer()
                if gapDuration == 0 {
                    Button("先扫一遍") { scanGapsOnly() }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(T.accent)
                }
            } else {
                Image(systemName: "list.number")
                    .font(.system(size: 12))
                    .foregroundColor(T.accent)
                Text("找到 \(gaps.count) 处，可省 \(Int(saveable.rounded())) 秒")
                    .font(.system(size: 11))
                    .foregroundColor(T.ink2)
                Spacer()
                Button("逐处挑选") { showGaps = true }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(T.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    // MARK: - 字幕样式

    private var subtitleStyleCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("字幕样式")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(T.ink)
                Spacer()
                Text("\(style.positionName) · \(String(format: "%.1f%%", style.sizeRatio * 100))")
                    .font(.system(size: 11))
                    .foregroundColor(T.sub)
            }

            // 字体
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SubtitleStyle.usable) { o in
                        let on = style.fontKey == o.id
                        Button {
                            var s = style
                            s.fontKey = o.id
                            setStyle(s)
                        } label: {
                            Text(o.title)
                                .font(Font(SubtitleStyle(fontKey: o.id,
                                                         sizeRatio: style.sizeRatio,
                                                         bottomRatio: style.bottomRatio)
                                            .uiFont(size: 15)))
                                .foregroundColor(on ? .white : T.ink2)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(on ? T.accent : T.surface2)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            // 字号
            HStack(spacing: 10) {
                Text("字号")
                    .font(.system(size: 12))
                    .foregroundColor(T.ink2)
                    .frame(width: 30, alignment: .leading)
                Text("小")
                    .font(.system(size: 10))
                    .foregroundColor(T.sub)
                Slider(value: Binding(
                    get: { style.sizeRatio },
                    set: { v in
                        var s = style
                        s.sizeRatio = v
                        setStyle(s)
                    }
                ), in: 0.028...0.10)
                .tint(T.accent)
                Text("大")
                    .font(.system(size: 10))
                    .foregroundColor(T.sub)
            }

            // 位置
            HStack(spacing: 10) {
                Text("位置")
                    .font(.system(size: 12))
                    .foregroundColor(T.ink2)
                    .frame(width: 30, alignment: .leading)
                Text("底")
                    .font(.system(size: 10))
                    .foregroundColor(T.sub)
                Slider(value: Binding(
                    get: { style.bottomRatio },
                    set: { v in
                        var s = style
                        s.bottomRatio = v
                        setStyle(s)
                    }
                ), in: 0.02...0.80)
                .tint(T.accent)
                Text("顶")
                    .font(.system(size: 10))
                    .foregroundColor(T.sub)
            }

            HStack(spacing: 8) {
                ForEach([0.07, 0.45, 0.74], id: \.self) { v in
                    let name = v < 0.2 ? "底部" : (v < 0.6 ? "居中" : "靠上")
                    Button {
                        var s = style
                        s.bottomRatio = v
                        setStyle(s)
                    } label: {
                        Text(name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(abs(style.bottomRatio - v) < 0.02 ? .white : T.ink2)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(abs(style.bottomRatio - v) < 0.02 ? T.accent : T.surface2)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            // 小样：按画面比例缩放预览，不用真导出一遍才知道效果
            SubtitleSample(style: style, text: "大家好，今天聊三件事")
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(T.line, lineWidth: 1)
                )
        }
        .padding(14)
        .background(T.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(T.line, lineWidth: 1)
        )
    }

    private func toggleRow(icon: String,
                           title: String,
                           sub: String,
                           isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(isOn.wrappedValue ? T.accent : T.sub)
                .frame(width: 26, height: 26)
                .background(isOn.wrappedValue ? T.accent.opacity(0.12) : T.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(T.ink)
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundColor(T.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(T.accent)
                .disabled(editor.running)
        }
        .padding(14)
        .background(T.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(T.line, lineWidth: 1)
        )
    }

    // MARK: - 进度

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(editor.stage.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(T.ink)
                Spacer()
                Text("\(Int(editor.progress * 100))%")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(T.accent)
            }

            ProgressView(value: editor.progress)
                .tint(T.accent)

            stepStrip

            HStack(alignment: .top, spacing: 8) {
                Text(editor.statusText)
                    .font(.system(size: 11))
                    .foregroundColor(T.sub)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                // 计数器一直在动，才看得出「在跑」而不是「卡死」
                Text("已用 \(VideoEditor.clock(editor.elapsed))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(T.sub.opacity(0.8))
            }
        }
        .padding(14)
        .background(T.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(T.line, lineWidth: 1)
        )
    }

    /// 这次实际要走的几步（跟着开关变），完成的打勾、当前的染成主题色
    private var steps: [(name: String, stage: EditStage)] {
        var out: [(name: String, stage: EditStage)] = []
        if denoise { out.append(("降噪", .denoise)) }
        if subtitle { out.append(("字幕", .transcribe)) }
        out.append(("合成", .render))
        return out
    }

    private var stepStrip: some View {
        HStack(spacing: 5) {
            ForEach(Array(steps.enumerated()), id: \.offset) { pair in
                let i = pair.offset
                let s = pair.element
                let done = editor.stage.rawValue > s.stage.rawValue
                let now = editor.stage == s.stage
                HStack(spacing: 4) {
                    Image(systemName: done ? "checkmark.circle.fill" : "\(i + 1).circle.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(s.name)
                        .font(.system(size: 11, weight: now ? .semibold : .regular))
                }
                .foregroundColor(done ? T.ok : (now ? T.accent : T.sub))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(now ? T.accent.opacity(0.12) : T.surface2)
                .clipShape(Capsule())

                if i < steps.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(T.sub.opacity(0.5))
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 完成

    private var doneCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(T.ok)
                Text("处理完成")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(T.ink)
                Spacer()
            }

            if subtitle {
                HStack(spacing: 6) {
                    Image(systemName: editor.cueCount > 0 ? "text.bubble.fill" : "text.bubble")
                        .font(.system(size: 12, weight: .semibold))
                    Text(subtitleSummary)
                        .font(.system(size: 12))
                }
                .foregroundColor(editor.cueCount > 0 && !editor.subtitleDropped ? T.ok : T.sub)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let r = result {
                HStack(spacing: 10) {
                    Button {
                        PhotoSaver.save(r) { ok, msg in
                            note = ok ? "已存入相册" : msg
                        }
                    } label: {
                        miniButton("再存一次", "square.and.arrow.down", T.accent)
                    }
                    .pressable()

                    ShareLink(item: r) {
                        miniButton("分享", "square.and.arrow.up", T.ink2)
                    }
                    .pressable()
                }
            }
        }
        .padding(14)
        .background(T.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(T.line, lineWidth: 1)
        )
    }

    /// 字幕到底成没成，直接写在完成卡片上 —— 别再让人对着片子猜「为什么一个字都没有」
    private var subtitleSummary: String {
        if editor.subtitleDropped { return "字幕：烧录失败，已交付无字幕成片（原因见诊断日志）" }
        if editor.cueCount > 0 { return "字幕：\(editor.cueCount) 条，已烧进画面" }
        return "字幕：一条也没识别出来（原因见下方提示）"
    }

    private func miniButton(_ title: String, _ icon: String, _ color: Color) -> some View {        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            Text(title).font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(color)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(T.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 主按钮

    private var actionButton: some View {
        Button {
            if result != nil {
                player?.pause()
                dismiss()
            } else {
                start()
            }
        } label: {
            HStack(spacing: 8) {
                if editor.running || scanning {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                }
                Text(buttonTitle)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(editor.running || scanning ? T.sub : T.accent)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(editor.running || scanning)
        .pressable()
    }

    private var buttonTitle: String {
        if result != nil { return "完成" }
        if editor.running { return "处理中…" }
        if scanning { return "找气口…" }
        return "开始处理"
    }

    // MARK: - 流程

    private func scanGapsOnly() {
        guard !scanning else { return }
        scanning = true
        editor.scanGaps(input: item.url) { g, d in
            scanning = false
            gaps = g
            gapDuration = d
        }
    }

    private func start() {
        guard !editor.running, !scanning else { return }
        result = nil
        note = nil
        player?.pause()

        guard cutSilence else {
            runEdit(cut: [])
            return
        }

        // 开着智能剪辑：先确保扫过，再把结果摆到用户面前挑
        if gapDuration <= 0 {
            scanning = true
            editor.scanGaps(input: item.url) { g, d in
                scanning = false
                gaps = g
                gapDuration = d
                showGaps = true
            }
            return
        }
        showGaps = true
    }

    private func runEdit(cut: [SilenceGap]) {
        result = nil
        note = nil
        player?.pause()

        editor.run(input: item.url,
                   denoise: denoise,
                   subtitle: subtitle,
                   style: style,
                   cutGaps: cutSilence ? cut : nil) { url, err in
            if let u = url {
                result = u
                player = AVPlayer(url: u)
                player?.play()
                PhotoSaver.save(u) { ok, msg in
                    if let e = err, !e.isEmpty {
                        note = "已存相册；\(e)"
                    } else {
                        note = ok ? "已自动存进相册" : msg
                    }
                }
            } else {
                note = err ?? "处理失败"
            }
        }
    }
}
