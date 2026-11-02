import SwiftUI
import AVKit

/// 作品页点「编辑」进来的后期页：降噪 + 自动字幕，处理完直接存相册。
struct EditorView: View {
    @Environment(\.dismiss) private var dismiss

    let item: WorkItem

    @StateObject private var editor = VideoEditor()
    @State private var denoise = true
    @State private var subtitle = true
    @State private var cutSilence = true
    @State private var result: URL?
    @State private var note: String?
    @State private var player: AVPlayer?

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
            toggleRow(icon: "scissors",
                      title: "智能剪辑 · 掐气口",
                      sub: "自动认出换气、卡壳的停顿并剪掉，成片更紧凑；残留一点呼吸声属于正常",
                      isOn: $cutSilence)

            toggleRow(icon: "waveform",
                      title: "AI 降噪",
                      sub: "切掉空调声、风声这类持续低频噪音，人声更突出",
                      isOn: $denoise)

            toggleRow(icon: "text.bubble",
                      title: "自动字幕",
                      sub: "识别口播内容，烧进画面底部。耗时最长，一般等于视频长度的一半",
                      isOn: $subtitle)

            Text("原视频不会被改动，处理结果会另存一份到相册。")
                .font(.system(size: 11))
                .foregroundColor(T.sub)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(T.accent)
            }

            ProgressView(value: editor.progress)
                .tint(T.accent)

            Text(editor.statusText)
                .font(.system(size: 11))
                .foregroundColor(T.sub)
        }
        .padding(14)
        .background(T.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(T.line, lineWidth: 1)
        )
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

    private func miniButton(_ title: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
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
                if editor.running {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                }
                Text(result != nil ? "完成" : (editor.running ? "处理中…" : "开始处理"))
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(editor.running ? T.sub : T.accent)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(editor.running)
        .pressable()
    }

    private func start() {
        guard !editor.running else { return }
        result = nil
        note = nil
        player?.pause()
        player = nil

        editor.run(input: item.url,
                   denoise: denoise,
                   subtitle: subtitle,
                   cutSilence: cutSilence) { url, err in
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
