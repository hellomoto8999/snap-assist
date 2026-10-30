import Foundation

/// Mappatura delle usage HID: F1/F2 vengono rimappate
/// sulle usage Apple di illuminazione della tastiera. Non intercettiamo gli
/// eventi: livello e HUD sono gestiti da macOS, quindi la barra compare sul
/// display attivo anche con monitor esterni.
enum KeyboardBacklightMapping {
    static let sourceF1 = "0x70000003A"
    static let sourceF2 = "0x70000003B"
    // Su macOS la usage 0x08 alza e la 0x09 abbassa (verificato sul campo).
    static let destinationUp = "0xFF00000008"
    static let destinationDown = "0xFF00000009"

    static var json: String {
        """
        {"UserKeyMapping":[
            {"HIDKeyboardModifierMappingSrc": \(sourceF1), "HIDKeyboardModifierMappingDst": \(destinationDown)},
            {"HIDKeyboardModifierMappingSrc": \(sourceF2), "HIDKeyboardModifierMappingDst": \(destinationUp)}
        ]}
        """
    }

    static let resetJSON = #"{"UserKeyMapping":[]}"#
}

/// Serve solo a sapere se il Mac ha una tastiera retroilluminata: la regolazione
/// vera è delegata a macOS tramite la mappatura HID.
final class KeyboardBrightness {
    static let shared = KeyboardBrightness()

    private var client: NSObject?
    private(set) var keyboardID: UInt64?

    private init() {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return }

        let instance = cls.init()
        client = instance
        if let ids = instance.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?
            .takeRetainedValue() as? [NSNumber],
           let first = ids.first {
            keyboardID = first.uint64Value
        }
    }

    var isAvailable: Bool {
        client != nil && keyboardID != nil
    }
}

/// Applica/rimuove la mappatura HID. Nessun event tap, nessun HUD disegnato:
/// premendo Fn + F1/F2 è il sistema a cambiare la retroilluminazione e a
/// mostrare la sua barra, come fa il sistema.
final class KeyboardBacklightController {
    var isEnabled = true
    private var mappingApplied = false

    func start() {
        guard isEnabled else { return }
        guard KeyboardBrightness.shared.isAvailable else {
            ZoneLog.write("keyboard backlight: nessuna tastiera retroilluminata")
            return
        }
        applyMapping()
    }

    func stop() {
        guard mappingApplied else { return }
        resetMapping()
    }

    private func applyMapping() {
        guard run(KeyboardBacklightMapping.json) else {
            ZoneLog.write("keyboard backlight: mappatura hidutil fallita")
            return
        }
        mappingApplied = true
        ZoneLog.write("keyboard backlight: Fn+F1/F2 rimappati, HUD di sistema")
    }

    private func resetMapping() {
        if run(KeyboardBacklightMapping.resetJSON) {
            mappingApplied = false
            ZoneLog.write("keyboard backlight: mappatura rimossa")
        }
    }

    @discardableResult
    private func run(_ json: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        task.arguments = ["property", "--set", json]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return false
        }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}
