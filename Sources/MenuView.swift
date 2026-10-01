import AppKit

// MARK: - 프리셋 버튼 (아이콘 + 텍스트 완전 중앙 정렬)

private final class PresetButton: NSView {

    var isSelected = false { didSet { updateAppearance() } }
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.4 } }
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
    override func mouseUp(with event: NSEvent)   { if isEnabled { onTap?() } }
}

// MARK: - 메뉴 팝오버 뷰

final class MenuView: NSView {

    var onControl:   ((_ auto: Bool, _ rpm: Int) -> Void)?
    var onAutoStart: ((Bool) -> Bool)?
    var onModelChange: ((MacModel) -> Bool)?
    var onQuit:      (() -> Void)?
    var onAbout:     (() -> Void)?

    private let W: CGFloat = 280

    // 상수
    private var minRPM: Int
    private var maxRPM: Int

    // UI
    private let rpmBig    = NSTextField(labelWithString: "—")
    private let rpmUnit   = NSTextField(labelWithString: "RPM")
    private let curLabel  = NSTextField(labelWithString: "현재  —  RPM")
    private let tempLabel = NSTextField(labelWithString: "CPU  —°C")
    private let slider    = VerticalRPMSlider()
    private let autoToggle = NSSwitch()
    private let modelToggle = NSSwitch()
    private let modelLabel = NSTextField(labelWithString: "")
    private let maxLabel = NSTextField(labelWithString: "")
    private let minLabel = NSTextField(labelWithString: "")
    private var presetBtns: [PresetButton] = []
    private var isAutoMode = true

    static let version: String = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }()

    override var isFlipped: Bool { true }   // y=0이 상단

    init(minRPM: Int, maxRPM: Int, autoStartOn: Bool, model: MacModel) {
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        super.init(frame: NSRect(x: 0, y: 0, width: W, height: 406))
        build(autoStartOn: autoStartOn, model: model)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 레이아웃 (상단부터 하단)

    private func build(autoStartOn: Bool, model: MacModel) {
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
        for label in [maxLabel, minLabel] {
            label.font = .systemFont(ofSize: 10)
            label.textColor = .tertiaryLabelColor
            label.alignment = .center
            addSubview(label)
        }
        maxLabel.stringValue = "\(maxRPM)"
        maxLabel.frame = NSRect(x: m - 4, y: 75, width: 40, height: 12)
        minLabel.stringValue = "\(minRPM)"
        minLabel.frame = NSRect(x: m - 4, y: 237, width: 40, height: 13)

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
        curLabel.maximumNumberOfLines = 2
        curLabel.frame     = NSRect(x: 66, y: 177, width: 204, height: 34)
        addSubview(curLabel)

        tempLabel.font      = .systemFont(ofSize: 12)
        tempLabel.textColor = .secondaryLabelColor
        tempLabel.frame     = NSRect(x: 66, y: 218, width: 204, height: 16)
        addSubview(tempLabel)

        sep(y: 252)

        // ── 3. 모델 선택: ON = Apple Silicon, OFF = Intel
        let modelTitle = lbl("New 모델", 13)
        modelTitle.frame = NSRect(x: m, y: 266, width: 200, height: 20)
        addSubview(modelTitle)
        modelLabel.font = .systemFont(ofSize: 11)
        modelLabel.textColor = .secondaryLabelColor
        modelLabel.frame = NSRect(x: m, y: 289, width: W - 2*m, height: 16)
        addSubview(modelLabel)
        modelToggle.state = model == .new ? .on : .off
        modelToggle.target = self
        modelToggle.action = #selector(modelToggled(_:))
        modelToggle.frame = NSRect(x: W - m - 38, y: 264, width: 38, height: 22)
        modelToggle.setAccessibilityLabel("New 모델 선택, 끄면 이전 Intel 모델")
        modelToggle.identifier = NSUserInterfaceItemIdentifier("modelToggle")
        addSubview(modelToggle)
        modelLabel.stringValue = model.title
        sep(y: 314)

        // ── 4. 자동 시작 토글
        let togLbl = lbl("로그인 시 자동 시작", 13)
        togLbl.frame = NSRect(x: m, y: 322, width: 200, height: 20)
        addSubview(togLbl)

        autoToggle.state  = autoStartOn ? .on : .off
        autoToggle.target = self
        autoToggle.action = #selector(autoToggled(_:))
        autoToggle.frame  = NSRect(x: W - m - 38, y: 320, width: 38, height: 22)
        addSubview(autoToggle)

        sep(y: 358)

        // ── 5. 푸터
        let appBtn = NSButton(title: "FanSpeed  v0.3  \(Self.version)",
                              target: self, action: #selector(aboutTapped))
        appBtn.isBordered = false
        appBtn.font = .systemFont(ofSize: 12, weight: .medium)
        appBtn.contentTintColor = .secondaryLabelColor
        appBtn.frame = NSRect(x: m - 4, y: 370, width: 232, height: 22)
        appBtn.alignment = .left
        addSubview(appBtn)

        let quitBtn = NSButton(title: "종료", target: self, action: #selector(quitTapped))
        quitBtn.isBordered = false
        quitBtn.font = .systemFont(ofSize: 12)
        quitBtn.contentTintColor = .secondaryLabelColor
        quitBtn.frame = NSRect(x: W - m - 36, y: 370, width: 36, height: 22)
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
        rpmBig.stringValue  = "—"
        rpmBig.textColor    = .tertiaryLabelColor
        rpmUnit.stringValue = "RPM · 자동"
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

    @objc private func modelToggled(_ sender: NSSwitch) {
        let selected: MacModel = sender.state == .on ? .new : .legacy
        guard onModelChange?(selected) ?? false else {
            sender.state = sender.state == .on ? .off : .on
            return
        }
        modelLabel.stringValue = selected.title
        resetControl()
        curLabel.stringValue = "팬 정보 확인 중…"
        tempLabel.stringValue = "CPU  —°C"
    }

    @objc private func aboutTapped() { onAbout?() }
    @objc private func quitTapped()  { onQuit?() }

    // MARK: - 외부 갱신

    func resetControl() { applyAutoUI() }

    func updateReadout(_ readout: FanReadout) {
        minRPM = readout.minRPM
        maxRPM = readout.maxRPM
        minLabel.stringValue = "\(minRPM)"
        maxLabel.stringValue = "\(maxRPM)"
        slider.minValue = Double(minRPM)
        slider.maxValue = Double(maxRPM)
        slider.value = slider.value.clamped(to: Double(minRPM)...Double(maxRPM))
        let available = readout.rpms.contains { $0 != nil }
        presetBtns.forEach { $0.isEnabled = available }
        slider.isEnabled = available && !isAutoMode
        curLabel.stringValue = readout.fanText
        curLabel.toolTip = readout.fanText
        if let t = readout.temperature {
            let warn = t >= 85 ? "  ⚠️" : ""
            let title = readout.model == .new ? "CPU 평균" : "CPU"
            tempLabel.stringValue = String(format: "%@  %.0f°C%@", title, t, warn)
            tempLabel.textColor   = t >= 85 ? .systemOrange : .secondaryLabelColor
        } else {
            tempLabel.stringValue = "CPU  읽기 불가"
            tempLabel.textColor = .secondaryLabelColor
        }
        if isAutoMode {
            let rpm = readout.rpms.first.flatMap { $0 }
            rpmBig.stringValue = rpm.map(String.init) ?? "—"
            rpmBig.textColor = rpm.map(rpmColor) ?? .tertiaryLabelColor
            rpmUnit.stringValue = "RPM · 자동"
        } else {
            let rpm = Int(slider.value)
            rpmBig.stringValue = "\(rpm)"
            rpmBig.textColor   = rpmColor(rpm)
        }
    }
}
