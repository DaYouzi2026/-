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

    @State private var toast: String?
    @State private var crashText: String?
    @State private var diagText: String?

    private var quality: VideoQuality { VideoQuality(rawValue: qualityRaw) ?? .uhd }
    private var frame: FrameRate { FrameRate(rawValue: fps) ?? .fps30 }

    private var usedSpace: String {
        let total = store.works.reduce(Int64(0)) { $0 + $1.size }
        let mb = Double(total) / 1048576.0
        return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("我的")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(.white)
            Text("设置只对这台手机生效")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.78))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .background(
            T.grad
                .ignoresSafeArea(edges: .top)
        )
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

            HStack {
                Text("录制同时用这套参数提词")
                    .font(.system(size: 13))
                    .foregroundColor(T.ink2)
                Spacer()
                Text("\(quality.title) · \(frame.title)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(T.accent)
            }
            .padding(16)
        }
    }

    // MARK: 提词

    private var promptCard: some View {
        GroupCard("提词默认值") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("字号").font(.system(size: 13)).foregroundColor(T.ink2)
                    Spacer()
                    Text("\(Int(fontSize))")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(T.accent)
                }
                Slider(value: $fontSize, in: 22...58, step: 2)
                    .tint(T.accent)
            }
            .padding(16)

            RowDivider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("匀速滚屏速度").font(.system(size: 13)).foregroundColor(T.ink2)
                    Spacer()
                    Text("\(Int(speed))").font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(T.accent)
                }
                Slider(value: $speed, in: 16...90, step: 2)
                    .tint(T.accent)
            }
            .padding(16)

            RowDivider()

            HStack {
                Text("开拍倒计时").font(.system(size: 13)).foregroundColor(T.ink2)
                Spacer()
                Picker("", selection: $countdown) {
                    Text("关").tag(0)
                    Text("3 秒").tag(3)
                    Text("5 秒").tag(5)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
            .padding(16)

            RowDivider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("进入即开始跟读").font(.system(size: 13)).foregroundColor(T.ink2)
                    Text("关掉的话，进拍摄页默认是匀速滚动").font(.system(size: 11)).foregroundColor(T.sub)
                }
                Spacer()
                Toggle("", isOn: $followOn).labelsHidden().tint(T.accent)
            }
            .padding(16)

            RowDivider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("镜像提词").font(.system(size: 13)).foregroundColor(T.ink2)
                    Text("外接提词器或反光板时把字翻过来").font(.system(size: 11)).foregroundColor(T.sub)
                }
                Spacer()
                Toggle("", isOn: $mirror).labelsHidden().tint(T.accent)
            }
            .padding(16)
        }
    }

    // MARK: 录制 / 存储

    private var recordCard: some View {
        GroupCard("作品") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("录完自动存进相册").font(.system(size: 13)).foregroundColor(T.ink2)
                    Text("关掉的话只留在 App 里，手动导出").font(.system(size: 11)).foregroundColor(T.sub)
                }
                Spacer()
                Toggle("", isOn: $autoSave).labelsHidden().tint(T.accent)
            }
            .padding(16)

            RowDivider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("前置镜像保存").font(.system(size: 13)).foregroundColor(T.ink2)
                    Text("成片和取景框同方向。关掉后自拍会存真实方向，左右反过来")
                        .font(.system(size: 11))
                        .foregroundColor(T.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $mirrorSave).labelsHidden().tint(T.accent)
            }
            .padding(16)

            RowDivider()

            HStack {
                Text("本地占用").font(.system(size: 13)).foregroundColor(T.ink2)
                Spacer()
                Text("\(store.works.count) 个 · \(usedSpace)")
                    .font(.system(size: 13))
                    .foregroundColor(T.sub)
            }
            .padding(16)

            RowDivider()

            Button {
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            } label: {
                HStack {
                    Text("去系统设置里改权限").font(.system(size: 13)).foregroundColor(T.ink2)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(T.sub)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
        }
    }

    private var aboutCard: some View {
        GroupCard("关于") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("提词大师").font(.system(size: 14, weight: .semibold)).foregroundColor(T.ink)
                    Spacer()
                    Text("1.16")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(T.sub)
                }
                Text("跟读用系统自带的中文识别，声音不出本机。台本、视频都只存在这台手机上。")
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("录音诊断")
                    .font(.system(size: 13))
                    .foregroundColor(T.ink2)
                Spacer()
                if text == nil {
                    Text("没有记录").font(.system(size: 12)).foregroundColor(T.sub)
                } else {
                    Button {
                        Diag.clear()
                        diagText = Diag.read()
                        show("已清掉记录")
                    } label: {
                        Text("清掉")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(T.accent)
                    }
                }
            }
            if let text {
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(T.sub)
                    .lineLimit(14)
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
