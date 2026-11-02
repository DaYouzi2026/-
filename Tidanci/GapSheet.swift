import SwiftUI

/// 气口确认面板：把检测到的每一处停顿列出来，让用户自己决定哪几处剪掉。
///
/// 默认全选（等于「智能剪辑」原来的行为），但改哪里、留哪里由用户说了算——
/// 之前是检测完直接剪，用户只能从成片里发现「这句被剪坏了」，代价太大。
struct GapSheet: View {
    let duration: Double
    let gaps: [SilenceGap]
    let onPreview: (SilenceGap) -> Void
    let onCancel: () -> Void
    let onConfirm: ([SilenceGap]) -> Void

    /// 每一处是否剪掉，顺序与 gaps 一致
    @State private var cut: [Bool]

    /// 每处前后各留 0.12 秒防咬字，所以真正能省下的是 length - 0.24
    private static let pad = 0.12

    init(duration: Double,
         gaps: [SilenceGap],
         onPreview: @escaping (SilenceGap) -> Void,
         onCancel: @escaping () -> Void,
         onConfirm: @escaping ([SilenceGap]) -> Void) {
        self.duration = duration
        self.gaps = gaps
        self.onPreview = onPreview
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _cut = State(initialValue: Array(repeating: true, count: gaps.count))
    }

    private func saved(_ g: SilenceGap) -> Double {
        max(0, g.length - Self.pad * 2)
    }

    private var savedTotal: Double {
        zip(gaps, cut).reduce(0.0) { acc, pair in
            pair.1 ? acc + saved(pair.0) : acc
        }
    }

    private var cutCount: Int {
        cut.filter { $0 }.count
    }

    private var finalTime: Double {
        max(0, duration - savedTotal)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header

                if gaps.isEmpty {
                    empty
                } else {
                    list
                }

                bottomBar
            }
            .background(T.bg.ignoresSafeArea())
            .navigationTitle("确认要剪的气口")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") { onCancel() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(cutCount == gaps.count ? "全部不剪" : "全部剪掉") {
                        let allCut = cutCount == gaps.count
                        cut = Array(repeating: !allCut, count: gaps.count)
                    }
                    .disabled(gaps.isEmpty)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("原片 \(duration.mmss)，找到 \(gaps.count) 处停顿")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(T.ink)
            Text(gaps.isEmpty
                 ? "没找到明显的换气停顿，这条可以直接输出。"
                 : "勾掉的那几处会被剪掉。按当前选择，成片约 \(finalTime.mmss)，省下 \(Int(savedTotal.rounded())) 秒。")
                .font(.system(size: 11))
                .foregroundColor(T.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(T.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 30))
                .foregroundColor(T.sub)
            Text("没有气口可剪")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(T.ink)
            Text("可能是这条本来就很紧凑，也可能环境底噪一直很高盖住了停顿。\n可以关掉「智能剪辑」再导出。")
                .font(.system(size: 11))
                .foregroundColor(T.sub)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(Array(gaps.enumerated()), id: \.offset) { idx, g in
                    row(idx, g)
                }
                Text("判定标准：连续 0.45 秒以上低于 -38dB。太吵的环境会把说话也判成静音，所以这里让你自己看一眼再决定。")
                    .font(.system(size: 10))
                    .foregroundColor(T.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func row(_ idx: Int, _ g: SilenceGap) -> some View {
        HStack(spacing: 10) {
            Text("\(idx + 1)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(cut[idx] ? T.accent : T.sub)
                .frame(width: 24, height: 24)
                .background(cut[idx] ? T.accent.opacity(0.12) : T.surface2)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("\(g.start.mmss) – \(g.end.mmss)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(T.ink)
                Text(String(format: "停顿 %.1f 秒 · 可省 %.1f 秒", g.length, saved(g)))
                    .font(.system(size: 10))
                    .foregroundColor(T.sub)
            }

            Spacer(minLength: 4)

            Button {
                onPreview(g)
            } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 20))
                    .foregroundColor(T.ink2)
            }
            .buttonStyle(.plain)

            Toggle("", isOn: $cut[idx])
                .labelsHidden()
                .tint(T.accent)
        }
        .padding(12)
        .background(T.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(T.line, lineWidth: 1)
        )
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Button {
                onConfirm([])
            } label: {
                Text("一处都不剪，直接输出")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(T.ink2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(T.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .pressable()

            Button {
                let chosen = zip(gaps, cut).filter { $0.1 }.map { $0.0 }
                onConfirm(chosen)
            } label: {
                Text(gaps.isEmpty ? "直接输出" : "按选择剪 · 约 \(finalTime.mmss)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(T.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .pressable()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(T.bg)
    }
}
