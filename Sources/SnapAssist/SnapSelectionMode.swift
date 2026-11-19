import Foundation

enum SnapSelectionMode: String, CaseIterable {
    case ask
    case automatic
    case windowsAssist

    static let defaultMode = SnapSelectionMode.windowsAssist

    static func resolve(_ rawValue: String?) -> SnapSelectionMode {
        guard let rawValue, let mode = SnapSelectionMode(rawValue: rawValue) else {
            return defaultMode
        }
        return mode
    }

    var titleKey: String {
        switch self {
        case .ask: return "settings.selection.ask"
        case .automatic: return "settings.selection.automatic"
        case .windowsAssist: return "settings.selection.windowsAssist"
        }
    }

    var descriptionKey: String {
        switch self {
        case .ask: return "settings.selection.ask.detail"
        case .automatic: return "settings.selection.automatic.detail"
        case .windowsAssist: return "settings.selection.windowsAssist.detail"
        }
    }
}

enum SnapSelectionAction: Equatable {
    case showPicker
    case automaticallyPlace
    case ignore
}

enum SnapSelectionPolicy {
    static func action(
        mode: SnapSelectionMode,
        destinationOccupied: Bool,
        hasCandidate: Bool
    ) -> SnapSelectionAction {
        guard hasCandidate else { return .ignore }

        switch mode {
        case .ask:
            return .showPicker
        case .automatic:
            return destinationOccupied ? .ignore : .automaticallyPlace
        case .windowsAssist:
            return destinationOccupied ? .ignore : .showPicker
        }
    }
}
