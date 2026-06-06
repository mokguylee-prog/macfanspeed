import AppKit

let args = CommandLine.arguments

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
