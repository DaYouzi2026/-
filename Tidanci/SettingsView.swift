import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var store: Store

    @AppStorage(Pref.quality) private var qualityRaw = "uhd"
    @AppStorage(Pref.fps) private var fps = 60
    @AppStorage(Pref.fontSize) private var fontSize = 34.0
    @AppStorage(Pref.speed) private var speed = 46.0
    @AppStorage(Pref.countdown) private var countdown = 3
    @AppStorage(Pref.autoSave) private var autoSave = true
    @AppStorage(Pref.mirror) private var mirror = false
    @AppStorage(Pref.mirrorSave) private var mirrorSave = true
    @AppStorage(Pref.followOn) private var followOn = true
    @AppStorage(Pref.speechOnDevice) private var speechOnDevice = false

    @State private var toast: String?
    @State private var crashText: String?
    @State private var diagText: String?
    @State private var showDiag = false

    private var quality: VideoQuality { VideoQuality(rawValue: qualityRaw) ?? .uhd }
    private var frame: FrameRate { FrameRate(rawValue: fps) ?? .fps30 }

    /// 体积已经在扫目录时算好，这里只是加法，不再逐个 stat 文件
    private var usedSpace: String {
        let total = store.works.reduce(Int64(0)) { $0 + $1.size }
        let mb = Double(total) / 1048576.0
        return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? v : "\(v)（\(b)）"
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                T.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    header

                    ScrollView {
                        VStack(spacing: 18) {
                            qualityCard
                            promptCard
                            recordCard
                            aboutCard
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 48)
                    }
                }

                if let t = toast {
                    Toast(text: t).padding(.top, 6)
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                crashText = CrashLog.read()
                diagText = Diag.read()
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("我的")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.white)
                Text("设置只对这台手机生效")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.78))
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(usedSpace)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Text("\(store.works.count) 个作品")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.72))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .background(
            T.grad
                .ignoresSafeArea(edges: .top)
        )
    }

    // MARK: - 通用行

    private func iconTile(_ icon: String, _ tint: Color, size: CGFloat = 30) -> some View {
        RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
            .fill(tint.opacity(0.13))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: size * 0.47, weight: .semibold))
                    .foregroundColor(tint)
            )
    }

    /// 统一的行结构：左边一个彩色图标，右边交给调用方。
    /// 一堆纯文字行在设置页里很难扫，加图标之后「画质/提词/作品」三块一眼能分开。
    private func row<Content: View>(_ icon: String,
                                    _ tint: Color,
                                    _ title: String,
                                    sub: String? = nil,
                                    @ViewBuilder trailing: () -> Content) -> some View {
        HStack(spacing: 12) {
            iconTile(icon, tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundColor(T.ink2)
                if let s = sub {
                    Text(s)
                        .font(.system(size: 11))
                        .foregroundColor(T.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private func sliderBlock(_ icon: String,
                             _ tint: Color,
                             _ title: String,
                             _ value: Binding<Double>,
                             _ range: ClosedRange<Double>,
                             _ step: Double,
                             _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                iconTile(icon, tint, size: 26)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(T.ink2)
                Spacer(minLength: 8)
                Text(text)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(T.accent)
            }
            Slider(value: value, in: range, step: step)
                .tint(T.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: 画质

    private var qualityCard: some View {
        GroupCard("拍摄画质") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $qualityRaw) {
                    ForEach(VideoQuality.allCases) { q in
                        Text(q.title).tag(q.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Picker("", selection: $fps) {
                    ForEach(FrameRate.allCases) { f in
                        Text(f.title).tag(f.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(quality.note + "；" + frame.note)
                    .font(.system(size: 11))
                    .foregroundColor(T.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            RowDivider()

            row("sparkles.tv", T.accent2, "录制同时用这套参数提词") {
                Text("\(quality.title) · \(frame.title)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(T.accent)
            }
        }
    }

    // MARK: 提词

    private var promptCard: some View {
        GroupCard("提词默认值") {
            sliderBlock("textformat.size", T.accent, "字号", $fontSize, 22...58, 2, "\(Int(fontSize))")

            RowDivider()

            sliderBlock("speedometer", T.accent2, "匀速滚屏速度", $speed, 16...90, 2, "\(Int(speed))")

            RowDivider()

            row("timer", T.warn, "开拍倒计时") {
                Picker("", selection: $countdown) {
                    Text("关").tag(0)
                    Text("3 秒").tag(3)
                    Text("5 秒").tag(5)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }

            RowDivider()

            row("waveform", T.ok, "进入即开始跟读", sub: "关掉的话，进拍摄页默认是匀速滚动") {
                Toggle("", isOn: $followOn).labelsHidden().tint(T.accent)
            }

            RowDivider()

            row("rectangle.lefthalf.filled", T.accent, "镜像提词", sub: "外接提词器或反光板时把字翻过来") {
                Toggle("", isOn: $mirror).labelsHidden().tint(T.accent)
            }

            RowDivider()

            // 这条不是「更多功能」，是隐私开关：默认联网识别，关掉就只能本机算
            row("lock.shield", T.ok, "只用本机识别",
                sub: speechOnDevice ? "声音不出这台手机，准度略降"
                                    : "默认联网识别（更准），没网会自动换本机模型") {
                Toggle("", isOn: $speechOnDevice).labelsHidden().tint(T.accent)
            }
        }
    }

    // MARK: 录制 / 存储

    private var recordCard: some View {
        GroupCard("作品") {
            row("photo.on.rectangle.angled", T.accent, "录完自动存进相册", sub: "关掉的话只留在 App 里，手动导出") {
                Toggle("", isOn: $autoSave).labelsHidden().tint(T.accent)
            }

            RowDivider()

            row("arrow.left.arrow.right", T.accent2, "前置镜像保存",
                sub: "成片和取景框同方向。关掉后自拍会存真实方向，左右反过来") {
                Toggle("", isOn: $mirrorSave).labelsHidden().tint(T.accent)
            }

            RowDivider()

            row("internaldrive", T.sub, "本地占用", sub: "视频不进 iCloud 备份，删了 App 就一起没了") {
                Text("\(store.works.count) 个 · \(usedSpace)")
                    .font(.system(size: 13))
                    .foregroundColor(T.sub)
            }

            RowDivider()

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                row("gearshape", T.sub, "去系统设置里改权限") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(T.sub)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 关于

    private var aboutCard: some View {
        GroupCard("关于") {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("提词大师")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(T.ink)
                    Spacer()
                    Text(appVersion)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(T.sub)
                }
                // 以前这里写「声音不出本机」，但跟读默认走的是联网识别 —— 文案和代码对不上。
                // 现在只描述事实：台本和视频不出本机；识别去哪算，由上面那个开关决定。
                Text("台本和视频只存在这台手机上，不上传。跟读的识别结果是否上传，取决于「只用本机识别」那个开关。")
                    .font(.system(size: 11))
                    .foregroundColor(T.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            RowDivider()

            crashRow

            RowDivider()

            diagRow
        }
    }

    /// 录音诊断：录完没声音时，这一块能直接说明「麦克风有没有出数据」。
    /// 收到的帧数是 0，就是采集断了；帧数正常但成片没声，就是写入/编码断了。
    @ViewBuilder
    private var diagRow: some View {
        let text = diagText
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                iconTile("stethoscope", T.accent2, size: 26)
                Text("诊断日志")
                    .font(.system(size: 13))
                    .foregroundColor(T.ink2)
                Spacer()
                if text == nil {
                    Text("没有记录").font(.system(size: 12)).foregroundColor(T.sub)
                } else {
                    Button {
                        showDiag.toggle()
                    } label: {
                        Text(showDiag ? "收起" : "展开")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(T.accent)
                    }
                    Button {
                        Diag.clear()
                        diagText = Diag.read()
                        show("已清掉记录")
                    } label: {
                        Text("清掉")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(T.sub)
                    }
                }
            }
            if let text, showDiag {
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(T.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(T.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("录完一条没声音的，把这块截图发我")
                    .font(.system(size: 10))
                    .foregroundColor(T.sub)
            }
        }
        .padding(16)
    }

    /// 闪退自证：上次崩溃的原因直接摆在设置里，截图发过来就能定位
    @ViewBuilder
    private var crashRow: some View {
        let log = crashText
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                iconTile("exclamationmark.triangle", T.warn, size: 26)
                Text("上次闪退")
                    .font(.system(size: 13))
                    .foregroundColor(T.ink2)
                Spacer()
                if log == nil {
                    Text("没有记录").font(.system(size: 12)).foregroundColor(T.sub)
                } else {
                    Button {
                        CrashLog.clear()
                        crashText = CrashLog.read()
                        show("已清掉记录")
                    } label: {
                        Text("清掉")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(T.accent)
                    }
                }
            }
            if let log {
                Text(log)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(T.sub)
                    .lineLimit(12)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(T.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("把这张图截给我，就知道崩在哪一行了")
                    .font(.system(size: 10))
                    .foregroundColor(T.sub)
            }
        }
        .padding(16)
    }

    private func show(_ t: String) {
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { toast = nil }
    }
}
