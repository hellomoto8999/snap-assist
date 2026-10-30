import AppKit
import ApplicationServices
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = SnapMonitor()
    private let picker = PickerController()
    private let divider = DividerController()
    private let zones = ZoneDragController()
    private let centerWindow = CenterWindowController()
    private let keyboardBacklight = KeyboardBacklightController()
    private let permissions = PermissionsWindowController()
    private var layoutEditor: LayoutEditorWindowController?

    private var statusItem: NSStatusItem?
    private var trustTimer: Timer?
    private var askedScreenRecording = false

    // MARK: - Preferenze

    private var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "enabled") }
    }

    private var thumbnailsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "thumbnails") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "thumbnails") }
    }

    private var dividerEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "divider") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "divider") }
    }

    private var centerTaps: Int {
        get { UserDefaults.standard.object(forKey: "centerTaps") as? Int ?? 2 }
        set { UserDefaults.standard.set(newValue, forKey: "centerTaps") }
    }

    private var keyboardBacklightEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "keyboardBacklight") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keyboardBacklight") }
    }

    // MARK: - Avvio

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupCallbacks()

        monitor.isEnabled = enabled
        monitor.start()
        divider.isEnabled = dividerEnabled
        divider.start()
        zones.start()
        centerWindow.tapsRequired = max(2, centerTaps)
        centerWindow.isEnabled = centerTaps > 0
        centerWindow.onCentered = { [weak self] pid, window in
            guard let self else { return }
            self.monitor.pauseDetection(for: 1.2)
            self.monitor.noteProgrammaticMove(pid: pid, window: window)
        }
        centerWindow.start()
        keyboardBacklight.isEnabled = keyboardBacklightEnabled
        keyboardBacklight.start()
        permissions.configure(
            suggest: enabled,
            previews: thumbnailsEnabled,
            divider: dividerEnabled,
            login: LoginItem.isEnabled || LoginItem.requiresApproval,
            centerTaps: centerTaps,
            keyboardBacklight: keyboardBacklightEnabled
        )
        permissions.updateLayout(LayoutStore.current)
        startTrustTimer()

        if AX.isTrusted {
            requestScreenRecordingIfNeeded()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.permissions.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        trustTimer?.invalidate()
        monitor.stop()
        divider.stop()
        zones.stop()
        centerWindow.stop()
        keyboardBacklight.stop()
        picker.dismiss(silently: true)
    }

    /// Riaprendo l'app (Finder, Dock, `open`) senza finestre visibili torna il
    /// pannello dei permessi: utile se l'icona nella barra è nascosta.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { permissions.show() }
        return true
    }

    private func setupCallbacks() {
        monitor.onSnap = { [weak self] event in
            guard let self else { return false }
            self.requestScreenRecordingIfNeeded()
            self.divider.isSuspended = true
            let shown = self.picker.present(for: event, thumbnails: self.thumbnailsEnabled)
            if !shown { self.divider.isSuspended = false }
            return shown
        }

        monitor.onShouldDismiss = { [weak self] in
            self?.picker.dismiss()
        }

        picker.onDismiss = { [weak self] in
            guard let self else { return }
            self.monitor.pickerDidDismiss()
            self.divider.isSuspended = false
            self.updateStatusIcon()
        }

        picker.onPick = { [weak self] candidate, target in
            self?.move(candidate, to: target)
        }

        divider.onDraggingChanged = { [weak self] dragging in
            guard let self else { return }
            self.monitor.pauseDetection(for: 1.5)
            guard !dragging else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.monitor.syncWithFrontmostWindow()
            }
        }

        permissions.onSuggestChanged = { [weak self] value in
            guard let self else { return }
            self.enabled = value
            self.monitor.isEnabled = value
            self.refreshMenuState()
        }

        permissions.onPreviewsChanged = { [weak self] value in
            guard let self else { return }
            self.thumbnailsEnabled = value
            if value { self.requestScreenRecordingIfNeeded() }
            self.refreshMenuState()
        }

        permissions.onDividerChanged = { [weak self] value in
            guard let self else { return }
            self.dividerEnabled = value
            self.divider.isEnabled = value
            self.refreshMenuState()
        }

        permissions.onCenterTapsChanged = { [weak self] taps in
            guard let self else { return }
            self.centerTaps = taps
            self.centerWindow.tapsRequired = max(2, taps)
            self.centerWindow.isEnabled = taps > 0
            self.refreshMenuState()
        }

        permissions.onKeyboardBacklightChanged = { [weak self] value in
            guard let self else { return }
            self.keyboardBacklightEnabled = value
            self.keyboardBacklight.isEnabled = value
            if value {
                self.keyboardBacklight.start()
            } else {
                self.keyboardBacklight.stop()
            }
            self.refreshMenuState()
        }

        permissions.onLoginChanged = { [weak self] value in
            self?.setLogin(value)
        }

        permissions.onEditLayout = { [weak self] in
            self?.showLayoutEditor()
        }

        zones.onDragStateChanged = { [weak self] dragging in
            guard let self else { return }
            if dragging {
                self.monitor.pauseDetection(for: 60)
            } else {
                self.monitor.pauseDetection(for: 1.5)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.monitor.syncWithFrontmostWindow()
                }
            }
        }

        zones.onWindowPlaced = { [weak self] pid, window in
            self?.monitor.noteProgrammaticMove(pid: pid, window: window)
        }
    }

    // MARK: - Login e layout

    private func setLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            if enabled, LoginItem.requiresApproval {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = L10n.t("login.approval.title")
                alert.informativeText = L10n.t("login.approval.message")
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        } catch {
            permissions.configure(
                suggest: self.enabled,
                previews: thumbnailsEnabled,
                divider: dividerEnabled,
                login: LoginItem.isEnabled || LoginItem.requiresApproval,
                centerTaps: centerTaps,
                keyboardBacklight: keyboardBacklightEnabled
            )
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.t("login.error.title")
            alert.informativeText = L10n.t("login.error.message")
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func showLayoutEditor() {
        if layoutEditor == nil {
            let editor = LayoutEditorWindowController()
            editor.onSave = { [weak self] layout in
                LayoutStore.current = layout
                self?.permissions.updateLayout(layout)
            }
            layoutEditor = editor
        }
        layoutEditor?.show()
    }

    // MARK: - Spostamento finestra

    private func move(_ candidate: WindowCandidate, to target: NSRect) {
        let targetFrame = ScreenGeometry.accessibility(fromAppKit: target)
        let pid = candidate.pid
        let cgFrame = candidate.frame

        // Lasciamo al pannello il tempo di sparire prima di animare la finestra.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            guard let window = AX.window(pid: pid, matching: cgFrame) else {
                NSSound.beep()
                return
            }

            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AX.setFrame(window, targetFrame)
            AX.activate(window)
            NSRunningApplication(processIdentifier: pid)?.activate()
            self.monitor.noteProgrammaticMove(pid: pid, window: window)
        }
    }

    // MARK: - Permessi

    private func requestScreenRecordingIfNeeded() {
        guard thumbnailsEnabled, !askedScreenRecording, !CGPreflightScreenCaptureAccess() else { return }
        askedScreenRecording = true
        CGRequestScreenCaptureAccess()
    }

    private func openSettings(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func showPermissions() {
        permissions.show()
    }

    private func startTrustTimer() {
        var wasTrusted = AX.isTrusted
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = AX.isTrusted
            guard trusted != wasTrusted else { return }
            wasTrusted = trusted
            self.updateStatusIcon()
            if trusted { self.requestScreenRecordingIfNeeded() }
        }
    }

    // MARK: - Menu barra

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Snap Assist")
            button.image?.isTemplate = true
            button.toolTip = L10n.t("menu.tooltip")
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        // Il menu contiene solo le due voci di servizio: tutte le opzioni
        // (snap, mouse, tastiera, permessi) sono nella finestra Impostazioni.
        let permissionsItem = NSMenuItem(
            title: L10n.t("menu.permissions"),
            action: #selector(showPermissions),
            keyEquivalent: ","
        )
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        let quit = NSMenuItem(title: L10n.t("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        refreshMenuState()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenuState()
    }

    private func refreshMenuState() {
        updateStatusIcon()
        permissions.configure(
            suggest: enabled,
            previews: thumbnailsEnabled,
            divider: dividerEnabled,
            login: LoginItem.isEnabled || LoginItem.requiresApproval,
            centerTaps: centerTaps,
            keyboardBacklight: keyboardBacklightEnabled
        )
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let name = AX.isTrusted ? "rectangle.split.2x1" : "exclamationmark.triangle.fill"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Snap Assist")
        button.image?.isTemplate = true
        button.alphaValue = enabled ? 1 : 0.45
    }

    // MARK: - Azioni

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
