import Foundation
import Combine
import ServiceManagement

/// How each stat is drawn on the panels.
enum TileStyle: String, CaseIterable, Identifiable {
    case numbers, bars, rings, graph
    var id: String { rawValue }

    var title: String {
        switch self {
        case .numbers: return "Numbers"
        case .bars: return "Bars"
        case .rings: return "Rings"
        case .graph: return "Graph"
        }
    }
}

enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius, fahrenheit
    var id: String { rawValue }
    var symbol: String { self == .celsius ? "°C" : "°F" }

    func convert(_ celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5 + 32
    }
}

/// User preferences, saved to UserDefaults as they change.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let refreshChoices: [TimeInterval] = [1, 2, 3, 5]

    @Published var style: TileStyle {
        didSet { defaults.set(style.rawValue, forKey: "tileStyle") }
    }
    @Published var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: "refreshInterval") }
    }
    @Published var temperatureUnit: TemperatureUnit {
        didSet { defaults.set(temperatureUnit.rawValue, forKey: "temperatureUnit") }
    }
    /// Resize the Dock automatically so the panels fit (asked on first run).
    @Published var autoFitDock: Bool {
        didSet { defaults.set(autoFitDock, forKey: "autoFitDock") }
    }
    /// Put the Dock back to the user's own size when DockStat quits.
    @Published var restoreDockOnQuit: Bool {
        didSet { defaults.set(restoreDockOnQuit, forKey: "restoreDockOnQuit") }
    }
    /// Look for a newer release on GitHub about once a day.
    @Published var checkForUpdates: Bool {
        didSet { defaults.set(checkForUpdates, forKey: "checkForUpdates") }
    }
    /// The welcome window has been completed.
    @Published var didOnboard: Bool {
        didSet { defaults.set(didOnboard, forKey: "didOnboard") }
    }

    /// Mirrors the system's Login Items state; set through `setLaunchAtLogin`.
    @Published private(set) var launchAtLogin = false
    /// Shown under the toggle when macOS needs the user to approve it.
    @Published private(set) var loginItemNote: String?

    private let defaults = UserDefaults.standard

    private init() {
        style = TileStyle(rawValue: defaults.string(forKey: "tileStyle") ?? "") ?? .bars
        let saved = defaults.double(forKey: "refreshInterval")
        refreshInterval = Self.refreshChoices.contains(saved) ? saved : 2
        temperatureUnit = TemperatureUnit(rawValue: defaults.string(forKey: "temperatureUnit") ?? "") ?? .celsius
        autoFitDock = defaults.object(forKey: "autoFitDock") as? Bool ?? true
        restoreDockOnQuit = defaults.object(forKey: "restoreDockOnQuit") as? Bool ?? false
        checkForUpdates = defaults.object(forKey: "checkForUpdates") as? Bool ?? true
        didOnboard = defaults.bool(forKey: "didOnboard")
        refreshLoginItemState()
    }

    /// How long the 60-sample graphs cover, for labels like "last 2 minutes".
    var historyDescription: String {
        let seconds = Int(refreshInterval * Double(StatsModel.historyLength))
        return seconds % 60 == 0 ? "last \(seconds / 60) min" : "last \(seconds) s"
    }

    // MARK: Launch at login (Login Items, via ServiceManagement)

    func setLaunchAtLogin(_ on: Bool) {
        loginItemNote = nil
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemNote = "Couldn't change Login Items: \(error.localizedDescription)"
        }
        refreshLoginItemState(keepError: true)
    }

    func refreshLoginItemState(keepError: Bool = false) {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        if status == .requiresApproval {
            loginItemNote = "Approve DockStat in System Settings → General → Login Items."
        } else if !keepError {
            loginItemNote = nil
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
