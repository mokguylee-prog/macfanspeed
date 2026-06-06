import AppKit

// MARK: - 프리셋 버튼 (아이콘 + 텍스트 완전 중앙 정렬)

private final class PresetButton: NSView {

    var isSelected = false { didSet { updateAppearance() } }
    var onTap: (() -> Void)?

    private let iconView  = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    init(sf: String, title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        iconView.image = NSImage(systemSymbolName: sf, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        titleLabel.stringValue = title
        titleLabel.font        = .systemFont(ofSize: 11)
        titleLabel.alignment   = .center
        addSubview(titleLabel)

        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError() }

    // 비-플립: y=0이 하단 → 수식이 직관적
    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        let w      = bounds.width
        let h      = bounds.height
        let iconH: CGFloat  = 15
        let titleH: CGFloat = 13
        let gap: CGFloat    = 3
        let total  = iconH + gap + titleH
        // 아이콘+텍스트 블록을 버튼 내에서 수직 중앙
        let baseY  = (h - total) / 2
        titleLabel.frame = NSRect(x: 2,           y: baseY,                  width: w-4,   height: titleH)
        iconView.frame   = NSRect(x: (w-iconH)/2, y: baseY + titleH + gap,   width: iconH, height: iconH)
    }

    private func updateAppearance() {
        let bg: NSColor = isSelected ? .controlAccentColor : NSColor(white: 0.5, alpha: 0.12)
        layer?.backgroundColor = bg.cgColor
        titleLabel.textColor       = isSelected ? .white : .labelColor
        iconView.contentTintColor  = isSelected ? .white : .secondaryLabelColor
    }

    override func mouseDown(with event: NSEvent) { /* 눌림 강조 생략 */ }
    override func mouseUp(with event: NSEvent)   { onTap?() }
}

// MARK: - 메뉴 팝오버 뷰

final class MenuView: NSView {

    var onControl:   ((_ auto: Bool, _ rpm: Int) -> Void)?
    var onAutoStart: ((Bool) -> Bool)?
    var onQuit:      (() -> Void)?
    var onAbout:     (() -> Void)?

    private let W: CGFloat = 280

    // 상수
    private let minRPM: Int
    private let maxRPM: Int

    // UI
    private let rpmBig    = NSTextField(labelWithString: "—")
    private let rpmUnit   = NSTextField(labelWithString: "RPM")
    private let curLabel  = NSTextField(labelWithString: "현재  —  RPM")
    private let tempLabel = NSTextField(labelWithString: "CPU  —°C")
    private let slider    = VerticalRPMSlider()
    private let autoToggle = NSSwitch()
    private var presetBtns: [PresetButton] = []
    private var isAutoMode = true

    static let version: String = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }()

    override var isFlipped: Bool { true }   // y=0이 상단

    init(minRPM: Int, maxRPM: Int, autoStartOn: Bool) {
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        super.init(frame: NSRect(x: 0, y: 0, width: W, height: 350))
        build(autoStartOn: autoStartOn)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 레이아웃 (상단부터 하단)

    private func build(autoStartOn: Bool) {
        let m: CGFloat = 16

        // ── 1. 프리셋 버튼 행 (아이콘+텍스트 완전 중앙)
        let sfIcons = ["wind", "tortoise.fill", "hare.fill", "flame.fill"]
        let titles  = ["자동", "조용히", "보통", "최대"]
        let bGap: CGFloat = 8
        let bW = (W - 2*m - bGap*3) / 4
        for i in 0..<4 {
            let b = PresetButton(sf: sfIcons[i], title: titles[i])
            b.frame = NSRect(x: m + CGFloat(i)*(bW+bGap), y: 10, width: bW, height: 52)
            b.onTap = { [weak self] in self?.presetTapped(i) }
            addSubview(b)
            presetBtns.append(b)
        }

        sep(y: 72)

        // ── 2. 제어 영역: 수직 슬라이더 + 대형 숫자
        slider.frame    = NSRect(x: m + 4, y: 84, width: 30, height: 155)
        slider.minValue = Double(minRPM)
        slider.maxValue = Double(maxRPM)
        slider.value    = Double(minRPM)
        slider.isEnabled = false
        slider.onChanged = { [weak self] rpm in self?.handleSlider(rpm: Int(rpm), commit: false) }
        slider.onCommit  = { [weak self] rpm in self?.handleSlider(rpm: Int(rpm), commit: true) }
        addSubview(slider)

        // 슬라이더 MAX/MIN 라벨
        let maxL = lbl("\(maxRPM)", 10, .tertiaryLabelColor); maxL.alignment = .center
        maxL.frame = NSRect(x: m - 2, y: 85, width: 32, height: 13)
        addSubview(maxL)

        let minL = lbl("\(minRPM)", 10, .tertiaryLabelColor); minL.alignment = .center
        minL.frame = NSRect(x: m - 2, y: 227, width: 32, height: 13)
        addSubview(minL)

        // 대형 RPM 숫자
        rpmBig.font  = NSFont.monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        rpmBig.frame = NSRect(x: 66, y: 100, width: 204, height: 44)
        addSubview(rpmBig)

        rpmUnit.font      = .systemFont(ofSize: 12)
        rpmUnit.textColor = .secondaryLabelColor
        rpmUnit.frame     = NSRect(x: 68, y: 146, width: 80, height: 16)
        addSubview(rpmUnit)

        curLabel.font      = .systemFont(ofSize: 12)
        curLabel.textColor = .secondaryLabelColor
        curLabel.frame     = NSRect(x: 66, y: 182, width: 204, height: 16)
        addSubview(curLabel)

        tempLabel.font      = .systemFont(ofSize: 12)
        tempLabel.textColor = .secondaryLabelColor
        tempLabel.frame     = NSRect(x: 66, y: 200, width: 204, height: 16)
        addSubview(tempLabel)

        sep(y: 252)

        // ── 3. 자동 시작 토글
        let togLbl = lbl("로그인 시 자동 시작", 13)
        togLbl.frame = NSRect(x: m, y: 266, width: 200, height: 20)
        addSubview(togLbl)

        autoToggle.state  = autoStartOn ? .on : .off
        autoToggle.target = self
        autoToggle.action = #selector(autoToggled(_:))
        autoToggle.frame  = NSRect(x: W - m - 38, y: 264, width: 38, height: 22)
        addSubview(autoToggle)

        sep(y: 302)

        // ── 4. 푸터
        let appBtn = NSButton(title: "FanSpeed  v0.2  \(Self.version)",
                              target: self, action: #selector(aboutTapped))
        appBtn.isBordered = false
        appBtn.font = .systemFont(ofSize: 12, weight: .medium)
        appBtn.contentTintColor = .secondaryLabelColor
        appBtn.frame = NSRect(x: m - 4, y: 314, width: 232, height: 22)
        appBtn.alignment = .left
        addSubview(appBtn)

        let quitBtn = NSButton(title: "종료", target: self, action: #selector(quitTapped))
        quitBtn.isBordered = false
        quitBtn.font = .systemFont(ofSize: 12)
        quitBtn.contentTintColor = .secondaryLabelColor
        quitBtn.frame = NSRect(x: W - m - 36, y: 314, width: 36, height: 22)
        quitBtn.alignment = .right
        addSubview(quitBtn)

        applyAutoUI()
    }

    // MARK: - 헬퍼

    private func sep(y: CGFloat) {
        let b = NSBox(frame: NSRect(x: 0, y: y, width: W, height: 1))
        b.boxType = .separator; addSubview(b)
    }

    private func lbl(_ text: String, _ size: CGFloat, _ color: NSColor = .labelColor) -> NSTextField {
        let t = NSTextField(labelWithString: text)
        t.font = .systemFont(ofSize: size); t.textColor = color
        return t
    }

    private func selectPreset(_ idx: Int) {
        presetBtns.enumerated().forEach { $0.element.isSelected = ($0.offset == idx) }
    }

    private func rpmColor(_ rpm: Int) -> NSColor {
        let p = Double(rpm - minRPM) / Double(maxRPM - minRPM)
        if p < 0.5 { return NSColor(calibratedRed: 0.10, green: 0.78, blue: 0.80, alpha: 1) }
        if p < 0.8 { return .systemOrange }
        return .systemRed
    }

    private func applyAutoUI() {
        isAutoMode = true
        selectPreset(0)
        slider.isEnabled    = false
        rpmBig.stringValue  = "AUTO"
        rpmBig.textColor    = .tertiaryLabelColor
        rpmUnit.stringValue = ""
    }

    private func applyManualUI(rpm: Int) {
        isAutoMode = false
        slider.isEnabled    = true
        slider.value        = Double(rpm)
        rpmBig.stringValue  = "\(rpm)"
        rpmBig.textColor    = rpmColor(rpm)
        rpmUnit.stringValue = "RPM"
    }

    // MARK: - 액션

    private func presetTapped(_ idx: Int) {
        let rpms = [0, max(minRPM, 2000), (minRPM + maxRPM)/2, maxRPM]
        selectPreset(idx)
        if idx == 0 { applyAutoUI(); onControl?(true, 0) }
        else        { let r = rpms[idx]; applyManualUI(rpm: r); onControl?(false, r) }
    }

    private func handleSlider(rpm: Int, commit: Bool) {
        rpmBig.stringValue  = "\(rpm)"
        rpmBig.textColor    = rpmColor(rpm)
        rpmUnit.stringValue = "RPM"
        selectPreset(-1)
        if commit { onControl?(false, rpm) }
    }

    @objc private func autoToggled(_ sender: NSSwitch) {
        let want = (sender.state == .on)
        if !(onAutoStart?(want) ?? false) { sender.state = want ? .off : .on }
    }

    @objc private func aboutTapped() { onAbout?() }
    @objc private func quitTapped()  { onQuit?() }

    // MARK: - 외부 갱신

    func updateReadout(currentRPM: Int, temp: Double?) {
        curLabel.stringValue = "현재  \(currentRPM)  RPM"
        if let t = temp {
            let warn = t >= 85 ? "  ⚠️" : ""
            tempLabel.stringValue = String(format: "CPU  %.0f°C%@", t, warn)
            tempLabel.textColor   = t >= 85 ? .systemOrange : .secondaryLabelColor
        }
        if !isAutoMode {
            let rpm = Int(slider.value)
            rpmBig.stringValue = "\(rpm)"
            rpmBig.textColor   = rpmColor(rpm)
        }
    }
}
