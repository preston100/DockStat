import Foundation
import Combine

/// Every stat that can be placed beside the Dock.
enum StatKind: String, CaseIterable, Codable, Identifiable {
    case cpu, memory, temperature, battery, network, disk

    var id: String { rawValue }

    /// Short label shown on the panel.
    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "MEM"
        case .temperature: return "TEMP"
        case .battery: return "BAT"
        case .network: return "NET"
        case .disk: return "DISK"
        }
    }

    /// Friendly name for the Customize window.
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .temperature: return "Temperature"
        case .battery: return "Battery"
        case .network: return "Network"
        case .disk: return "Disk"
        }
    }

    /// Stats this Mac can actually show: desktops have no battery, Intel Macs don't expose
    /// the Apple Silicon temperature sensors. Worked out once at launch.
    static let available: [StatKind] = {
        var kinds = allCases
        if BatterySampler.sample() == nil { kinds.removeAll { $0 == .battery } }
        if !TemperatureSampler().isAvailable { kinds.removeAll { $0 == .temperature } }
        return kinds
    }()

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .temperature: return "thermometer.medium"
        case .battery: return "battery.75percent"
        case .network: return "network"
        case .disk: return "internaldrive"
        }
    }
}

/// Which stats sit on each side of the Dock, in order. Saved between launches.
final class LayoutStore: ObservableObject {
    static let maxPerSide = 3
    private static let key = "tileLayout.v1"

    @Published private(set) var left: [StatKind]
    @Published private(set) var right: [StatKind]

    private struct Saved: Codable { var left: [StatKind]; var right: [StatKind] }

    static let defaultLeft: [StatKind] = [.cpu, .memory]
    /// Temperature and battery where the Mac has them, topped up with disk and network.
    static let defaultRight: [StatKind] = {
        let preferred: [StatKind] = [.temperature, .battery, .disk, .network]
        return Array(preferred.filter(StatKind.available.contains).prefix(2))
    }()

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            left = saved.left.filter(StatKind.available.contains)
            right = saved.right.filter(StatKind.available.contains)
        } else {
            left = Self.defaultLeft
            right = Self.defaultRight
        }
    }

    func stats(on side: PanelSide) -> [StatKind] { side == .left ? left : right }

    var active: Set<StatKind> { Set(left + right) }

    var unused: [StatKind] { StatKind.available.filter { !active.contains($0) } }

    func isFull(_ side: PanelSide, ignoring kind: StatKind) -> Bool {
        stats(on: side).filter { $0 != kind }.count >= Self.maxPerSide
    }

    /// Moves `kind` to `side` at `index` (or the end). Removes it from wherever it was.
    /// Returns false if that side is already full.
    @discardableResult
    func place(_ kind: StatKind, on side: PanelSide, at index: Int? = nil) -> Bool {
        if isFull(side, ignoring: kind) { return false }
        var l = left.filter { $0 != kind }
        var r = right.filter { $0 != kind }
        if side == .left {
            l.insert(kind, at: min(index ?? l.count, l.count))
        } else {
            r.insert(kind, at: min(index ?? r.count, r.count))
        }
        left = l
        right = r
        save()
        return true
    }

    /// Moves `kind` so it sits just before `target` (which may be on either side).
    @discardableResult
    func place(_ kind: StatKind, before target: StatKind) -> Bool {
        guard kind != target else { return true }
        let side: PanelSide = left.contains(target) ? .left : .right
        let index = stats(on: side).filter { $0 != kind }.firstIndex(of: target)
        return place(kind, on: side, at: index)
    }

    func remove(_ kind: StatKind) {
        left.removeAll { $0 == kind }
        right.removeAll { $0 == kind }
        save()
    }

    func reset() {
        left = Self.defaultLeft
        right = Self.defaultRight
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Saved(left: left, right: right)) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
