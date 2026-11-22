import Foundation
import CoreBluetooth

/// 云台 BLE 连接（2.3 稳健版）
/// 诊断截图已证实云台开放了控制服务 02F00000-...-FE00 + 写 FF01 + 通知 FF02。
/// 本版重点解决"连上又断开"：自动重连、只在当前设备上处理断开、
/// 不再因为"没识别到服务"就主动踢掉连接、放宽写特征挑选。
final class GCBLEManager: NSObject, ObservableObject,
                          CBCentralManagerDelegate, CBPeripheralDelegate {

    @Published var stateText = "初始化…"
    @Published var devices: [CBPeripheral] = []
    @Published var deviceRSSI: [UUID: Int] = [:]
    @Published var deviceUUIDs: [UUID: [String]] = [:]
    @Published var logs: [String] = []
    @Published var connected = false
    @Published var diagnostics = ""
    @Published var lastConnectedName = ""
    @Published var lastButtonEvent = ""
    @Published var foundControlChannel = false
    @Published var reconnectCount = 0

    /// 云台物理按键事件：0=拍照 1=录像 2=放大 3=缩小 4=停止缩放 5=拍照或录像 6=人脸跟踪
    var onButton: ((Int) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var allWriteChars: [CBCharacteristic] = []
    private var allNotifyChars: [CBCharacteristic] = []

    private var wantConnected = false
    private var reconnectTries = 0
    private var connectTimer: Timer?
    private var reconnectTimer: Timer?

    private let knownWrite = ["FF01", "FFF1", "FFE1",
                              "02F00000-0000-0000-0000-00000000FF01",
                              "0000ff01-0000-1000-8000-00805f9b34fb"]
    private let knownNotify = ["FF02", "FFF2", "FFE2",
                               "02F00000-0000-0000-0000-00000000FF02",
                               "0000ff02-0000-1000-8000-00805f9b34fb"]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - 中心状态
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            stateText = "就绪 · 扫描中…"
            scan()
        case .unauthorized:
            stateText = "蓝牙未授权，请在设置中允许"
        case .poweredOff:
            stateText = "请打开蓝牙"
        default:
            stateText = "蓝牙不可用"
        }
    }

    // MARK: - 扫描
    func scan() {
        guard central.state == .poweredOn else { return }
        stateText = "扫描中…"
        clearTimers()
        devices.removeAll()
        deviceRSSI.removeAll()
        deviceUUIDs.removeAll()
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self = self else { return }
            self.central.stopScan()
            if !self.connected {
                self.stateText = "扫描结束 · 连接中…"
                self.autoConnectGimbal()
            }
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        deviceRSSI[p.identifier] = RSSI.intValue
        let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map { $0.uuidString } ?? []
        if !uuids.isEmpty { deviceUUIDs[p.identifier] = uuids }
        if !devices.contains(where: { $0.identifier == p.identifier }) {
            devices.append(p)
            devices.sort { a, b in
                let sa = candidateScore(a), sb = candidateScore(b)
                if sa != sb { return sa > sb }
                return (deviceRSSI[a.identifier] ?? -100) > (deviceRSSI[b.identifier] ?? -100)
            }
        }
        refreshDiagnostics()
    }

    private func candidateScore(_ p: CBPeripheral) -> Int {
        if isGimbalName(p.name ?? "") { return 3 }
        if let uuids = deviceUUIDs[p.identifier] {
            for u in uuids {
                let s = u.uppercased()
                if s.contains("FE00") || s.contains("02F00000")
                    || s.contains("FFE0") || s.contains("FFF0") || s.contains("FFFF") { return 2 }
            }
        }
        if p.name == nil && (deviceRSSI[p.identifier] ?? -100) > -80 { return 1 }
        return 0
    }

    private func isCandidate(_ p: CBPeripheral) -> Bool { candidateScore(p) > 0 }

    private func isGimbalName(_ n: String) -> Bool {
        let s = n.lowercased()
        return s.contains("gimbal") || s.contains("云台") || s.contains("netviv")
            || s.contains("jy-") || s.contains("stabilizer")
    }

    func deviceLabel(_ p: CBPeripheral) -> String {
        let name = p.name ?? "未命名"
        let r = deviceRSSI[p.identifier].map { "\($0)dBm" } ?? "?"
        let tag = isCandidate(p) ? " ★候选" : ""
        return "\(name) \(r)\(tag)"
    }

    func deviceDetail(_ p: CBPeripheral) -> String {
        let name = p.name ?? "未命名"
        let r = deviceRSSI[p.identifier].map { "\($0)" } ?? "?"
        let uuids = deviceUUIDs[p.identifier]?.joined(separator: ",") ?? "无广播UUID"
        return "\(name) | \(r)dBm | \(isCandidate(p) ? "候选" : "其他") | \(uuids)"
    }

    /// 自动连接最合适的候选（只连一次，不来回踢）
    func autoConnectGimbal() {
        guard !connected else { return }
        let cands = devices.filter { candidateScore($0) > 0 }
            .sorted { a, b in
                let sa = candidateScore(a), sb = candidateScore(b)
                if sa != sb { return sa > sb }
                return (deviceRSSI[a.identifier] ?? -100) > (deviceRSSI[b.identifier] ?? -100)
            }
        if let p = cands.first {
            addLog("自动连接: \(p.name ?? "未命名")")
            connect(p)
        } else {
            stateText = "未发现云台 · 请确认已开机"
            refreshDiagnostics()
        }
    }

    // MARK: - 连接
    func connect(_ p: CBPeripheral) {
        clearTimers()
        wantConnected = true
        reconnectTries = 0
        stateText = "连接中… \(p.name ?? "未命名")"
        lastConnectedName = p.name ?? "未命名设备"
        peripheral = p
        p.delegate = self
        central.connect(p, options: nil)
        connectTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self = self, !self.connected else { return }
            self.addLog("连接超时（可能被系统HID占用）")
            self.stateText = "连接超时 · 点重新连接"
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        stateText = "已连接 · 发现服务…"
        addLog("已连接 \(p.name ?? "未命名")")
        allWriteChars.removeAll()
        allNotifyChars.removeAll()
        writeChar = nil
        diagnostics = "发现服务中…"
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        clearTimers()
        stateText = "连接失败 · 点重新连接"
        addLog("连接失败: \(error?.localizedDescription ?? "未知")")
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        clearTimers()
        guard p.identifier == peripheral?.identifier else { return }   // 只处理当前设备，避免误判
        let wasConnected = connected
        connected = false
        foundControlChannel = false
        writeChar = nil
        if wantConnected && reconnectTries < 8 {
            reconnectTries += 1
            reconnectCount = reconnectTries
            stateText = "已断开 · 自动重连(\(reconnectTries)/8)…"
            addLog("断开，2秒后重连 #\(reconnectTries)")
            reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                guard let self = self, let p = self.peripheral else { return }
                self.central.connect(p, options: nil)
            }
        } else {
            stateText = "已断开 · 点重新连接"
            if wasConnected { addLog("已断开") }
        }
    }

    // MARK: - 服务 / 特征
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = p.services, !services.isEmpty else {
            diagnostics = "未发现服务（该设备可能只有 HID）"
            stateText = "无控制服务 · 请忽略系统蓝牙配对后重试"
            return
        }
        addLog("发现 \(services.count) 个服务")
        for s in services { p.discoverCharacteristics(nil, for: s) }
        refreshDiagnostics(services: services.map { $0.uuid.uuidString })
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let chars = s.characteristics else { return }
        for ch in chars {
            if ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse) {
                allWriteChars.append(ch)
            }
            if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                allNotifyChars.append(ch)
                p.setNotifyValue(true, for: ch)
            }
        }
        pickCharacteristics()
    }

    private func rank(_ ch: CBCharacteristic, _ known: [String]) -> Int {
        let u = ch.uuid.uuidString.uppercased()
        for (i, k) in known.enumerated() where u == k.uppercased() || u.hasSuffix(k.uppercased()) {
            return 100 - i
        }
        return 0
    }

    private func pickCharacteristics() {
        guard let best = allWriteChars.sorted(by: { rank($0, knownWrite) > rank($1, knownWrite) }).first
        else { return }
        if writeChar?.uuid != best.uuid {
            writeChar = best
            addLog("控制写通道: \(best.uuid.uuidString)")
        }
        for ch in allNotifyChars.sorted(by: { rank($0, knownNotify) > rank($1, knownNotify) }) {
            peripheral?.setNotifyValue(true, for: ch)
        }
        if !connected {
            connected = true
            foundControlChannel = true
            reconnectTries = 0
            reconnectCount = 0
            stateText = "云台已连接 ✓"
            addLog("✓ 控制通道就绪，可以发指令")
            refreshDiagnostics()
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let v = c.value else { return }
        let bytes = [UInt8](v)
        addLog("← " + GCProtocol.hex(bytes))
        parseButtonNotify(bytes)
    }

    /// 解析云台 FF02 通知里的物理按键事件（事件码同 Gimbal Play 的 l70 枚举）
    private func parseButtonNotify(_ b: [UInt8]) {
        var frame = b
        // 去外层 FF FF lenHi lenLo
        if b.count > 4, b[0] == 0xFF, b[1] == 0xFF { frame = Array(b[4...]) }
        // 找内层 55 02
        var inner = -1
        for i in 0..<max(0, frame.count - 4) where frame[i] == 0x55 && frame[i+1] == 0x02 {
            inner = i; break
        }
        guard inner >= 0, inner + 3 < frame.count else { return }   // 未识别成帧就不乱判
        let cmd = frame[inner + 3]
        var event: Int? = nil
        if cmd == 0x22 || cmd == 0x31, inner + 6 < frame.count {
            event = mapEvent(frame[inner + 6])
        } else {
            event = mapEvent(cmd)
        }
        if let e = event {
            let names = ["拍照", "录像", "放大", "缩小", "停止缩放", "拍照/录像", "人脸跟踪"]
            lastButtonEvent = names[e]
            addLog("★按键: \(names[e])")
            onButton?(e)
        }
    }

    private func mapEvent(_ v: UInt8) -> Int? {
        switch v {
        case 2: return 0          // TakePicture
        case 3: return 1          // TakeVideo
        case 4: return 5          // TakePictureOrVideo
        case 9, 11: return 2      // ZoomIn / ZoomIn2
        case 10, 12: return 3     // ZoomOut / ZoomOut2
        case 13: return 4         // StopZoom
        case 17: return 6         // FaceTraceToggle
        default: return nil
        }
    }

    // MARK: - 发指令
    private var lastWrite: TimeInterval = 0
    func send(_ data: [UInt8]) {
        guard connected, let p = peripheral, let ch = writeChar else {
            addLog("未连接控制通道，指令未发出")
            return
        }
        let now = Date().timeIntervalSince1970
        if now - lastWrite < 0.02 {
            let delay = 0.02 - (now - lastWrite)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.doSend(data) }
        } else {
            doSend(data)
        }
        lastWrite = now
    }

    private func doSend(_ data: [UInt8]) {
        guard let p = peripheral, let ch = writeChar else { return }
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(data), for: ch, type: type)
        addLog("→ " + GCProtocol.hex(data))
    }

    private func addLog(_ s: String) {
        logs.insert(s, at: 0)
        if logs.count > 16 { logs.removeLast() }
    }

    private func refreshDiagnostics(services: [String]? = nil) {
        var lines: [String] = []
        lines.append("扫描到 \(devices.count) 个设备：")
        for p in devices { lines.append(deviceDetail(p)) }
        if let svcs = services {
            lines.append("设备服务：")
            lines.append(contentsOf: svcs)
        }
        if let ch = writeChar {
            lines.append("已选写特征：\(ch.uuid.uuidString)")
        }
        diagnostics = lines.joined(separator: "\n")
    }

    private func clearTimers() {
        connectTimer?.invalidate(); connectTimer = nil
        reconnectTimer?.invalidate(); reconnectTimer = nil
    }

    func disconnect() {
        wantConnected = false
        clearTimers()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        connected = false
    }

    /// 手动重连（UI 按钮）
    func reconnect() {
        guard let p = peripheral else { scan(); return }
        wantConnected = true
        reconnectTries = 0
        stateText = "重新连接…"
        central.connect(p, options: nil)
    }
}
