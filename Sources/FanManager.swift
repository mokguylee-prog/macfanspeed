import Foundation
import AppKit

struct FanReadout {
    let model: MacModel
    let fanCount: Int?
    let rpms: [Int?]
    let temperature: Double?
    let minRPM: Int
    let maxRPM: Int

    var rpmText: String {
        if fanCount == 0 { return "팬 없음" }
        return rpms.isEmpty ? "—" : rpms.map { $0.map(String.init) ?? "—" }.joined(separator: "/")
    }

    var fanText: String {
        if fanCount == 0 { return "냉각 팬이 없는 모델" }
        if rpms.isEmpty { return "팬 정보를 읽을 수 없음" }
        return rpms.enumerated().map { index, rpm in
            "팬 \(index + 1)  \(rpm.map { "\($0) RPM" } ?? "읽기 불가")"
        }.joined(separator: "\n")
    }
}

struct FanCommand: Equatable {
    let model: MacModel
    let rpm: Int?

    init(model: MacModel, rpm: Int?) {
        self.model = model
        self.rpm = rpm
    }

    init?(payload: String) {
        let parts = payload.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let action: String
        if parts.count == 2, let model = MacModel(rawValue: parts[0]) {
            self.model = model
            action = parts[1]
        } else if parts.count == 1 {
            // 이전 GUI의 "auto" / "2000" 명령도 처리한다.
            model = .detected
            action = parts[0]
        } else { return nil }
        if action == "auto" { rpm = nil }
        else if let value = Int(action), (0...30000).contains(value) { rpm = value }
        else { return nil }
    }

    var payload: String { "\(model.rawValue) \(rpm.map(String.init) ?? "auto")" }
}

final class FanManager {
    static let shared = FanManager()
    private let smc = SMCKit.shared

    // 경로
    static let targetFile  = "/Users/Shared/.fanspeed_target"
    static let helperBin   = "/usr/local/bin/fanspeed-helper"
    static let daemonPlist = "/Library/LaunchDaemons/com.fanspeed.helper.plist"
    static let daemonLabel = "com.fanspeed.helper"
    static let agentLabel  = "com.fanspeed.app"
    static var agentPlist: String {
        NSHomeDirectory() + "/Library/LaunchAgents/com.fanspeed.app.plist"
    }

    private let lock = NSRecursiveLock()
    private let preferences = UserDefaults(suiteName: "com.fanspeed.app")!
    private(set) var model: MacModel = .detected
    private(set) var fanCount: Int?
    private(set) var minRPM: Int = 1200
    private(set) var maxRPM: Int = 6200
    private(set) var hasIssuedControl = false

    private init() {
        if let saved = preferences.string(forKey: "macModel"), let value = MacModel(rawValue: saved) {
            model = value
        }
        refreshFanInfo()
    }

    private func refreshFanInfo() {
        fanCount = smc.fanCount()
        if fanCount == nil, smc.fanCurrentRPM(fan: 0) != nil { fanCount = 1 }
        let fans = 0..<(fanCount ?? 0)
        minRPM = fans.compactMap { smc.fanMinRPM(fan: $0) }.max() ?? 1200
        maxRPM = fans.compactMap { smc.fanMaxRPM(fan: $0) }.max() ?? 6200
        if maxRPM <= minRPM { minRPM = 1200; maxRPM = 6200 }
    }

    // MARK: - 모니터링

    func readout(model override: MacModel? = nil) -> FanReadout {
        lock.lock(); defer { lock.unlock() }
        let selected = override ?? model
        return FanReadout(model: selected, fanCount: fanCount,
                          rpms: (0..<(fanCount ?? 0)).map { smc.fanCurrentRPM(fan: $0) },
                          temperature: smc.cpuTemperature(model: selected),
                          minRPM: minRPM, maxRPM: maxRPM)
    }

    @discardableResult
    func selectModel(_ selected: MacModel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard selected != model else { return true }
        // 수동 제어 중에 모델을 바꾸면 기존 방식으로 먼저 자동 제어에 복귀한다.
        if hasIssuedControl && !commit(auto: true, rpm: 0) { return false }
        model = selected
        preferences.set(selected.rawValue, forKey: "macModel")
        refreshFanInfo()
        return true
    }

    // MARK: - 데몬 상태

    var daemonInstalled: Bool {
        guard let data = FileManager.default.contents(atPath: Self.daemonPlist),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil))
                as? [String: Any] else { return false }
        return plist["FanSpeedIPCVersion"] as? Int == 2
    }

    var daemonNeedsUpdate: Bool {
        FileManager.default.fileExists(atPath: Self.daemonPlist) && !daemonInstalled
    }

    // MARK: - 제어 (슬라이더·프리셋 공통)

    /// 데몬 설치 시: 파일 IPC (즉각, 비밀번호 없음)
    /// 미설치 시: osascript 1회 (비밀번호 입력)
    @discardableResult
    func commit(auto: Bool, rpm: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let count = fanCount, count > 0 else { return false }
        let target = min(max(rpm, minRPM), maxRPM)
        let payload = FanCommand(model: model, rpm: auto ? nil : target).payload
        if daemonInstalled {
            // ⚠️ atomically:true 는 임시파일+rename 으로 동작 →
            // /Users/Shared/ 는 sticky 디렉토리(drwxrwxrwt)이고
            // 타겟 파일 소유자는 root 라서 일반 사용자는 rename 덮어쓰기 불가 (EPERM).
            // 따라서 in-place 직접 쓰기(atomically:false) 사용.
            guard let data = payload.data(using: .utf8) else { return false }
            if let fh = FileHandle(forWritingAtPath: Self.targetFile) {
                defer { try? fh.close() }
                do {
                    try fh.truncate(atOffset: 0)
                    try fh.write(contentsOf: data)
                    hasIssuedControl = !auto
                    return true
                } catch { return false }
            }
            // 파일이 없으면 새로 생성 시도 (root 소유가 아닐 때만 가능)
            let ok = FileManager.default.createFile(atPath: Self.targetFile, contents: data)
            if ok { hasIssuedControl = !auto }
            return ok
        }
        // 데몬 미설치 → 1회 권한 상승
        let arg = auto ? "auto" : "manual \(target)"
        let ok = runAdmin("'\(absoluteSelfPath)' --smc-set \(arg) --model \(model.rawValue)")
        if ok { hasIssuedControl = !auto }
        return ok
    }

    // MARK: - 데몬 설치 / 제거

    @discardableResult
    func installDaemon() -> Bool {
        let src = absoluteSelfPath
        let plist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>\(Self.daemonLabel)</string>
  <key>ProgramArguments</key>
  <array><string>\(Self.helperBin)</string><string>--daemon</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>FanSpeedIPCVersion</key><integer>2</integer>
</dict>
</plist>
"""
        let plistEscaped = plist.replacingOccurrences(of: "'", with: "'\\''")
        let shell = """
        mkdir -p /usr/local/bin && cp '\(src)' '\(Self.helperBin)' && \
        chmod 755 '\(Self.helperBin)' && \
        printf '%s' '\(plistEscaped)' > '\(Self.daemonPlist)' && \
        chown root:wheel '\(Self.daemonPlist)' && chmod 644 '\(Self.daemonPlist)' && \
        touch '\(Self.targetFile)' && chmod 666 '\(Self.targetFile)' && \
        launchctl unload '\(Self.daemonPlist)' 2>/dev/null; \
        launchctl load -w '\(Self.daemonPlist)'
        """
        return runAdmin(shell)
    }

    @discardableResult
    func uninstallDaemon() -> Bool {
        let shell = """
        launchctl unload '\(Self.daemonPlist)' 2>/dev/null; \
        rm -f '\(Self.daemonPlist)' '\(Self.helperBin)'
        """
        return runAdmin(shell)
    }

    // MARK: - 자동 시작 (LaunchAgent, 권한 불필요)

    var autoStartEnabled: Bool {
        FileManager.default.fileExists(atPath: Self.agentPlist)
    }

    @discardableResult
    func setAutoStart(_ on: Bool) -> Bool {
        let dir = (Self.agentPlist as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if on {
            let plist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>\(Self.agentLabel)</string>
  <key>ProgramArguments</key><array><string>\(absoluteSelfPath)</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
"""
            do {
                try plist.write(toFile: Self.agentPlist, atomically: true, encoding: .utf8)
                launchctl(["load", "-w", Self.agentPlist])
                return true
            } catch { return false }
        } else {
            launchctl(["unload", "-w", Self.agentPlist])
            try? FileManager.default.removeItem(atPath: Self.agentPlist)
            return true
        }
    }

    // MARK: - 내부 도우미

    private var absoluteSelfPath: String {
        let p = CommandLine.arguments[0]
        let raw = p.hasPrefix("/")
            ? p
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(p)
        return URL(fileURLWithPath: raw).standardized.path
    }

    @discardableResult
    private func runAdmin(_ shell: String) -> Bool {
        // shell 내 특수문자 이스케이프 (\ → \\, " → \")
        let esc = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let src = "do shell script \"\(esc)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let n = err?["NSAppleScriptErrorNumber"] as? Int, n == -128 { return false } // 취소
        return err == nil
    }

    @discardableResult
    private func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.launchPath = "/bin/launchctl"
        p.arguments  = args
        p.launch(); p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: - CLI 진입점

    /// --smc-set auto | --smc-set manual <RPM>   (root, osascript 경유)
    static func runCLI(_ args: [String]) -> Int32 {
        guard args.count >= 2 else { return 2 }
        let model: MacModel
        if let index = args.firstIndex(of: "--model") {
            guard args.indices.contains(index + 1),
                  let selected = MacModel(rawValue: args[index + 1]) else { return 2 }
            model = selected
        } else { model = .detected }
        if args[1] == "auto" {
            return SMCKit.shared.applyControl(model: model, auto: true) ? 0 : 1
        }
        if args[1] == "manual", args.count >= 3,
           let rpm = Int(args[2]), (0...30000).contains(rpm) {
            return SMCKit.shared.applyControl(model: model, auto: false, rpm: rpm) ? 0 : 1
        }
        return 2
    }

    /// --daemon   (root, LaunchDaemon, 무한 루프)
    static func runDaemon() -> Never {
        let smc   = SMCKit.shared
        var lastApplied: FanCommand?
        var lastError: String?
        while true {
            let raw = (try? String(contentsOfFile: targetFile, encoding: .utf8)) ?? "auto"
            // in-place IPC 쓰기 도중의 빈 파일과 잘못된 명령은 무시한다.
            if let command = FanCommand(payload: raw), command != lastApplied {
                let restored: Bool
                if let previous = lastApplied, previous.model != command.model, previous.rpm != nil {
                    restored = smc.applyControl(model: previous.model, auto: true)
                } else { restored = true }
                if restored && smc.applyControl(model: command.model,
                                               auto: command.rpm == nil, rpm: command.rpm ?? 0) {
                    lastApplied = command
                    lastError = nil
                } else if lastError != command.payload {
                    FileHandle.standardError.write(Data("FanSpeed: 제어 실패 (\(command.payload))\n".utf8))
                    lastError = command.payload
                }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }
}
