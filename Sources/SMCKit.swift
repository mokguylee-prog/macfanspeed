import Foundation
import IOKit

// MARK: - SMC C 구조체 (C 레이아웃과 정확히 일치해야 함, 총 80바이트)

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

// C에서 이 구조체는 4바이트 정렬로 12바이트가 됨 (dataAttributes 뒤 3바이트 패딩).
// 패딩을 명시하지 않으면 Swift는 9바이트로 만들어 전체 구조체가 어긋나 모든 읽기가 0이 됨.
private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    var _pad1: UInt8 = 0
    var _pad2: UInt8 = 0
    var _pad3: UInt8 = 0
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

private let KERNEL_INDEX_SMC: UInt32 = 2
private let SMC_CMD_READ_KEYINFO: UInt8 = 9
private let SMC_CMD_READ_BYTES: UInt8   = 5
private let SMC_CMD_WRITE_BYTES: UInt8  = 6

struct SMCVal {
    var dataSize: UInt32
    var dataType: UInt32
    var bytes: [UInt8]
}

// MARK: - SMCKit

final class SMCKit {
    static let shared = SMCKit()
    private var conn: io_connect_t = 0
    private(set) var isOpen = false

    private init() { open() }
    deinit { close() }

    private func open() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return }
        let r = IOServiceOpen(svc, mach_task_self_, 0, &conn)
        IOObjectRelease(svc)
        isOpen = (r == kIOReturnSuccess)
    }

    private func close() {
        if conn != 0 { IOServiceClose(conn) }
    }

    private func fourCC(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for (i, c) in s.utf8.prefix(4).enumerated() {
            r |= UInt32(c) << UInt32(8 * (3 - i))
        }
        return r
    }

    private func call(_ input: inout SMCKeyData, _ output: inout SMCKeyData) -> kern_return_t {
        let size = MemoryLayout<SMCKeyData>.size
        var outSize = size
        return withUnsafeMutablePointer(to: &input) { ip in
            withUnsafeMutablePointer(to: &output) { op in
                IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, ip, size, op, &outSize)
            }
        }
    }

    // MARK: 읽기

    func read(_ key: String) -> SMCVal? {
        guard isOpen else { return nil }
        var input = SMCKeyData()
        var output = SMCKeyData()

        input.key = fourCC(key)
        input.data8 = SMC_CMD_READ_KEYINFO
        guard call(&input, &output) == kIOReturnSuccess else { return nil }
        // result != 0 또는 dataSize == 0 이면 키 없음
        guard output.result == 0, output.keyInfo.dataSize > 0 else { return nil }

        let size = output.keyInfo.dataSize
        let type = output.keyInfo.dataType

        input.keyInfo.dataSize = size
        input.data8 = SMC_CMD_READ_BYTES
        guard call(&input, &output) == kIOReturnSuccess, output.result == 0 else { return nil }

        var arr = [UInt8]()
        withUnsafeBytes(of: output.bytes) { raw in
            for i in 0..<Int(min(size, 32)) { arr.append(raw[i]) }
        }
        return SMCVal(dataSize: size, dataType: type, bytes: arr)
    }

    // MARK: 쓰기 (root 권한 필요)

    @discardableResult
    func write(_ key: String, bytes: [UInt8]) -> Bool {
        guard isOpen else { return false }
        var input = SMCKeyData()
        var output = SMCKeyData()

        input.key = fourCC(key)
        input.data8 = SMC_CMD_READ_KEYINFO
        guard call(&input, &output) == kIOReturnSuccess, output.result == 0,
              output.keyInfo.dataSize > 0 else { return false }

        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.keyInfo.dataType = output.keyInfo.dataType
        input.data8 = SMC_CMD_WRITE_BYTES
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for (i, b) in bytes.prefix(Int(output.keyInfo.dataSize)).enumerated() {
                raw[i] = b
            }
        }
        let r = call(&input, &output)
        return r == kIOReturnSuccess && output.result == 0
    }

    // MARK: 고수준 API

    /// fpe2(2비트 소수 고정소수점) 값 → 정수 RPM
    private func fpe2(_ v: SMCVal?) -> Int? {
        guard let v = v, v.bytes.count >= 2 else { return nil }
        let raw = UInt16(v.bytes[0]) << 8 | UInt16(v.bytes[1])
        return Int(raw) >> 2
    }

    func fanCount() -> Int {
        guard let v = read("FNum"), let first = v.bytes.first else { return 0 }
        return Int(first)
    }

    func fanCurrentRPM(fan: Int) -> Int? { fpe2(read("F\(fan)Ac")) }
    func fanMinRPM(fan: Int) -> Int?     { fpe2(read("F\(fan)Mn")) }
    func fanMaxRPM(fan: Int) -> Int?     { fpe2(read("F\(fan)Mx")) }
    func fanTargetRPM(fan: Int) -> Int?  { fpe2(read("F\(fan)Tg")) }

    /// sp78(8비트 소수) 온도. 여러 센서 키를 시도해 합리적 값 반환.
    func cpuTemperature() -> Double? {
        for key in ["TC0P", "TC0E", "TC0D", "TCXC", "TC0F"] {
            if let v = read(key), v.bytes.count >= 2 {
                let t = Double(Int(v.bytes[0])) + Double(Int(v.bytes[1])) / 256.0
                if t > 0 && t < 150 { return t }
            }
        }
        return nil
    }

    // MARK: 팬 제어 (FS! 비트마스크 + FxTg 타겟)

    /// 수동 모드 비트마스크 쓰기. mask의 각 비트가 해당 팬을 수동 제어로 전환.
    @discardableResult
    func setManualMask(_ mask: UInt16) -> Bool {
        let hi = UInt8((mask >> 8) & 0xFF)
        let lo = UInt8(mask & 0xFF)
        return write("FS! ", bytes: [hi, lo])
    }

    /// 팬 목표 RPM 쓰기 (fpe2 = rpm * 4)
    @discardableResult
    func setFanTarget(fan: Int, rpm: Int) -> Bool {
        let raw = rpm * 4
        let hi = UInt8((raw >> 8) & 0xFF)
        let lo = UInt8(raw & 0xFF)
        return write("F\(fan)Tg", bytes: [hi, lo])
    }
}
