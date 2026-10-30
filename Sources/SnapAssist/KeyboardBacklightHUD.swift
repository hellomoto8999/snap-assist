import AppKit

/// HUD in stile macOS per la retroilluminazione della tastiera: una pillola
/// scura in alto a destra con icona e barra a segmenti, come quella della
/// luminosità del display.
final class KeyboardBacklightHUD {
    static let shared = KeyboardBacklightHUD()

    private let size = NSSize(width: 360, height: 62)
    private var panel: NSPanel?
    private var content: HUDContentView?
    private var hideWorkItem: DispatchWorkItem?

    func show(level: Float) {
        let level = min(max(level, 0), 1)
        let panel = ensurePanel()
        content?.level = level

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let screen {
            // In alto a destra, appena sotto la barra dei menu.
            let frame = NSRect(
                x: screen.frame.maxX - size.width - 20,
                y: screen.visibleFrame.maxY - size.height - 12,
                width: size.width,
                height: size.height
            )
            if panel.frame != frame {
                panel.setFrame(frame, display: true)
            }
        }

        hideWorkItem?.cancel()

        if !panel.isVisible || panel.alphaValue < 0.05 {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.08
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
        }

        let item = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: item)
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
        // Se l'animazione non arriva (stessa cautela del pannello di scelta).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if panel.alphaValue < 0.05 {
                panel.orderOut(nil)
            }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = size.height / 2
        effect.layer?.masksToBounds = true

        let content = HUDContentView(frame: NSRect(origin: .zero, size: size))
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        panel.contentView = effect

        self.panel = panel
        self.content = content
        return panel
    }
}

/// Pillola con icona e barra a segmenti, come l'HUD della luminosità di macOS.
final class HUDContentView: NSView {
    var level: Float = 0 {
        didSet { needsDisplay = true }
    }

    private let iconView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "Keyboard backlight")
        iconView.image = image
        iconView.contentTintColor = NSColor.white.withAlphaComponent(0.96)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let iconSide: CGFloat = 24
        iconView.frame = NSRect(
            x: 23 - iconSide / 2,
            y: bounds.midY - iconSide / 2,
            width: iconSide,
            height: iconSide
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        // Disco appena più chiaro dietro l'icona.
        let disc = NSRect(x: 23 - 21, y: bounds.midY - 21, width: 42, height: 42)
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSBezierPath(ovalIn: disc).fill()

        let count = 16
        let left: CGFloat = 64
        let right: CGFloat = bounds.width - 20
        let gap: CGFloat = 3
        let blockWidth = (right - left - gap * CGFloat(count - 1)) / CGFloat(count)
        let blockHeight: CGFloat = 12
        let y = bounds.midY - blockHeight / 2

        let filled = Int((CGFloat(min(max(level, 0), 1)) * CGFloat(count)).rounded())

        for index in 0..<count {
            let rect = NSRect(
                x: left + CGFloat(index) * (blockWidth + gap),
                y: y,
                width: blockWidth,
                height: blockHeight
            )
            let color = index < filled
                ? NSColor.white.withAlphaComponent(0.96)
                : NSColor.white.withAlphaComponent(0.16)
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5).fill()
        }
    }
}
