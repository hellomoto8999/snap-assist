import AppKit
import ApplicationServices

/// Regole del gesto: Fn + F1/F2 (i tasti della luminosità display) regolano
/// la retroilluminazione della tastiera.
enum KeyboardBrightnessKey {
    static func direction(keyCode: Int64, functionHeld: Bool) -> Int? {
        guard functionHeld else { return nil }
        switch keyCode {
        case 122: return -1 // F1, luminosità display giù
        case 120: return 1  // F2, luminosità display su
        default: return nil
        }
    }

    static func adjusted(_ current: Float, direction: Int, step: Float = 0.0625) -> Float {
        min(max(current + Float(direction) * step, 0), 1)
    }
}

/// Controllo della retroilluminazione tramite CoreBrightness (API privata,
/// la stessa usata dalle app di terze parti per la tastiera).
final class KeyboardBrightness {
    static let shared = KeyboardBrightness()

    private var client: NSObject?
    private var getBrightness: (@convention(c) (NSObject, Selector, UInt64) -> Float)?
    private var setBrightness: (@convention(c) (NSObject, Selector, Float, Int32, Bool, UInt64) -> Bool)?
    private var getSelector: Selector?
    private var setSelector: Selector?
    private(set) var keyboardID: UInt64?

    private init() {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return }

        let instance = cls.init()
        client = instance

        let get = NSSelectorFromString("brightnessForKeyboard:")
        let set = NSSelectorFromString("setBrightness:fadeSpeed:commit:forKeyboard:")
        guard instance.responds(to: get), instance.responds(to: set) else { return }

        getSelector = get
        setSelector = set
        getBrightness = unsafeBitCast(
            instance.method(for: get),
            to: (@convention(c) (NSObject, Selector, UInt64) -> Float).self
        )
        setBrightness = unsafeBitCast(
            instance.method(for: set),
            to: (@convention(c) (NSObject, Selector, Float, Int32, Bool, UInt64) -> Bool).self
        )

        if let ids = instance.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?
            .takeRetainedValue() as? [NSNumber],
           let first = ids.first {
            keyboardID = first.uint64Value
        }
    }

    var isAvailable: Bool {
        client != nil && keyboardID != nil && getBrightness != nil && setBrightness != nil
    }

    func current() -> Float? {
        guard let client, let getBrightness, let getSelector, let keyboardID else { return nil }
        return getBrightness(client, getSelector, keyboardID)
    }

    @discardableResult
    func set(_ value: Float) -> Bool {
        guard let client, let setBrightness, let setSelector, let keyboardID else { return false }
        let clamped = min(max(value, 0), 1)
        // fadeSpeed 0 = risposta immediata, commit true = scrittura hardware.
        return setBrightness(client, setSelector, clamped, 0, true, keyboardID)
    }
}

/// Intercetta Fn + F1/F2 e regola la retroilluminazione. Usa un event tap per
/// non far arrivare F1/F2 all'app in primo piano; se il tap non è permesso,
/// ripiega su un monitor globale (senza soppressione).
final class KeyboardBacklightController {
    var isEnabled = true

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var monitor: Any?
    private var retryTimer: Timer?
    private let step: Float = 0.0625

    private var brightness: KeyboardBrightness { .shared }

    func start() {
        stop()
        guard isEnabled, brightness.isAvailable else { return }

        if !installTap() {
            installMonitor()
            scheduleTapRetry()
        }
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        retryTimer?.invalidate()
        retryTimer = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    // MARK: - Event tap

    private func installTap() -> Bool {
        if tap != nil { return true }

        // 14 = NX_SYSDEFINED: CGEventType non ha un caso pubblico.
        let systemDefinedType = CGEventType(rawValue: 14)!
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << systemDefinedType.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<KeyboardBacklightController>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                return controller.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        ZoneLog.write("keyboard backlight: event tap attivo")
        return true
    }

    private func handle(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard isEnabled, brightness.isAvailable else {
            return Unmanaged.passUnretained(event)
        }

        let functionHeld = event.flags.contains(.maskSecondaryFn)

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if let direction = KeyboardBrightnessKey.direction(keyCode: keyCode, functionHeld: functionHeld) {
                adjust(direction)
                return nil
            }
        }

        if type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if KeyboardBrightnessKey.direction(keyCode: keyCode, functionHeld: true) != nil, functionHeld {
                return nil
            }
        }

        // Con "F1, F2 come tasti funzione standard" attivo, Fn+F1/F2 arriva
        // come evento luminosità di sistema: lo intercettiamo per non cambiare
        // anche la luminosità del display.
        if type.rawValue == 14,
           let nsEvent = NSEvent(cgEvent: event),
           nsEvent.subtype.rawValue == 8 {
            let fnHeld = functionHeld || nsEvent.modifierFlags.contains(.function)
            guard fnHeld else { return Unmanaged.passUnretained(event) }
            let data1 = nsEvent.data1
            let key = (data1 & 0xFFFF0000) >> 16
            let state = (data1 & 0x0000FF00) >> 8
            if state == 0x0A {
                if key == 1 { adjust(-1); return nil }
                if key == 2 { adjust(1); return nil }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func scheduleTapRetry() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.isEnabled else { return }
            if self.installTap() {
                if let monitor = self.monitor {
                    NSEvent.removeMonitor(monitor)
                    self.monitor = nil
                }
                self.retryTimer?.invalidate()
                self.retryTimer = nil
            }
        }
    }

    // MARK: - Fallback senza tap

    private func installMonitor() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isEnabled, self.brightness.isAvailable else { return }
            let direction = KeyboardBrightnessKey.direction(
                keyCode: Int64(event.keyCode),
                functionHeld: event.modifierFlags.contains(.function)
            )
            if let direction { self.adjust(direction) }
        }
        ZoneLog.write("keyboard backlight: monitor globale (senza soppressione)")
    }

    // MARK: - Livello

    private func adjust(_ direction: Int) {
        guard let current = brightness.current() else { return }
        brightness.set(KeyboardBrightnessKey.adjusted(current, direction: direction, step: step))
    }
}
