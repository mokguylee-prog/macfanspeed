import Foundation
import AppKit

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

    private(set) var fanCount: Int = 0
    private(set) var minRPM: Int = 1200
    private(set) var maxRPM: Int = 6200

    private init() {
        fanCount = smc.fanCount()
        if fanCount == 0, smc.fanCurrentRPM(fan: 0) != nil { fanCount = 1 }
        if let mn = smc.fanMinRPM(fan: 0), mn > 0 { minRPM = mn }
        if let mx = smc.fanMaxRPM(fan: 0), mx > 0 { maxRPM = mx }
    }

    // MARK: - 모니터링

    func currentRPM() -> Int  { smc.fanCurrentRPM(fan: 0) ?? 0 }
    func cpuTemp() -> Double? { smc.cpuTemperature() }

    // MARK: - 데몬 상태

    var daemonInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.daemonPlist)
    }

    // MARK: - 제어 (슬라이더·프리셋 공통)

    /// 데몬 설치 시: 파일 IPC (즉각, 비밀번호 없음)
    /// 미설치 시: osascript 1회 (비밀번호 입력)
    @discardableResult
    func commit(auto: Bool, rpm: Int) -> Bool {
        let payload = auto ? "auto" : "\(rpm)"
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
                    return true
                } catch { return false }
            }
            // 파일이 없으면 새로 생성 시도 (root 소유가 아닐 때만 가능)
            return FileManager.default.createFile(atPath: Self.targetFile, contents: data)
        }
        // 데몬 미설치 → 1회 권한 상승
        let arg = auto ? "auto" : "manual \(rpm)"
        return runAdmin("'\(absoluteSelfPath)' --smc-set \(arg)")
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
</dict>
</plist>
"""
        let plistEscaped = plist.replacingOccurrences(of: "'", with: "'\\''")
        let shell = """
        cp '\(src)' '\(Self.helperBin)' && \
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
        let smc   = SMCKit.shared
        guard smc.isOpen else { return 1 }
        let count = max(smc.fanCount(), 1)
        let mask  = UInt16((1 << count) - 1)
        guard args.count >= 2 else { return 2 }

        if args[1] == "auto" {
            _ = smc.setManualMask(0)
            return 0
        }
        if args[1] == "manual", args.count >= 3, let rpm = Int(args[2]) {
            _ = smc.setManualMask(mask)
            for f in 0..<count { _ = smc.setFanTarget(fan: f, rpm: rpm) }
            return 0
        }
        return 2
    }

    /// --daemon   (root, LaunchDaemon, 무한 루프)
    static func runDaemon() -> Never {
        let smc   = SMCKit.shared
        let count = max(smc.fanCount(), 1)
        let mask  = UInt16((1 << count) - 1)
        var last  = ""
        while true {
            let raw = (try? String(contentsOfFile: targetFile, encoding: .utf8)) ?? "auto"
            let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if cmd != last {
                if cmd == "auto" || cmd.isEmpty {
                    _ = smc.setManualMask(0)
                } else if let rpm = Int(cmd) {
                    _ = smc.setManualMask(mask)
                    for f in 0..<count { _ = smc.setFanTarget(fan: f, rpm: rpm) }
                }
                last = cmd
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }
}
