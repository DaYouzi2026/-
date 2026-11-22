import Foundation
import CoreBluetooth

/// CoreBluetooth 云台连接。
/// 改进：扫描全部设备（含无名称的），按信号排序；连接后发现「全部」服务与特征，
/// 自动挑选可写特征作为控制通道，并把发现结果暴露给界面做诊断。
final class GCBLEManager: NSObject, ObservableObject,
                          CBCentralManagerDelegate, CBPeripheralDelegate {

    @Published var stateText = "初始化…"
    @Published var devices: [CBPeripheral] = []
    @Published var deviceRSSI: [UUID: Int] = [:]
    @Published var logs: [String] = []
    @Published var connected = false
    @Published var diagnostics = ""          // 发现到的服务/特征，供排查
    @Published var lastConnectedName = ""

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var allWriteChars: [CBCharacteristic] = []
    private var allNotifyChars: [CBCharacteristic] = []
    private var autoConnectAttempted = false

    /// 已知写特征优先级（命中则用，否则退回任意可写特征）
    private let knownWrite = ["FF01", "FFE1", "FFF1", "02F00000-0000-0000-0000-00000000FF01"]
    private let knownNotify = ["FF02", "FFE2", "FFF2", "02F00000-0000-0000-0000-00000000FF02"]

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
        devices.removeAll()
        deviceRSSI.removeAll()
        autoConnectAttempted = false
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
            guard let self = self else { return }
            self.central.stopScan()
            if !self.connected {
                self.stateText = "扫描结束 · 点设备连接"
                self.autoConnectGimbal()
            }
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        deviceRSSI[p.identifier] = RSSI.intValue
        if !devices.contains(where: { $0.identifier == p.identifier }) {
            devices.append(p)
            // 按顺序排序：云台名优先，其次信号强
            devices.sort { a, b in
                let ag = isGimbalName(a.name ?? "")
                let bg = isGimbalName(b.name ?? "")
                if ag != bg { return ag }
                return (deviceRSSI[a.identifier] ?? -100) > (deviceRSSI[b.identifier] ?? -100)
            }
        }
    }

    private func isGimbalName(_ n: String) -> Bool {
        let s = n.lowercased()
        return s.contains("gimbal") || s.contains("云台") || s.contains("netviv")
            || s.contains("jy-") || s.contains("stabilizer")
    }

    func deviceLabel(_ p: CBPeripheral) -> String {
        let name = p.name ?? "未命名设备"
        let r = deviceRSSI[p.identifier].map { "\($0)dBm" } ?? "?"
        let tag = isGimbalName(name) ? " ★云台" : ""
        return "\(name)  \(r)\(tag)"
    }

    /// 自动连接信号最强的云台设备
    func autoConnectGimbal() {
        guard !autoConnectAttempted else { return }
        autoConnectAttempted = true
        let gimbals = devices.filter { isGimbalName($0.name ?? "") }
        let target = (gimbals.isEmpty ? devices : gimbals)
            .max { (deviceRSSI[$0.identifier] ?? -100) < (deviceRSSI[$1.identifier] ?? -100) }
        if let p = target {
            addLog("自动连接: \(p.name ?? "未命名")")
            connect(p)
        }
    }

    // MARK: - 连接
    func connect(_ p: CBPeripheral) {
        stateText = "连接中… \(p.name ?? "未命名")"
        lastConnectedName = p.name ?? "未命名设备"
        peripheral = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        stateText = "已连接 · 发现服务…"
        addLog("已连接 \(p.name ?? "")")
        allWriteChars.removeAll()
        allNotifyChars.removeAll()
        diagnostics = "发现服务中…"
        // 关键：不再限定 UUID，发现全部服务，避免不同固件 UUID 不一致导致读不到
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        stateText = "连接失败（设备可能已被系统占用为HID）"
        addLog("连接失败: \(error?.localizedDescription ?? "未知")")
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        connected = false
        stateText = "已断开 · 可重新扫描"
        addLog("已断开")
    }

    // MARK: - 服务 / 特征发现
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = p.services else {
            diagnostics = "未发现任何服务（该设备可能只有 HID 拍照功能，无 GATT 控制通道）"
            stateText = "设备无控制服务"
            return
        }
        var lines: [String] = []
        if services.isEmpty {
            lines.append("未发现任何服务")
        }
        for s in services {
            lines.append("服务 \(s.uuid.uuidString)")
            p.discoverCharacteristics(nil, for: s)
        }
        diagnostics = lines.joined(separator: "\n")
        addLog("发现 \(services.count) 个服务")
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
        stateText = "已就绪 ✓"
        addLog("控制通道: \(best.uuid.uuidString)")
        for ch in allNotifyChars.sorted(by: { rank($0, knownNotify) > rank($1, knownNotify) }) {
            peripheral?.setNotifyValue(true, for: ch)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let v = c.value { addLog("← " + GCProtocol.hex([UInt8](v))) }
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
        if logs.count > 10 { logs.removeLast() }
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        connected = false
    }
}
