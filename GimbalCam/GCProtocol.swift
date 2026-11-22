import Foundation

/// 勤蓝/Netviv 云台 BLE 协议（逆向自 Gimbal Play v2.5.57）
/// 内层: 55 02 type cmd n n [params] [累加校验]
/// 外层: FF FF [lenHi][lenLo][channel][inner][CRC8]
enum GCProtocol {

    // 真机可调变体
    static var channel: UInt8 = 3
    static var innerChecksum = true
    static var outerCrc = true

    static let CMD_YAW_PITCH: UInt8 = 0x23
    static let CMD_TARGET: UInt8 = 0x11
    static let CMD_TOGGLE: UInt8 = 0x22
    static let CMD_SETTING: UInt8 = 0x25
    static let CMD_MODE: UInt8 = 0x31

    /// 内层累加校验：从第2字节起到末尾求和取低8位
    private static func innerCheck(_ f: [UInt8]) -> UInt8 {
        var sum = 0
        for i in 1..<f.count { sum += Int(f[i]) }
        return UInt8(sum & 0xFF)
    }

    /// CRC-8/MAXIM 多项式反射 0x8D, 初值 0
    static func crc8(_ data: [UInt8], _ len: Int) -> UInt8 {
        var crc: UInt8 = 0
        for i in 0..<len {
            crc ^= data[i]
            for _ in 0..<8 {
                crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x8D : crc << 1
            }
        }
        return crc
    }

    private static func innerFrame(type: UInt8, cmd: UInt8, params: [UInt8]) -> [UInt8] {
        var b: [UInt8] = [0x55, type, 0x0B, cmd, UInt8(params.count), UInt8(params.count)]
        b += params
        if innerChecksum { b.append(innerCheck(b)) }
        return b
    }

    static func wrap(_ inner: [UInt8]) -> [UInt8] {
        let coreLen = inner.count + 1
        var core: [UInt8] = [UInt8((coreLen >> 8) & 0xFF), UInt8(coreLen & 0xFF), channel]
        core += inner
        let check: UInt8 = outerCrc ? crc8(core, core.count)
            : core.reduce(0) { UInt8(truncatingIfNeeded: Int($0) + Int($1)) }
        return [0xFF, 0xFF] + core + [check]
    }

    static func yawPitch(_ yaw: Int, _ pitch: Int) -> [UInt8] {
        let y = Int16(clamping: max(-1000, min(1000, yaw)))
        let p = Int16(clamping: max(-1000, min(1000, pitch)))
        var params: [UInt8] = []
        params += [UInt8(truncatingIfNeeded: y), UInt8(truncatingIfNeeded: y >> 8)]
        params += [UInt8(truncatingIfNeeded: p), UInt8(truncatingIfNeeded: p >> 8)]
        params.append(0)
        return wrap(innerFrame(type: 0x02, cmd: CMD_YAW_PITCH, params: params))
    }

    static func setting(_ sub: Int, _ value: Int) -> [UInt8] {
        wrap(innerFrame(type: 0x02, cmd: CMD_SETTING, params: [UInt8(sub), UInt8(value)]))
    }

    static func toggle(_ on: Bool) -> [UInt8] {
        wrap(innerFrame(type: 0x02, cmd: CMD_TOGGLE, params: [on ? 1 : 0]))
    }

    static func hex(_ b: [UInt8]) -> String {
        b.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
