import SwiftUI
import AVFoundation
import UIKit

/// 相机预览层
struct GCPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = UIScreen.main.bounds
        v.layer.addSublayer(layer)
        return v
    }
    func updateUIView(_ v: UIView, context: Context) {
        if let layer = v.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            layer.frame = v.bounds
        }
    }
}

struct GCMainView: View {
    @StateObject private var ble = GCBLEManager()
    @StateObject private var follow = GCFollowEngine()
    @State private var camera: GCCamera?

    @State private var showPrompter = true
    @State private var showSettings = false
    @State private var script = "在此输入台词，或粘贴稿子。\n点「播放」开始自动滚动。"
    @State private var playing = false
    @State private var speed: CGFloat = 1.0
    @State private var fontSize: CGFloat = 28
    @State private var mirrored = false
    @State private var showBorder = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let cam = camera {
                GCPreview(session: cam.session).ignoresSafeArea()
            }

            if showPrompter {
                GCPrompter(text: $script, playing: $playing, speed: $speed,
                           fontSize: $fontSize, mirrored: $mirrored, showBorder: $showBorder)
            }

            // 顶部状态 + 按钮
            VStack(spacing: 8) {
                Text(ble.stateText)
                    .font(.caption).foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.black.opacity(0.6)).cornerRadius(8)

                HStack(spacing: 8) {
                    gcBtn("扫描") { ble.scan() }
                    gcBtn(follow.enabled ? "跟随✓" : "跟随") {
                        follow.enabled.toggle(); follow.reset()
                    }
                    gcBtn(showPrompter ? "提词✓" : "提词") { showPrompter.toggle() }
                    gcBtn(playing ? "暂停" : "播放") { playing.toggle() }
                    gcBtn("设置") { showSettings.toggle() }
                }

                // 设备列表
                if !ble.devices.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(ble.devices, id: \.identifier) { d in
                                Button(d.name ?? "设备") { ble.connect(d) }
                                    .font(.caption).foregroundColor(.white)
                                    .padding(6).background(Color.blue.opacity(0.7)).cornerRadius(6)
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding(.top, 8)

            // 手动方向控制（底部，真机验证协议用）
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    gcBtn("◀") { turn(-300, 0) }
                    gcBtn("■") { turn(0, 0) }
                    gcBtn("▶") { turn(300, 0) }
                    gcBtn("▲") { turn(0, 300) }
                    gcBtn("▼") { turn(0, -300) }
                }
                .padding(.bottom, 12)
            }

            // 日志
            VStack {
                Spacer()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(ble.logs.prefix(5), id: \.self) { l in
                            Text(l).font(.system(size: 9)).foregroundColor(.green)
                        }
                    }
                    Spacer()
                }
                .padding(.leading, 8).padding(.bottom, 60)
            }

            // 设置面板
            if showSettings {
                settingsView
            }
        }
        .onAppear {
            let c = GCCamera()
            c.onFace = { dx, dy, landscape in
                if let cmd = follow.compute(dx: dx, dy: dy) {
                    ble.send(GCProtocol.yawPitch(cmd.0, cmd.1))
                }
                follow.updateOrientation(landscape: landscape)
            }
            c.start()
            camera = c
        }
        .onDisappear { camera?.stop(); ble.disconnect() }
    }

    private func turn(_ y: Int, _ p: Int) { ble.send(GCProtocol.yawPitch(y, p)) }

    private func gcBtn(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button(t) { action() }
            .font(.caption).foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.black.opacity(0.65)).cornerRadius(8)
    }

    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("跟随设置").font(.headline).foregroundColor(.white)
                sliderRow("灵敏度", value: Binding(get: { Double(follow.gain) },
                    set: { follow.gain = Float($0) }), range: 0.2...3.0)
                sliderRow("死区", value: Binding(get: { Double(follow.deadzone) },
                    set: { follow.deadzone = Float($0) }), range: 0.0...0.3)
                sliderRow("平滑", value: Binding(get: { Double(follow.smoothing) },
                    set: { follow.smoothing = Float($0) }), range: 0.05...1.0)
                Toggle("水平反转", isOn: $follow.invertX).foregroundColor(.white)
                Toggle("俯仰反转", isOn: $follow.invertY).foregroundColor(.white)

                Text("提词设置").font(.headline).foregroundColor(.white).padding(.top)
                sliderRow("速度", value: $speed, range: 0.2...6.0)
                sliderRow("字号", value: $fontSize, range: 16...60)
                Toggle("镜像", isOn: $mirrored).foregroundColor(.white)
                Toggle("边框", isOn: $showBorder).foregroundColor(.white)

                Text("台词").font(.headline).foregroundColor(.white).padding(.top)
                TextEditor(text: $script).frame(height: 90).cornerRadius(6)

                Text("协议变体（云台不动时切换）").font(.headline).foregroundColor(.white).padding(.top)
                Picker("通道", selection: Binding(get: { Int(GCProtocol.channel) },
                    set: { GCProtocol.channel = UInt8($0) })) {
                    Text("通道3").tag(3); Text("通道2").tag(2)
                }.pickerStyle(.segmented).colorScheme(.dark)
                Toggle("内层校验", isOn: Binding(get: { GCProtocol.innerChecksum },
                    set: { GCProtocol.innerChecksum = $0 })).foregroundColor(.white)
                Toggle("外层CRC8", isOn: Binding(get: { GCProtocol.outerCrc },
                    set: { GCProtocol.outerCrc = $0 })).foregroundColor(.white)

                Button("解锁横竖屏") { follow.manualUnlock() }.foregroundColor(.white)
                Button("关闭设置") { showSettings = false }.foregroundColor(.white)
            }
            .padding()
        }
        .background(Color.black.opacity(0.92))
        .frame(height: UIScreen.main.bounds.height * 0.7)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title).foregroundColor(.white).font(.caption)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue)).foregroundColor(.gray).font(.caption)
            }
            Slider(value: value, in: range)
        }
    }
}
