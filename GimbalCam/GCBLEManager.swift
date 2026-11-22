import Foundation
import CoreBluetooth

/// CoreBluetooth 云台连接（增强版）
/// - 云台通常广播两个 BLE 身份：HID 拍照键（被 iOS 系统占用，App 扫不到）
///   与 GATT 控制通道（FE00/02F00000 服务，用于转头）。本类寻找后者。
/// - 扫描时记录广播的服务 UUID，即使设备无名称也能按服务识别。
/// - 自动连接只尝试「候选设备」，连上后验证服务，验证失败自动断开换下一个。
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

    /// 云台物理按键事件回调（来自 FF02 通知）：0=拍照 1=录像 2=放大 3=缩小 4=停止缩放 5=人脸跟踪切换
    var onButton: ((Int) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var allWriteChars: [CBCharacteristic] = []
    private var allNotifyChars: [CBCharacteristic] = []

    private var autoQueue: [CBPeripheral] = []      // 待尝试的候选
    private var autoIndex = 0
    private var connectTimer: Timer?
    private var verifiedService = false

    private let knownWrite = ["FF01", "FFE1", "FFF1", "02F00000-0000-0000-0000-00000000FF01",
                              "0000ff01-0000-1000-8000-00805f9b34fb"]
    private let knownNotify = ["FF02", "FFE2", "FFF2", "02F00000-0000-0000-0000-00000000FF02",
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
        default:
            stateText = "蓝牙不可用"
        }
    }

    // MARK: - 扫描
    func scan() {
        guard central.state == .poweredOn else { return }
        stateText = "扫描中…"
        clearConnectTimer()
        devices.removeAll()
        deviceRSSI.removeAll()
        deviceUUIDs.removeAll()
        autoQueue.removeAll()
        autoIndex = 0
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
            guard let self = self else { return }
            self.central.stopScan()
            if !self.connected { self.autoConnectGimbal() }
            self.refreshDiagnostics()
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
                let ac = isCandidate(a), bc = isCandidate(b)
                if ac != bc { return ac }
                return (deviceRSSI[a.identifier] ?? -100) > (deviceRSSI[b.identifier] ?? -100)
            }
        }
        refreshDiagnostics()
    }

    /// 候选优先级：名字像云台(3) > 广播了控制服务UUID(2) > 强信号的未命名设备(1) > 其他(0)
    private func candidateScore(_ p: CBPeripheral) -> Int {
        if isGimbalName(p.name ?? "") { return 3 }
        if let uuids = deviceUUIDs[p.identifier] {
            for u in uuids {
                let s = u.uppercased()
                if s.contains("FE00") || s.contains("02F00000")
                    || s.contains("FFE0") || s.contains("FFF0") { return 2 }
            }
        }
        // 无名称 + 信号较强：很可能是云台控制通道（不广播名字很常见）
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

    /// 自动连接：只对候选设备逐个尝试，连上验证服务失败则断开换下一个
    func autoConnectGimbal() {
        autoQueue = devices.filter { candidateScore($0) > 0 }
            .sorted { a, b in
                let sa = candidateScore(a), sb = candidateScore(b)
                if sa != sb { return sa > sb }
                return (deviceRSSI[a.identifier] ?? -100) > (deviceRSSI[b.identifier] ?? -100)
            }
        autoIndex = 0
        if autoQueue.isEmpty {
            stateText = "未发现云台 · 请确认云台已开机"
            addLog("扫描到的设备均非云台候选")
            refreshDiagnostics()
            return
        }
        addLog("候选 \(autoQueue.count) 个，开始尝试")
        tryNextCandidate()
    }

    private func tryNextCandidate() {
        guard autoIndex < autoQueue.count else {
            stateText = "候选均连接失败 · 需用 Gimbal Play 确认型号"
            addLog("所有候选设备均未发现控制服务")
            refreshDiagnostics()
            return
        }
        let p = autoQueue[autoIndex]
        autoIndex += 1
        connect(p)
    }

    // MARK: - 连接
    func connect(_ p: CBPeripheral) {
        clearConnectTimer()
        stateText = "连接中… \(p.name ?? "未命名")"
        lastConnectedName = p.name ?? "未命名设备"
        peripheral = p
        p.delegate = self
        central.connect(p, options: nil)
        // 连接+发现服务超时：8 秒没验证到就换下一个
        connectTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if !self.verifiedService {
                self.addLog("超时无控制服务，换下一个")
                self.central.cancelPeripheralConnection(p)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.tryNextCandidate() }
            }
        }
    }

    private func clearConnectTimer() {
        connectTimer?.invalidate()
        connectTimer = nil
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        stateText = "已连接 · 验证服务…"
        addLog("已连接 \(p.name ?? "未命名")")
        verifiedService = false
        allWriteChars.removeAll()
        allNotifyChars.removeAll()
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        clearConnectTimer()
        stateText = "连接失败 · 换下一个"
        addLog("连接失败: \(error?.localizedDescription ?? "未知")")
        tryNextCandidate()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        clearConnectTimer()
        if connected {
            connected = false
            stateText = "已断开 · 可重新扫描"
            addLog("已断开")
        }
    }

    // MARK: - 服务 / 特征发现
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = p.services else { return }
        addLog("发现 \(services.count) 个服务")
        let hasControl = services.contains { s in
            let u = s.uuid.uuidString.uppercased()
            return u.contains("FE00") || u.contains("02F00000")
        }
        if hasControl {
            verifiedService = true
            clearConnectTimer()
            stateText = "云台已连接 ✓"
            connected = true
            addLog("✓ 找到控制服务")
        } else {
            // 连上的不是云台控制通道，断开换下一个
            addLog("非云台控制服务，断开")
            refreshDiagnostics(services: services.map { $0.uuid.uuidString })
            central.cancelPeripheralConnection(p)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.tryNextCandidate()
            }
            return
        }
        for s in services { p.discoverCharacteristics(nil, for: s) }
        refreshDiagnostics(services: services.map { $0.uuid.uuidString })
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let chars = s.characteristics else { return }
        var lines = diagnostics.components(separatedBy: "\n")
        for ch in chars {
            lines.append("  └ \(ch.uuid.uuidString) [\(flags(ch))]")
            if ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse) {
                allWriteChars.append(ch)
            }
            if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                allNotifyChars.append(ch)
                p.setNotifyValue(true, for: ch)
            }
        }
        diagnostics = lines.joined(separator: "\n")
        pickCharacteristics()
    }

    private func flags(_ c: CBCharacteristic) -> String {
        var f = ""
        if c.properties.contains(.write) { f += "W" }
        if c.properties.contains(.writeWithoutResponse) { f += "WNR" }
        if c.properties.contains(.notify) { f += "N" }
        if c.properties.contains(.read) { f += "R" }
        return f.isEmpty ? "-" : f
    }

    private func rank(_ ch: CBCharacteristic, _ known: [String]) -> Int {
        let u = ch.uuid.uuidString.uppercased()
        for (i, k) in known.enumerated() where u == k || u.hasSuffix(k) { return 100 - i }
        return 0
    }

    private func pickCharacteristics() {
        guard let best = allWriteChars.sorted(by: { rank($0, knownWrite) > rank($1, knownWrite) }).first
        else { return }
        writeChar = best
        connected = true
        stateText = "云台已连接 ✓"
        addLog("控制通道: \(best.uuid.uuidString)")
        for ch in allNotifyChars.sorted(by: { rank($0, knownNotify) > rank($1, knownNotify) }) {
            peripheral?.setNotifyValue(true, for: ch)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let v = c.value else { return }
        let bytes = [UInt8](v)
        addLog("← " + GCProtocol.hex(bytes))
        parseButtonNotify(bytes)
    }

    /// 解析云台 FF02 通知里的物理按键事件。
    /// 逆向 Gimbal Play: 通知帧与下发同构 FF FF [lenH][lenL][ch][内层帧][crc]，
    /// 内层帧第 4 字节是命令码；按键事件命令码走 command 分发。
    /// l70 事件枚举值：TakePicture=2, TakeVideo=3, TakePictureOrVideo=4,
    /// ZoomIn=9, ZoomOut=10, ZoomIn2=11, ZoomOut2=12, StopZoom=13, FaceTraceToggle=17。
    private func parseButtonNotify(_ b: [UInt8]) {
        // 找到 FF FF 头
        var start = -1
        for i in 0..<max(0, b.count - 1) where b[i] == 0xFF && b[i+1] == 0xFF {
            start = i; break
        }
        let frame = start >= 0 ? Array(b[start...]) : b
        // 内层帧格式: 55 02 0B CMD n n [payload] checksum
        // 找到 0x55 起点
        var inner = -1
        for i in 0..<max(0, frame.count - 4) where frame[i] == 0x55 && frame[i+1] == 0x02 {
            inner = i; break
        }
        guard inner >= 0, inner + 4 < frame.count else { return }
        let cmd = frame[inner + 3]
        let payload: [UInt8] = inner + 6 <= frame.count - 1
            ? Array(frame[(inner+6)..<(frame.count-1)]) : []

        var event: Int? = nil
        switch cmd {
        case 0x22: // 开关/拍照类
            if let p0 = payload.first {
                switch p0 {
                case 2: event = 0       // TakePicture 拍照
                case 3: event = 1       // TakeVideo 录像
                case 4: event = 5       // 拍照或录像
                case 9: event = 2       // ZoomIn 放大
                case 10: event = 3      // ZoomOut 缩小
                case 11: event = 2      // 连续放大
                case 12: event = 3      // 连续缩小
                case 13: event = 4      // StopZoom
                case 17: event = 6      // FaceTraceToggle
                default: break
                }
            }
        case 0x31: // 模式变化
            if let p0 = payload.first {
                switch p0 {
                case 2: event = 0
                case 3: event = 1
                case 9: event = 2
                case 10: event = 3
                default: break
                }
            }
        default: break
        }
        if let e = event {
            let names = ["拍照", "录像", "放大", "缩小", "停止缩放", "拍照/录像", "人脸跟踪切换"]
            lastButtonEvent = names[e]
            addLog("★按键: \(names[e])")
            onButton?(e)
        }
    }

    // MARK: - 发指令
    private var lastWrite: TimeInterval = 0
    func send(_ data: [UInt8]) {
        guard connected, peripheral != nil, writeChar != nil else {
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
        if logs.count > 14 { logs.removeLast() }
    }

    private func refreshDiagnostics(services: [String]? = nil) {
        var lines: [String] = []
        lines.append("扫描到 \(devices.count) 个设备：")
        for p in devices { lines.append(deviceDetail(p)) }
        if let svcs = services {
            lines.append("已连接设备服务：")
            lines.append(contentsOf: svcs)
        }
        diagnostics = lines.joined(separator: "\n")
    }

    func disconnect() {
        clearConnectTimer()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        connected = false
    }
}
