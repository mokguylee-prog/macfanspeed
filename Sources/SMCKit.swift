import Foundation
import IOKit
import Darwin

enum MacModel: String, CaseIterable {
    case new
    case legacy

    static var detected: MacModel {
        // 실제 하드웨어를 확인하므로 Rosetta로 실행해도 Apple Silicon을 인식한다.
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0 && arm64 == 1
            ? .new : .legacy
    }

    var title: String { self == .new ? "New 모델 · Apple Silicon" : "이전 모델 · Intel" }
}

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

    var typeName: String {
        String(bytes: (0..<4).map { UInt8((dataType >> (8 * (3 - $0))) & 0xff) },
               encoding: .ascii) ?? ""
    }

    // SMC 키의 실제 타입을 사용한다. 0은 팬 정지 상태일 수 있으므로 유효한 값이다.
    var number: Double? {
        guard bytes.count == Int(dataSize) else { return nil }
        let value: Double
        switch (typeName, bytes.count) {
        case ("flt ", 4):
            let bits = bytes.enumerated().reduce(UInt32(0)) {
                $0 | (UInt32($1.element) << ($1.offset * 8))
            }
            value = Double(Float(bitPattern: bits))
        case ("fpe2", 2):
            value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case ("sp78", 2):
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            value = Double(Int16(bitPattern: raw)) / 256
        case ("ui8 ", 1), ("ui16", 2), ("ui32", 4):
            value = Double(bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        default:
            return nil
        }
        return value.isFinite ? value : nil
    }

    func encoding(_ value: Double) -> [UInt8]? {
        guard value.isFinite, value >= 0 else { return nil }
        switch (typeName, dataSize) {
        case ("flt ", 4):
            let float = Float(value)
            guard float.isFinite else { return nil }
            let bits = float.bitPattern
            return (0..<4).map { UInt8((bits >> ($0 * 8)) & 0xff) }
        case ("fpe2", 2):
            guard value <= Double(UInt16.max) / 4 else { return nil }
            let raw = UInt16((value * 4).rounded())
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case ("ui8 ", 1):
            guard value <= 255, value.rounded() == value else { return nil }
            return [UInt8(value)]
        default:
            return nil
        }
    }
}

// MARK: - SMCKit

final class SMCKit {
    static let shared = SMCKit()
    private var conn: io_connect_t = 0
    private(set) var isOpen = false
    private let lock = NSRecursiveLock()
    private var cachedKeys: [String]?
    private var cpuKeys: [String]?

    private init() { open() }
    deinit { close() }

    private func open() {
        let port: mach_port_t
        if #available(macOS 12.0, *) { port = kIOMainPortDefault }
        else { port = kIOMasterPortDefault }
        let svc = IOServiceGetMatchingService(port, IOServiceMatching("AppleSMC"))
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
        lock.lock(); defer { lock.unlock() }
        guard isOpen else { return nil }
        var input = SMCKeyData()
        var output = SMCKeyData()

        input.key = fourCC(key)
        input.data8 = SMC_CMD_READ_KEYINFO
        guard call(&input, &output) == kIOReturnSuccess else { return nil }
        // result != 0 또는 dataSize == 0 이면 키 없음
        guard output.result == 0, (1...32).contains(output.keyInfo.dataSize) else { return nil }

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
        lock.lock(); defer { lock.unlock() }
        guard isOpen else { return false }
        var input = SMCKeyData()
        var output = SMCKeyData()

        input.key = fourCC(key)
        input.data8 = SMC_CMD_READ_KEYINFO
        guard call(&input, &output) == kIOReturnSuccess, output.result == 0,
              (1...32).contains(output.keyInfo.dataSize),
              bytes.count == Int(output.keyInfo.dataSize) else { return false }

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

    private func rpm(_ key: String) -> Int? {
        guard let value = read(key)?.number, (0...30000).contains(value) else { return nil }
        return Int(value.rounded())
    }

    func fanCount() -> Int? {
        guard let value = read("FNum")?.number,
              (0...16).contains(value), value.rounded() == value else { return nil }
        return Int(value)
    }

    func fanCurrentRPM(fan: Int) -> Int? { rpm("F\(fan)Ac") }
    func fanMinRPM(fan: Int) -> Int?     { rpm("F\(fan)Mn") }
    func fanMaxRPM(fan: Int) -> Int?     { rpm("F\(fan)Mx") }
    func fanTargetRPM(fan: Int) -> Int?  { rpm("F\(fan)Tg") }

    func allKeys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        if let keys = cachedKeys { return keys }
        guard let count = read("#KEY")?.number, count > 0, count <= 16384 else { return [] }
        let keys: [String] = (0..<Int(count)).compactMap { index in
            var input = SMCKeyData()
            var output = SMCKeyData()
            input.data8 = 8  // SMC_CMD_READ_INDEX
            input.data32 = UInt32(index)
            guard call(&input, &output) == kIOReturnSuccess, output.result == 0 else { return nil }
            let bytes = (0..<4).map { UInt8((output.key >> (8 * (3 - $0))) & 0xff) }
            return String(bytes: bytes, encoding: .ascii)
        }
        cachedKeys = keys
        return keys
    }

    func cpuTemperature(model: MacModel) -> Double? {
        lock.lock(); defer { lock.unlock() }
        if model == .new {
            if cpuKeys == nil {
                cpuKeys = allKeys().filter { key in
                    // M1/M2/M4/M5: Tp/Te. M3의 Tf 센서는 CPU와 GPU를 구분한다.
                    let m3CPU = ["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                                 "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
                    return key.hasPrefix("Tp") || key.hasPrefix("Te") || m3CPU.contains(key)
                }.sorted()
            }
            let temperatures = (cpuKeys ?? []).compactMap { read($0)?.number }
                .filter { $0 > 0 && $0 < 150 }
            if !temperatures.isEmpty {
                return temperatures.reduce(0, +) / Double(temperatures.count)
            }
        }
        for key in ["TC0P", "TC0E", "TC0D", "TCXC", "TC0F"] {
            if let value = read(key)?.number, value > 0, value < 150 { return value }
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

    /// 키 타입에 맞춰 팬 목표 RPM을 쓴다 (Intel fpe2 / Apple Silicon flt).
    @discardableResult
    func setFanTarget(fan: Int, rpm: Int) -> Bool {
        writeNumber("F\(fan)Tg", value: Double(rpm))
    }

    private func writeNumber(_ key: String, value: Double) -> Bool {
        guard let info = read(key), let bytes = info.encoding(value) else { return false }
        return write(key, bytes: bytes)
    }

    func fanModeKey(fan: Int) -> String? {
        ["F\(fan)md", "F\(fan)Md"].first { read($0)?.typeName == "ui8 " }
    }

    @discardableResult
    func applyControl(model: MacModel, auto: Bool, rpm: Int = 0) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let count = fanCount(), count > 0 else { return false }
        var success = true

        if model == .legacy {
            let mask = auto ? UInt16(0) : UInt16((UInt32(1) << count) - 1)
            guard setManualMask(mask) else { return false }
        } else {
            for fan in 0..<count {
                guard let key = fanModeKey(fan: fan),
                      writeNumber(key, value: auto ? 0 : 1) else {
                    if !auto {
                        _ = applyControl(model: model, auto: true)
                        return false
                    }
                    // 자동 복귀는 한 팬이 실패해도 나머지 팬까지 모두 시도한다.
                    success = false
                    continue
                }
            }
        }

        for fan in 0..<count {
            // 각 팬의 실제 범위로 제한한다. 좌우 팬의 최대 RPM이 다를 수 있다.
            let minimum = fanMinRPM(fan: fan) ?? 1200
            let maximum = fanMaxRPM(fan: fan) ?? 6200
            let target = auto ? 0 : min(max(rpm, minimum), maximum)
            // Intel 자동 모드는 FS! 만 초기화한다.
            if auto && model == .legacy { continue }
            guard setFanTarget(fan: fan, rpm: target) else {
                if !auto {
                    _ = applyControl(model: model, auto: true)
                    return false
                }
                success = false
                continue
            }
        }
        return success
    }
}
