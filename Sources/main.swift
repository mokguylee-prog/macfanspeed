import AppKit

let args = CommandLine.arguments

// 읽기 전용 진단: GUI나 관리자 권한 없이 실제 센서 값을 확인한다.
if args.contains("--diagnose") {
    var requestedModel: MacModel?
    if let index = args.firstIndex(of: "--model") {
        guard args.indices.contains(index + 1), let model = MacModel(rawValue: args[index + 1]) else {
            FileHandle.standardError.write(Data("사용법: FanSpeed --diagnose [--model new|legacy]\n".utf8))
            exit(2)
        }
        requestedModel = model
    }
    let readout = FanManager.shared.readout(model: requestedModel)
    let smc = SMCKit.shared
    let fans: [[String: Any]] = readout.rpms.enumerated().map { index, rpm in
        ["fan": index + 1, "currentRPM": rpm.map { $0 as Any } ?? NSNull(),
         "minRPM": smc.fanMinRPM(fan: index).map { $0 as Any } ?? NSNull(),
         "maxRPM": smc.fanMaxRPM(fan: index).map { $0 as Any } ?? NSNull(),
         "dataType": smc.read("F\(index)Ac")?.typeName ?? "unavailable",
         "modeKey": smc.fanModeKey(fan: index) ?? "unavailable"]
    }
    let report: [String: Any] = [
        "detectedModel": MacModel.detected.rawValue, "selectedModel": readout.model.rawValue,
        "os": ProcessInfo.processInfo.operatingSystemVersionString, "smcOpen": smc.isOpen,
        "fanCount": readout.fanCount.map { $0 as Any } ?? NSNull(), "fans": fans,
        "cpuTemperature": readout.temperature.map { $0 as Any } ?? NSNull()
    ]
    if let json = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    exit(readout.fanCount == nil ? 1 : 0)
}

// 데몬 모드 (root, LaunchDaemon): GUI 없이 목표 파일 폴링
if args.contains("--daemon") {
    FanManager.runDaemon()  // 무한 루프, 반환 없음
}

// 1회 쓰기 모드 (root, osascript): SMC 직접 쓰기 후 종료
if let idx = args.firstIndex(of: "--smc-set") {
    exit(FanManager.runCLI(Array(args[idx...])))
}

// GUI 모드: 중복 실행 방지 (LaunchAgent + 수동 실행 겹침 차단)
let myExeName = (CommandLine.arguments[0] as NSString).lastPathComponent
let myPID = ProcessInfo.processInfo.processIdentifier
let duplicate = NSWorkspace.shared.runningApplications.contains { app in
    guard app.processIdentifier != myPID,
          let exe = app.executableURL?.lastPathComponent else { return false }
    return exe == myExeName
}
if duplicate {
    FileHandle.standardError.write(Data("FanSpeed가 이미 실행 중입니다. 종료합니다.\n".utf8))
    exit(0)
}

// GUI 모드: 메뉴바 앱
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
