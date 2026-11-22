import Foundation
import CoreBluetooth

/// CoreBluetooth 云台连接，兼容两套 UUID 变体
final class GCBLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    @Published var stateText = "初始化…"
    @Published var devices: [CBPeripheral] = []
    @Published var logs: [String] = []
    @Published var connected = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?

    private let serviceUUIDs = [
        CBUUID(string: "FE00"),
        CBUUID(string: "02F00000-0000-0000-0000-00000000FE00")
    ]
    private let writeUUIDs = [
        CBUUID(string: "FF01"),
        CBUUID(string: "02F00000-0000-0000-0000-00000000FF01")
    ]
    private let notifyUUIDs = [
        CBUUID(string: "FF02"),
        CBUUID(string: "02F00000-0000-0000-0000-00000000FF02")
    ]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            stateText = "就绪 · 扫描中…"
            scan()
        default:
            stateText = "蓝牙不可用"
        }
    }

    func scan() {
        guard central.state == .poweredOn else { return }
        stateText = "扫描中…"
        devices.removeAll()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.central.stopScan()
            self?.stateText = "扫描结束"
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if p.name != nil, !devices.contains(where: { $0.identifier == p.identifier }) {
            devices.append(p)
        }
    }

    func connect(_ p: CBPeripheral) {
        stateText = "连接中… \(p.name ?? "")"
        peripheral = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        stateText = "发现服务…"
        p.discoverServices(serviceUUIDs)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = p.services else { return }
        for s in services {
            // 判断是哪种 UUID 变体
            let variant = serviceUUIDs.firstIndex(of: s.uuid) ?? 0
            p.discoverCharacteristics(writeUUIDs + notifyUUIDs, for: s)
            objc_setAssociatedObject(s, "variant", variant as NSObject, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let chars = s.characteristics else { return }
        let variant = objc_getAssociatedObject(s, "variant") as? Int ?? 0
        for ch in chars {
            if ch.uuid == writeUUIDs[variant] {
                writeChar = ch
            } else if ch.uuid == notifyUUIDs[variant] {
                p.setNotifyValue(true, for: ch)
            }
        }
        if writeChar != nil {
            connected = true
            stateText = "已就绪 ✓"
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let v = c.value { addLog("← " + GCProtocol.hex([UInt8](v))) }
    }

    private var lastWrite: TimeInterval = 0
    func send(_ data: [UInt8]) {
        guard connected, let p = peripheral, let ch = writeChar else { return }
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
        p.writeValue(Data(data), for: ch, type: .withResponse)
        addLog("→ " + GCProtocol.hex(data))
    }

    private func addLog(_ s: String) {
        logs.insert(s, at: 0)
        if logs.count > 8 { logs.removeLast() }
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        connected = false
    }
}
