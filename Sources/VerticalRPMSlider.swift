import AppKit

// MARK: - Comparable clamp 유틸리티

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self {
        min(max(self, r.lowerBound), r.upperBound)
    }
}

// MARK: - 커스텀 수직 슬라이더 (완전 커스텀 드로잉)

final class VerticalRPMSlider: NSView {

    var minValue: Double = 1200
    var maxValue: Double = 6200
    var value: Double = 1200 {
        didSet { needsDisplay = true }
    }
    var isEnabled: Bool = true {
        didSet {
            needsDisplay = true
            alphaValue   = isEnabled ? 1.0 : 0.4
        }
    }
    var onChanged: ((Double) -> Void)?  // 드래그 중 (실시간 표시)
    var onCommit:  ((Double) -> Void)?  // 손 뗄 때 (SMC 적용)

    private let trackW:   CGFloat = 12
    private let knobSize: CGFloat = 20
    private let vPad:     CGFloat = 14

    // 비-플립: y=0이 하단 = 낮은 RPM
    override var isFlipped: Bool { false }

    // MARK: 드로잉

    override func draw(_ dirtyRect: NSRect) {
        let cx      = bounds.midX
        let trackH  = bounds.height - 2 * vPad
        let trackX  = cx - trackW / 2
        let trackY  = vPad
        let pct     = CGFloat((value - minValue) / (maxValue - minValue))
        let knobCY  = trackY + pct * trackH

        // 트랙 배경
        let bgRect  = NSRect(x: trackX, y: trackY, width: trackW, height: trackH)
        let bgPath  = NSBezierPath(roundedRect: bgRect, xRadius: trackW/2, yRadius: trackW/2)
        NSColor.quaternaryLabelColor.setFill()
        bgPath.fill()

        // 채워진 트랙 (하단→노브)
        let fillH = knobCY - trackY
        if fillH > 0 {
            let fillRect = NSRect(x: trackX, y: trackY, width: trackW, height: fillH)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: trackW/2, yRadius: trackW/2)
            trackColor(pct: Double(pct)).setFill()
            fillPath.fill()
        }

        // 노브 그림자 (약한 오프셋 원)
        let shadowRect = NSRect(
            x: cx - knobSize/2 + 0.5,
            y: knobCY - knobSize/2 - 1,
            width: knobSize, height: knobSize
        )
        NSColor.black.withAlphaComponent(0.15).setFill()
        NSBezierPath(ovalIn: shadowRect).fill()

        // 노브 본체
        let knobRect = NSRect(
            x: cx - knobSize/2,
            y: knobCY - knobSize/2,
            width: knobSize, height: knobSize
        )
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()

        // 노브 테두리
        let borderPath = NSBezierPath(ovalIn: knobRect.insetBy(dx: 0.5, dy: 0.5))
        borderPath.lineWidth = 0.5
        NSColor(white: 0, alpha: 0.12).setStroke()
        borderPath.stroke()
    }

    private func trackColor(pct: Double) -> NSColor {
        switch pct {
        case ..<0.5:
            return NSColor(calibratedRed: 0.10, green: 0.78, blue: 0.80, alpha: 1)
        case ..<0.8:
            let t = CGFloat((pct - 0.5) / 0.3)
            return NSColor(calibratedRed: 0.10 + t*0.90,
                           green:        0.78 - t*0.48,
                           blue:         0.80 - t*0.80, alpha: 1)
        default:
            let t = CGFloat((pct - 0.8) / 0.2)
            return NSColor(calibratedRed: 1.0,
                           green:        0.30 - t*0.18,
                           blue:         0.0, alpha: 1)
        }
    }

    // MARK: 마우스 처리

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        applyMouse(event); needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        applyMouse(event); needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        applyMouse(event)
        onCommit?(value)
    }

    private func applyMouse(_ event: NSEvent) {
        let pt    = convert(event.locationInWindow, from: nil)
        let trackH = bounds.height - 2 * vPad
        let pct   = Double((pt.y - vPad) / trackH).clamped(to: 0...1)
        // 1 RPM 단위 미세 조절
        value = (minValue + pct * (maxValue - minValue)).rounded()
        value = value.clamped(to: minValue...maxValue)
        onChanged?(value)
    }
}
