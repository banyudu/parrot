import AppKit
import QuartzCore

private let kPanelH: CGFloat = 34
private let kPanelW: CGFloat = 120
private let kTextPanelH: CGFloat = 28
private let kTextMaxW: CGFloat = 500
private let kTextPadding: CGFloat = 12
private let kTextGap: CGFloat = 6
private let kBarCount = 12
private let kBarWidth: CGFloat = 3
private let kBarGap: CGFloat = 3
private let kBarMaxH: CGFloat = 24
private let kBarMinH: CGFloat = 4
private let kIdleH: CGFloat = 6

final class OverlayPanel {
    private let panel: NSPanel
    private let container: NSView
    private let waveView: WaveBarView
    private let dotView: DotView
    private var animTimer: Timer?
    private var dismissTimer: Timer?

    private let textPanel: NSPanel
    private let textContainer: NSView
    private let textLabel: NSTextField

    var audioLevel: Float = 0
    private var anchorRect: CGRect?

    init() {
        let barsW = CGFloat(kBarCount) * kBarWidth + CGFloat(kBarCount - 1) * kBarGap

        let screen = NSScreen.main?.frame ?? .zero
        let x = (screen.width - kPanelW) / 2
        let y = screen.height * 0.10

        panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: kPanelW, height: kPanelH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating + 1
        panel.isOpaque = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0

        container = NSView(frame: NSRect(x: 0, y: 0, width: kPanelW, height: kPanelH))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.92).cgColor
        container.layer?.cornerRadius = kPanelH / 2
        container.layer?.masksToBounds = true
        panel.contentView = container

        let barsX = (kPanelW - barsW) / 2
        let barsY = (kPanelH - kBarMaxH) / 2
        waveView = WaveBarView(frame: NSRect(x: barsX, y: barsY, width: barsW, height: kBarMaxH))
        waveView.isHidden = true
        container.addSubview(waveView)

        let dotSize: CGFloat = 7
        dotView = DotView(frame: NSRect(
            x: (kPanelW - dotSize) / 2,
            y: (kPanelH - dotSize) / 2,
            width: dotSize,
            height: dotSize
        ))
        dotView.isHidden = true
        container.addSubview(dotView)

        let screen2 = NSScreen.main?.frame ?? .zero
        let textY = screen2.height * 0.10 + kPanelH + kTextGap
        textPanel = NSPanel(
            contentRect: NSRect(x: 0, y: textY, width: kTextMaxW, height: kTextPanelH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        textPanel.level = .floating + 1
        textPanel.isOpaque = false
        textPanel.hasShadow = true
        textPanel.backgroundColor = .clear
        textPanel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        textPanel.ignoresMouseEvents = true
        textPanel.alphaValue = 0

        textContainer = NSView(frame: NSRect(x: 0, y: 0, width: kTextMaxW, height: kTextPanelH))
        textContainer.wantsLayer = true
        textContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        textContainer.layer?.cornerRadius = kTextPanelH / 2
        textContainer.layer?.masksToBounds = true
        textPanel.contentView = textContainer

        textLabel = NSTextField(labelWithString: "")
        textLabel.font = .systemFont(ofSize: 13, weight: .medium)
        textLabel.textColor = .white
        textLabel.alignment = .center
        textLabel.lineBreakMode = .byTruncatingHead
        textLabel.maximumNumberOfLines = 1
        textLabel.frame = NSRect(x: kTextPadding, y: 0, width: kTextMaxW - kTextPadding * 2, height: kTextPanelH)
        textContainer.addSubview(textLabel)
    }

    // MARK: - Anchor

    func setAnchor(_ rect: CGRect?) {
        anchorRect = rect
        repositionPanels()
    }

    private func repositionPanels() {
        let screen = NSScreen.main?.frame ?? .zero

        let centerX: CGFloat
        let baseY: CGFloat

        if let anchor = anchorRect {
            centerX = anchor.midX
            baseY = anchor.minY - kPanelH - 8
        } else {
            centerX = screen.width / 2
            baseY = screen.height * 0.10
        }

        let panelX = max(0, min(centerX - kPanelW / 2, screen.width - kPanelW))
        let clampedY = max(8, min(baseY, screen.height - kPanelH - kTextPanelH - kTextGap - 8))

        var pf = panel.frame
        pf.origin = NSPoint(x: panelX, y: clampedY)
        panel.setFrame(pf, display: false)

        var tf = textPanel.frame
        tf.origin.y = clampedY + kPanelH + kTextGap
        textPanel.setFrame(tf, display: false)
    }

    // MARK: - Public

    func showRecording() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        stopPulse()
        dotView.isHidden = true
        waveView.isHidden = false

        panel.alphaValue = 1
        panel.orderFrontRegardless()
        startWaveAnimation()
    }

    func showProcessing() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        stopWaveAnimation()
        waveView.isHidden = true
        dotView.isHidden = false
        dotView.color = .white
        startPulse()
    }

    func showDone() {
        stopWaveAnimation()
        stopPulse()
        waveView.isHidden = true
        dotView.isHidden = true

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    func showError() {
        stopWaveAnimation()
        stopPulse()
        waveView.isHidden = true
        dotView.isHidden = false
        dotView.color = .systemRed
        dotView.layer?.removeAnimation(forKey: "pulse")
        dotView.layer?.opacity = 1.0

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    func updateText(_ confirmed: String, provisional: String) {
        let full = (confirmed + provisional).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else {
            textPanel.orderOut(nil)
            textPanel.alphaValue = 0
            return
        }

        textLabel.stringValue = full

        let attrStr = NSAttributedString(string: full, attributes: [.font: textLabel.font!])
        let textWidth = min(attrStr.size().width + kTextPadding * 2 + 4, kTextMaxW)
        let screen = NSScreen.main?.frame ?? .zero
        let anchorCenterX = anchorRect?.midX ?? screen.width / 2
        let newX = max(0, min(anchorCenterX - textWidth / 2, screen.width - textWidth))
        var frame = textPanel.frame
        frame.origin.x = newX
        frame.size.width = textWidth
        textPanel.setFrame(frame, display: false)
        textContainer.frame = NSRect(x: 0, y: 0, width: textWidth, height: kTextPanelH)
        textLabel.frame = NSRect(x: kTextPadding, y: 0, width: textWidth - kTextPadding * 2, height: kTextPanelH)

        textPanel.alphaValue = 1
        textPanel.orderFrontRegardless()
    }

    func hideText() {
        textPanel.orderOut(nil)
        textPanel.alphaValue = 0
        textLabel.stringValue = ""
    }

    func hide() {
        stopWaveAnimation()
        stopPulse()
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel.orderOut(nil)
        panel.alphaValue = 0
        hideText()
    }

    // MARK: - Internals

    private func startPulse() {
        stopPulse()
        dotView.wantsLayer = true
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.25
        anim.duration = 0.6
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dotView.layer?.add(anim, forKey: "pulse")
    }

    private func stopPulse() {
        dotView.layer?.removeAnimation(forKey: "pulse")
        dotView.layer?.opacity = 1.0
    }

    private func startWaveAnimation() {
        stopWaveAnimation()
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.waveView.audioLevel = self.audioLevel
            self.waveView.tick()
        }
    }

    private func stopWaveAnimation() {
        animTimer?.invalidate()
        animTimer = nil
    }
}

// MARK: - WaveBarView

private final class WaveBarView: NSView {
    private var phases: [Double] = (0..<kBarCount).map { _ in Double.random(in: 0...(.pi * 2)) }
    private var time: Double = 0
    var audioLevel: Float = 0

    func tick() {
        time += 0.07
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let raw = Double(min(audioLevel / 0.04, 1.0))
        let level = sqrt(raw)
        let dynamicMax = kIdleH + CGFloat(level) * (kBarMaxH - kIdleH)

        for i in 0..<kBarCount {
            let freq = 1.6 + Double(i) * 0.4
            let norm = (sin(time * freq + phases[i]) + 1) / 2
            let h = kBarMinH + CGFloat(norm) * (dynamicMax - kBarMinH)
            let x = CGFloat(i) * (kBarWidth + kBarGap)
            let y = (bounds.height - h) / 2

            let rect = NSRect(x: x, y: y, width: kBarWidth, height: h)
            let path = NSBezierPath(roundedRect: rect, xRadius: kBarWidth / 2, yRadius: kBarWidth / 2)

            let alpha = 0.7 + 0.3 * CGFloat(norm)
            NSColor.white.withAlphaComponent(alpha).setFill()
            path.fill()
        }
    }
}

// MARK: - DotView

private final class DotView: NSView {
    var color: NSColor = .white { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
