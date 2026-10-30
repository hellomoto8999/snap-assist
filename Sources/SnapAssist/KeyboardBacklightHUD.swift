import AppKit

/// Piccolo HUD in stile macOS: icona tastiera e barra del livello.
final class KeyboardBacklightHUD {
    static let shared = KeyboardBacklightHUD()

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
            let frame = NSRect(
                x: screen.visibleFrame.midX - 120,
                y: screen.visibleFrame.minY + 90,
                width: 240,
                height: 80
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
                context.duration = 0.1
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
        }

        let item = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: item)
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
        // Se l'animazione non arriva (stessa cautela del pannello di scelta).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if panel.alphaValue < 0.05 {
                panel.orderOut(nil)
            }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
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

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true

        let content = HUDContentView(frame: effect.bounds)
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        panel.contentView = effect

        self.panel = panel
        self.content = content
        return panel
    }
}

final class HUDContentView: NSView {
    var level: Float = 0 {
        didSet { needsDisplay = true }
    }

    private let iconView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboard backlight")
        iconView.image = image
        iconView.contentTintColor = NSColor.white.withAlphaComponent(0.95)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let side: CGFloat = 34
        iconView.frame = NSRect(
            x: 22,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(
            x: 72,
            y: bounds.midY - 6,
            width: bounds.width - 72 - 24,
            height: 12
        )
        let background = NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6)
        NSColor.white.withAlphaComponent(0.22).setFill()
        background.fill()

        let fillWidth = bar.width * CGFloat(level)
        if fillWidth > 0.5 {
            let fill = NSRect(x: bar.minX, y: bar.minY, width: fillWidth, height: bar.height)
            let path = NSBezierPath(roundedRect: fill, xRadius: 6, yRadius: 6)
            NSColor.white.withAlphaComponent(0.92).setFill()
            path.fill()
        }
    }
}
