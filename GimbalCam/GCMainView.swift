import SwiftUI
import AVFoundation
import UIKit
import PhotosUI

/// 相机预览层（铺满屏幕）
struct GCPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onTap: ((CGPoint) -> Void)?

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = UIScreen.main.bounds
        v.layer.addSublayer(layer)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.tapped(_:)))
        v.addGestureRecognizer(tap)
        context.coordinator.onTap = onTap
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        context.coordinator.onTap = onTap
        if let layer = v.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            layer.frame = v.bounds
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject {
        var onTap: ((CGPoint) -> Void)?
        @objc func tapped(_ g: UITapGestureRecognizer) {
            let p = g.location(in: g.view)
            guard let size = g.view?.bounds.size, size.width > 0, size.height > 0 else { return }
            onTap?(CGPoint(x: p.x / size.width, y: p.y / size.height))
        }
    }
}

struct GCMainView: View {
    @StateObject private var ble = GCBLEManager()
    @StateObject private var follow = GCFollowEngine()
    private let volumeShutter = GCVolumeShutter()

    @State private var camera: GCCamera?
    @State private var shutterEnabled = true
    @State private var showDiagnostics = false
    @State private var cameraStatus = "相机启动中…"

    // 拍摄
    @State private var mode: GCMode = .photo
    @State private var flashOn = false
    @State private var zoom: CGFloat = 1.0
    @State private var toast: String?
    @State private var showGallery = false

    // 面板开关（全部默认关闭，按需点出）
    @State private var showPrompter = false
    @State private var showGimbal = false
    @State private var showSettings = false
    @State private var showDevices = false

    // 提词内容
    @State private var script = "在此输入台词，或粘贴稿子。\n点播放开始自动滚动。"
    @State private var playing = false
    @State private var speed: CGFloat = 1.0
    @State private var fontSize: CGFloat = 28
    @State private var mirrored = false
    @State private var showBorder = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 全屏相机预览
            if let cam = camera {
                GCPreview(session: cam.session) { pt in cam.focus(at: pt) }
                    .ignoresSafeArea()
            }

            // 相机未就绪时的提示（避免纯黑屏无反馈）
            if cameraStatus != "相机就绪" {
                VStack(spacing: 8) {
                    ProgressView().colorScheme(.dark)
                    Text(cameraStatus).font(.caption).foregroundColor(.white.opacity(0.8))
                }
            }

            // 人脸跟踪框提示
            if follow.enabled {
                trackingIndicator
            }

            // 顶部栏
            VStack(spacing: 10) {
                topBar
                if showDevices { deviceList }
                Spacer()
            }
            .padding(.top, 6)

            // 右侧工具条
            VStack {
                Spacer().frame(height: 150)
                rightRail
                Spacer().frame(height: 260)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 16)

            // 底部相机控制
            VStack(spacing: 16) {
                modeBar
                shutterBar
            }
            .padding(.bottom, 18)
            .frame(maxHeight: .infinity, alignment: .bottom)

            // 提词浮层（默认关闭）
            if showPrompter {
                GCPrompter(text: $script, playing: $playing, speed: $speed,
                           fontSize: $fontSize, mirrored: $mirrored, showBorder: $showBorder)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // 云台控制面板
            if showGimbal { gimbalPanel }

            // 设置面板
            if showSettings { settingsView }

            // 相册（系统照片选择器）
            if showGallery {
                GCGalleryPicker { showGallery = false }
                    .edgesIgnoringSafeArea(.all)
            }

            // 提示
            if let t = toast {
                Text(t)
                    .font(.subheadline).foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.black.opacity(0.8)).cornerRadius(20)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showPrompter)
        .statusBar(hidden: true)
        .onAppear {
            setupCamera()
            volumeShutter.onShutter = {
                flashToast("收到拍照键 · \(mode == .photo ? "拍照" : "录像")")
                shoot()
            }
            volumeShutter.start()
            ble.onButton = { event in handleGimbalButton(event) }
        }
        .onDisappear { camera?.stop(); ble.disconnect(); volumeShutter.stop() }
    }

    // MARK: - 初始化相机
    private func setupCamera() {
        let c = GCCamera()
        c.onStatus = { s in cameraStatus = s }
        c.onFace = { dx, dy, landscape in
            if let cmd = follow.compute(dx: dx, dy: dy) {
                ble.send(GCProtocol.yawPitch(cmd.0, cmd.1))
            }
            follow.updateOrientation(landscape: landscape)
        }
        c.onPhotoSaved = { ok in flashToast(ok ? "照片已保存到相册" : "拍照失败") }
        c.onVideoSaved = { ok in flashToast(ok ? "视频已保存到相册" : "录像保存失败") }
        c.onRecordingChanged = { recording in
            if recording { flashToast("录制中…再次点击停止") }
        }
        c.start()
        camera = c
        zoom = c.zoomFactor
    }

    private func flashToast(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { toast = nil }
    }

    // MARK: - 顶部栏
    private var topBar: some View {
        HStack(spacing: 14) {
            // 云台连接状态（点击进入设备列表）
            Button {
                withAnimation { showDevices.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(ble.connected ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(ble.connected ? "云台已连接" : "连接云台")
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 10))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.black.opacity(0.55)).cornerRadius(18)
            }

            Spacer()

            topIcon("bolt.fill", active: flashOn) {
                flashOn.toggle()
                camera?.setFlash(flashOn)
            }
            topIcon("text.bubble") { withAnimation { showPrompter.toggle() } }
            topIcon("gearshape") { showSettings = true }
        }
        .padding(.horizontal, 16)
    }

    private func topIcon(_ name: String, active: Bool = false,
                         _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(active ? .yellow : .white)
                .frame(width: 38, height: 38)
                .background(Color.black.opacity(active ? 0.7 : 0.5))
                .clipShape(Circle())
        }
    }

    // MARK: - 设备列表
    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("附近蓝牙设备 · \(ble.stateText)").foregroundColor(.white).font(.caption)
                Spacer()
                Button("扫描") { ble.scan() }.foregroundColor(.cyan).font(.caption)
                Button("自动连云台") { ble.autoConnectGimbal(); flashToast("自动连接最强云台信号") }
                    .foregroundColor(.green).font(.caption)
                Button("收起") { withAnimation { showDevices = false } }
                    .foregroundColor(.gray).font(.caption)
            }
            if ble.devices.isEmpty {
                Text("未发现设备，请确认云台已开机").foregroundColor(.gray).font(.caption)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(ble.devices, id: \.identifier) { d in
                            Button {
                                ble.connect(d)
                                flashToast("正在连接 \(d.name ?? "设备")")
                            } label: {
                                Text(ble.deviceLabel(d))
                                    .font(.caption).foregroundColor(.white)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Color.blue.opacity(0.75)).cornerRadius(14)
                            }
                        }
                    }
                }
            }
            // 状态行 + 重连
            HStack(spacing: 10) {
                Circle().fill(ble.connected ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                Text(ble.connected ? "控制通道已就绪" : "未连接控制通道")
                    .font(.caption).foregroundColor(ble.connected ? .green : .red)
                Spacer()
                Button("重新连接") { ble.reconnect(); flashToast("正在重连云台") }
                    .foregroundColor(.cyan).font(.caption)
                Button(showDiagnostics ? "隐藏诊断" : "BLE诊断") {
                    withAnimation { showDiagnostics.toggle() }
                }.foregroundColor(.orange).font(.caption)
            }
            if showDiagnostics {
                VStack(alignment: .leading, spacing: 4) {
                    Text("⚠️ 若一直断开：去 iPhone 设置→蓝牙→Gimbal Go 右边的ⓘ→「忽略此设备」，\n然后回这里点「重新连接」。系统HID占用会让云台只肯连一路。")
                        .font(.system(size: 9)).foregroundColor(.yellow)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("状态: \(ble.stateText)").foregroundColor(.cyan)
                                .font(.system(size: 9, design: .monospaced))
                            ForEach(ble.logs, id: \.self) { l in
                                Text(l).font(.system(size: 9, design: .monospaced)).foregroundColor(.green)
                            }
                            Text(ble.diagnostics)
                                .font(.system(size: 9, design: .monospaced)).foregroundColor(.white)
                        }
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.8)).cornerRadius(12)
        .padding(.horizontal, 16)
    }

    // MARK: - 右侧工具条
    private var rightRail: some View {
        VStack(spacing: 18) {
            railButton("camera.rotate", label: "翻转") { camera?.switchCamera() }
            railButton("slider.horizontal.3", label: "跟随") {
                follow.enabled.toggle(); follow.reset()
                withAnimation { showGimbal = true }
            }
            railButton("gamecontroller", label: "云台") { withAnimation { showGimbal.toggle() } }
            railButton("photo", label: "相册") { showGallery = true }
        }
    }

    private func railButton(_ name: String, label: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: name).font(.system(size: 20))
                Text(label).font(.system(size: 10))
            }
            .foregroundColor(.white)
            .frame(width: 46, height: 52)
            .background(Color.black.opacity(0.5)).cornerRadius(12)
        }
    }

    // MARK: - 模式栏
    private var modeBar: some View {
        HStack(spacing: 22) {
            ForEach(GCMode.allCases, id: \.self) { m in
                Button {
                    mode = m
                    if m == .video && camera?.isRecording == true { camera?.toggleRecording() }
                } label: {
                    Text(m.title)
                        .font(.system(size: mode == m ? 16 : 14,
                                      weight: mode == m ? .semibold : .regular))
                        .foregroundColor(mode == m ? .yellow : .white.opacity(0.7))
                }
            }
        }
    }

    // MARK: - 快门栏
    private var shutterBar: some View {
        HStack(alignment: .center) {
            // 相册缩略入口
            Button { showGallery = true } label: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "photo").foregroundColor(.white))
            }
            .frame(minWidth: 70)

            Spacer()

            // 快门
            Button { shoot() } label: {
                ZStack {
                    Circle().stroke(mode == .video && camera?.isRecording == true ? Color.red : Color.white,
                                    lineWidth: 3).frame(width: 78, height: 78)
                    if mode == .video && camera?.isRecording == true {
                        RoundedRectangle(cornerRadius: 5).fill(Color.red)
                            .frame(width: 30, height: 30)
                    } else {
                        Circle().fill(mode == .video ? Color.red : Color.white)
                            .frame(width: 64, height: 64)
                    }
                }
            }
            .frame(minWidth: 78)

            Spacer()

            // 变焦
            VStack(spacing: 4) {
                Text(String(format: "%.1fx", zoom))
                    .font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                Slider(value: $zoom, in: 1...max(1.5, camera?.maxZoom ?? 2), step: 0.1)
                    .frame(width: 90)
                    .accentColor(.yellow)
                    .onChange(of: zoom) { v in camera?.setZoom(v) }
            }
            .frame(minWidth: 100)
        }
        .padding(.horizontal, 18)
    }

    private func shoot() {
        guard camera != nil else { flashToast(cameraStatus); return }
        if mode == .photo {
            camera?.takePhoto()
        } else {
            camera?.toggleRecording()
        }
    }

    /// 云台物理按键触发的动作（来自 FF02 通知解码）
    private func handleGimbalButton(_ event: Int) {
        switch event {
        case 0: // 拍照
            mode = .photo
            camera?.takePhoto()
        case 1: // 录像
            mode = .video
            camera?.toggleRecording()
        case 5: // 拍照或录像：按当前模式
            shoot()
        case 2: // 放大
            zoom = Swift.min(max(1.5, camera?.maxZoom ?? 2), zoom + 0.3)
            camera?.setZoom(zoom)
            flashToast("放大 \(String(format: "%.1f", zoom))x")
        case 3: // 缩小
            zoom = Swift.max(1.0, zoom - 0.3)
            camera?.setZoom(zoom)
            flashToast("缩小 \(String(format: "%.1f", zoom))x")
        case 6: // 人脸跟踪切换
            follow.enabled.toggle(); follow.reset()
            flashToast(follow.enabled ? "跟踪已开" : "跟踪已关")
        default:
            break
        }
    }

    // MARK: - 跟踪提示
    private var trackingIndicator: some View {
        VStack(spacing: 5) {
            if ble.connected {
                Text(follow.orientationLocked ? "跟踪中 · 横竖屏已锁定" : "跟踪中 · 画面稳定确认中…")
                    .font(.caption).foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.green.opacity(0.75)).cornerRadius(14)
            } else {
                // 跟随开着但没连上控制通道 —— 明确告诉用户为什么云台不动
                VStack(spacing: 3) {
                    Text("⚠️ 未连接云台控制通道 · 云台不会转动")
                        .font(.caption).foregroundColor(.white)
                    Text("点顶部「连接云台」→ 选带 ★云台 的设备")
                        .font(.system(size: 10)).foregroundColor(.white.opacity(0.85))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.orange.opacity(0.85)).cornerRadius(12)
                .onTapGesture { withAnimation { showDevices = true } }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 120)
    }

    // MARK: - 云台控制面板
    private var gimbalPanel: some View {
        VStack(spacing: 14) {
            HStack {
                Text("云台控制").font(.headline).foregroundColor(.white)
                Spacer()
                Button("收起") { withAnimation { showGimbal = false } }
                    .foregroundColor(.gray)
            }

            HStack {
                Toggle("人脸跟随", isOn: $follow.enabled)
                    .foregroundColor(.white)
                    .onChange(of: follow.enabled) { _ in follow.reset() }
            }

            // 方向键
            VStack(spacing: 8) {
                directionButton("▲", 0, 350)
                HStack(spacing: 8) {
                    directionButton("◀", -350, 0)
                    directionButton("■", 0, 0)
                    directionButton("▶", 350, 0)
                }
                directionButton("▼", 0, -350)
            }

            HStack {
                Button("扫描设备") { ble.scan() }.foregroundColor(.cyan)
                Spacer()
                Text("连接：\(ble.stateText)").foregroundColor(.gray).font(.caption)
                Spacer()
                Button("解锁横竖屏") { follow.manualUnlock() }.foregroundColor(.orange)
            }
            .font(.caption)
        }
        .padding(18)
        .background(Color.black.opacity(0.9)).cornerRadius(18)
        .frame(width: min(340, UIScreen.main.bounds.width - 40))
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func directionButton(_ t: String, _ y: Int, _ p: Int) -> some View {
        Button { ble.send(GCProtocol.yawPitch(y, p)) } label: {
            Text(t).font(.title3).foregroundColor(.white)
                .frame(width: 52, height: 44)
                .background(Color.white.opacity(0.16)).cornerRadius(10)
        }
    }

    // MARK: - 设置面板
    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("设置").font(.title3.bold()).foregroundColor(.white)
                    Spacer()
                    Button("关闭") { showSettings = false }.foregroundColor(.gray)
                }

                Group {
                    Text("拍照按键").font(.headline).foregroundColor(.white)
                    Toggle("云台拍照键当快门", isOn: $shutterEnabled)
                        .foregroundColor(.white)
                        .onChange(of: shutterEnabled) { on in
                            if on { volumeShutter.start() } else { volumeShutter.stop() }
                        }
                    Text("开启后，按云台上的拍照键（手机会显示为音量键）即可拍照/录像")
                        .font(.caption).foregroundColor(.gray)
                }

                Group {
                    Text("云台跟随").font(.headline).foregroundColor(.white)
                    sliderRow("灵敏度", value: Binding(get: { Double(follow.gain) },
                        set: { follow.gain = Float($0) }), range: 0.2...3.0)
                    sliderRow("死区", value: Binding(get: { Double(follow.deadzone) },
                        set: { follow.deadzone = Float($0) }), range: 0.0...0.3)
                    sliderRow("平滑", value: Binding(get: { Double(follow.smoothing) },
                        set: { follow.smoothing = Float($0) }), range: 0.05...1.0)
                    Toggle("水平反转", isOn: $follow.invertX).foregroundColor(.white)
                    Toggle("俯仰反转", isOn: $follow.invertY).foregroundColor(.white)
                }

                Group {
                    Text("提词").font(.headline).foregroundColor(.white).padding(.top, 6)
                    Toggle("显示提词浮层", isOn: $showPrompter).foregroundColor(.white)
                    sliderCGFloat("滚动速度", value: $speed, range: 0.2...6.0)
                    sliderCGFloat("字号", value: $fontSize, range: 16...60)
                    Toggle("镜像", isOn: $mirrored).foregroundColor(.white)
                    Toggle("边框", isOn: $showBorder).foregroundColor(.white)
                    TextEditor(text: $script).frame(height: 90).cornerRadius(6)
                }

                Group {
                    Text("协议（云台不动时切换）").font(.headline).foregroundColor(.white).padding(.top, 6)
                    Picker("通道", selection: Binding(get: { Int(GCProtocol.channel) },
                        set: { GCProtocol.channel = UInt8($0) })) {
                        Text("通道3").tag(3); Text("通道2").tag(2)
                    }.pickerStyle(.segmented).colorScheme(.dark)
                    Toggle("内层校验", isOn: Binding(get: { GCProtocol.innerChecksum },
                        set: { GCProtocol.innerChecksum = $0 })).foregroundColor(.white)
                    Toggle("外层CRC8", isOn: Binding(get: { GCProtocol.outerCrc },
                        set: { GCProtocol.outerCrc = $0 })).foregroundColor(.white)
                }
            }
            .padding()
        }
        .background(Color.black.opacity(0.95))
        .frame(height: UIScreen.main.bounds.height * 0.78)
        .frame(maxHeight: .infinity, alignment: .bottom)
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

    private func sliderCGFloat(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title).foregroundColor(.white).font(.caption)
                Spacer()
                Text(String(format: "%.1f", value.wrappedValue)).foregroundColor(.gray).font(.caption)
            }
            Slider(value: value, in: range)
        }
    }
}

enum GCMode: CaseIterable {
    case video, photo, portrait
    var title: String {
        switch self { case .video: return "视频"; case .photo: return "照片"; case .portrait: return "人像" }
    }
}

/// 系统照片选择器（查看刚拍的照片/视频）
struct GCGalleryPicker: UIViewControllerRepresentable {
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onDismiss()
        }
    }
}
