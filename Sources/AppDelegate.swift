import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var menuView: MenuView!
    private var timer: Timer?
    private let fan = FanManager.shared

    static let version: String = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }()

    func applicationDidFinishLaunching(_ n: Notification) {
        setupStatusItem()
        setupPopover()
        scheduleTimer()
        // 자동 시작은 사용자가 토글로 명시 활성화할 때만 등록 (강제 등록 X)
        // 데몬 미설치 → 0.8초 후 최초 설정 안내
        if !fan.daemonInstalled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.promptDaemonInstall()
            }
        }
    }

    // MARK: - StatusItem (메뉴바 아이콘 + RPM)

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = makeFanIcon()
            // 파란색 아이콘이므로 template 미사용 (template = 흑백 전환)
            btn.image?.isTemplate = false
            btn.imagePosition = .imageLeft
            btn.title = "  — RPM"
            btn.font  = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            btn.target = self
            btn.action = #selector(togglePopover(_:))
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    // Core Graphics로 파란색 팬 아이콘 생성
    private func makeFanIcon() -> NSImage {
        let size: CGFloat = 16
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()

        guard let ctx = NSGraphicsContext.current?.cgContext else {
            img.unlockFocus(); return img
        }
        ctx.translateBy(x: size/2, y: size/2)

        let blue = NSColor.systemBlue.cgColor

        // 중심 허브
        ctx.setFillColor(blue)
        ctx.fillEllipse(in: CGRect(x: -2, y: -2, width: 4, height: 4))

        // 3개의 팬 블레이드 (120° 간격)
        for i in 0..<3 {
            ctx.saveGState()
            ctx.rotate(by: CGFloat(i) * 2 * .pi / 3)
            let path = CGMutablePath()
            path.move(to: .zero)
            path.addCurve(to: CGPoint(x:  6, y:  2.5),
                          control1: CGPoint(x:  2.5, y:  0.8),
                          control2: CGPoint(x:  4.5, y:  3.2))
            path.addCurve(to: CGPoint(x:  3.5, y:  6),
                          control1: CGPoint(x:  7,   y:  4.5),
                          control2: CGPoint(x:  5.2, y:  6.2))
            path.addCurve(to: .zero,
                          control1: CGPoint(x:  1.8, y:  6),
                          control2: CGPoint(x:  0.8, y:  2.5))
            path.closeSubpath()
            ctx.setFillColor(blue)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()
        }
        img.unlockFocus()
        return img
    }

    // MARK: - Popover (애니메이션 없이 즉시 표시)

    private func setupPopover() {
        let mn = fan.fanMinRPM ?? 1200
        let mx = fan.fanMaxRPM ?? 6200
        menuView = MenuView(minRPM: mn, maxRPM: mx, autoStartOn: fan.autoStartEnabled)

        menuView.onControl   = { [weak self] auto, rpm in self?.applyControl(auto: auto, rpm: rpm) }
        menuView.onAutoStart = { [weak self] on in self?.fan.setAutoStart(on) ?? false }
        menuView.onAbout     = { [weak self] in self?.showAbout() }
        menuView.onQuit      = { [weak self] in self?.safeQuit() }

        let vc = NSViewController()
        vc.view = menuView

        popover = NSPopover()
        popover.contentViewController = vc
        popover.contentSize = menuView.frame.size
        popover.behavior    = .transient
        popover.animates    = false   // ← 즉시 표시 (애니메이션 제거)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - 데몬 설치 (최초 1회 안내)

    private func promptDaemonInstall() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "FanSpeed 최초 설정"
        a.informativeText = """
        팬 속도를 비밀번호 없이 즉시 조절하려면
        백그라운드 도우미를 한 번만 설치해야 합니다.

        macOS 비밀번호를 한 번 입력하면
        이후 모든 조작이 즉시 반영됩니다.
        """
        a.addButton(withTitle: "설치 (1회)")
        a.addButton(withTitle: "나중에")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let ok = fan.installDaemon()
        NSApp.activate(ignoringOtherApps: true)
        let b = NSAlert()
        b.messageText      = ok ? "설치 완료 ✓" : "설치 취소"
        b.informativeText  = ok
            ? "이제 비밀번호 없이 즉시 팬 속도를 조절할 수 있습니다."
            : "나중에 팬 속도를 변경할 때 비밀번호를 요청합니다."
        b.addButton(withTitle: "확인")
        b.runModal()
    }

    // MARK: - 팬 제어

    private func applyControl(auto: Bool, rpm: Int) {
        let ok = fan.commit(auto: auto, rpm: rpm)
        if !ok && !auto {
            DispatchQueue.main.async { [weak self] in self?.showControlError() }
        }
    }

    private func showControlError() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "팬 속도 설정"
        a.informativeText = """
        관리자 권한이 필요합니다.
        비밀번호를 입력하거나 데몬을 설치하면
        이후엔 비밀번호 없이 제어됩니다.
        """
        a.alertStyle = .informational
        a.addButton(withTitle: "데몬 설치 (1회만)")
        a.addButton(withTitle: "나중에")
        if a.runModal() == .alertFirstButtonReturn { promptDaemonInstall() }
    }

    // MARK: - 타이머 (백그라운드 SMC 읽기 → 메인 UI 업데이트)

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshReadout()
        }
        timer?.tolerance = 1
        refreshReadout()
    }

    private func refreshReadout() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let rpm  = self.fan.currentRPM()
            let temp = self.fan.cpuTemp()
            DispatchQueue.main.async {
                self.menuView?.updateReadout(currentRPM: rpm, temp: temp)
                // 메뉴바: 아이콘 + RPM + 온도
                let tempStr = temp.map { String(format: "%.0f°C", $0) } ?? "--"
                self.statusItem.button?.title = "  \(rpm)  \(tempStr)"
                self.statusItem.button?.toolTip = "\(rpm) RPM · \(tempStr)"
            }
        }
    }

    // MARK: - About

    private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "FanSpeed"
        a.informativeText = """
        macOS 팬 속도 제어 메뉴바 앱

        만든이: 월평동 이상목
        버전: v0.2  (\(Self.version))
        """
        a.alertStyle = .informational
        a.addButton(withTitle: "확인")
        a.runModal()
    }

    // MARK: - 종료

    private func safeQuit() {
        fan.commit(auto: true, rpm: 0)
        NSApp.terminate(nil)
    }
}

// MARK: - FanManager 편의 확장

extension FanManager {
    var fanMinRPM: Int? { minRPM > 0 ? minRPM : nil }
    var fanMaxRPM: Int? { maxRPM > 0 ? maxRPM : nil }
}
