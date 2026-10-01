import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var menuView: MenuView!
    private var timer: Timer?
    private let fan = FanManager.shared
    private let sensorQueue = DispatchQueue(label: "com.fanspeed.sensors", qos: .utility)
    private var didOfferHelper = false
    // NSAlert에 직접 꽂아줄 큰 사이즈 팬 아이콘 (한번만 생성해 재사용)
    private lazy var appIcon: NSImage = makeFanIcon(size: 256)

    static let version: String = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }()

    func applicationDidFinishLaunching(_ n: Notification) {
        // 앱 아이콘 설정 (NSAlert 자동 사용 + Cmd-Tab 등)
        NSApp.applicationIconImage = appIcon
        // Finder 에서 보이는 실행파일 아이콘도 팬 아이콘으로 설정
        // (단일 실행파일은 기본 'exec' 아이콘으로 표시됨)
        if let exePath = Bundle.main.executablePath {
            NSWorkspace.shared.setIcon(makeFanIcon(size: 512), forFile: exePath, options: [])
        }
        setupStatusItem()
        setupPopover()
        scheduleTimer()
        // 자동 시작은 사용자가 토글로 명시 활성화할 때만 등록 (강제 등록 X)
        // 읽기만 할 때는 데몬이나 관리자 권한이 필요하지 않다.
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

    // Core Graphics로 파란색 팬 아이콘 생성 (메뉴바·앱 아이콘 공용)
    // size: 출력 픽셀 크기. 내부 path는 16pt 기준으로 그려두고 CGContext 스케일로 확대.
    private func makeFanIcon(size: CGFloat = 16) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()

        guard let ctx = NSGraphicsContext.current?.cgContext else {
            img.unlockFocus(); return img
        }
        // 16pt 기준 path → 실제 크기로 균일 스케일
        let s = size / 16.0
        ctx.translateBy(x: size/2, y: size/2)
        ctx.scaleBy(x: s, y: s)

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
        menuView = MenuView(minRPM: fan.minRPM, maxRPM: fan.maxRPM,
                            autoStartOn: fan.autoStartEnabled, model: fan.model)

        menuView.onControl   = { [weak self] auto, rpm in self?.applyControl(auto: auto, rpm: rpm) }
        menuView.onAutoStart = { [weak self] on in self?.fan.setAutoStart(on) ?? false }
        menuView.onModelChange = { [weak self] model in
            guard let self else { return false }
            guard self.fan.selectModel(model) else { self.showControlError(); return false }
            self.refreshReadout()
            return true
        }
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
        a.icon = appIcon
        a.messageText = fan.daemonNeedsUpdate ? "FanSpeed 도우미 업데이트" : "FanSpeed 최초 설정"
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
        b.icon = appIcon
        b.messageText      = ok ? "설치 완료 ✓" : "설치 취소"
        b.informativeText  = ok
            ? "이제 비밀번호 없이 즉시 팬 속도를 조절할 수 있습니다."
            : "나중에 팬 속도를 변경할 때 비밀번호를 요청합니다."
        b.addButton(withTitle: "확인")
        b.runModal()
    }

    // MARK: - 팬 제어

    private func applyControl(auto: Bool, rpm: Int) {
        if !auto && !fan.daemonInstalled && !didOfferHelper {
            didOfferHelper = true
            promptDaemonInstall()
        }
        let ok = fan.commit(auto: auto, rpm: rpm)
        if !ok {
            menuView.resetControl()
            DispatchQueue.main.async { [weak self] in self?.showControlError() }
        }
        refreshReadout()
    }

    private func showControlError() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.icon = appIcon
        a.messageText = "팬 속도를 적용하지 못했습니다"
        a.informativeText = """
        선택한 모델: \(fan.model.title)

        모델 선택과 관리자 권한을 확인해 주세요.
        macOS 또는 펌웨어가 수동 제어를 허용하지 않을 수도 있습니다.
        팬 속도와 온도 표시는 도우미 없이 사용할 수 있습니다.
        """
        a.alertStyle = .informational
        a.addButton(withTitle: fan.daemonNeedsUpdate ? "도우미 업데이트" : "도우미 설치")
        a.addButton(withTitle: "나중에")
        if a.runModal() == .alertFirstButtonReturn { promptDaemonInstall() }
    }

    // MARK: - 타이머 (백그라운드 SMC 읽기 → 메인 UI 업데이트)

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshReadout()
        }
        timer?.tolerance = 0.4
        refreshReadout()
    }

    private func refreshReadout() {
        sensorQueue.async { [weak self] in
            guard let self else { return }
            let readout = self.fan.readout()
            DispatchQueue.main.async {
                guard readout.model == self.fan.model else { return }
                self.menuView?.updateReadout(readout)
                let tempStr = readout.temperature.map { String(format: "%.0f°C", $0) } ?? "—°C"
                let rpmStr = readout.fanCount == 0 ? readout.rpmText : "\(readout.rpmText) RPM"
                self.statusItem.button?.title = "  \(rpmStr)  \(tempStr)"
                self.statusItem.button?.toolTip = "\(readout.model.title)\n\(readout.fanText)\nCPU \(tempStr)"
            }
        }
    }

    // MARK: - About

    private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.icon = appIcon
        a.messageText = "FanSpeed"
        a.informativeText = """
        macOS 팬 속도 제어 메뉴바 앱

        만든이: 월평동 이상목
        버전: v0.3  (\(Self.version))
        """
        a.alertStyle = .informational
        a.addButton(withTitle: "확인")
        a.runModal()
    }

    // MARK: - 종료

    private func safeQuit() {
        if fan.hasIssuedControl { fan.commit(auto: true, rpm: 0) }
        NSApp.terminate(nil)
    }
}
