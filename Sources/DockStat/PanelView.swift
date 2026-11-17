import SwiftUI

/// One panel beside the Dock: the stats chosen for that side, in order.
/// Everything scales with the Dock's thickness. Side Docks get a vertical stack.
struct PanelView: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var settings = AppSettings.shared
    @StateObject private var hover = HoverFlag()
    let kinds: [StatKind]
    let thickness: CGFloat
    let vertical: Bool
    /// Opens the details (used by VoiceOver's "press" on a stat).
    var onActivate: (() -> Void)? = nil

    var body: some View {
        Group {
            if vertical {
                // Modules are drawn a little smaller so they fit across a narrow side Dock.
                VStack(spacing: thickness * 0.22) {
                    ForEach(kinds) { kind in
                        StatModule(kind: kind, model: model, height: thickness * 0.74, compact: true,
                                   onActivate: onActivate)
                    }
                }
                .padding(.vertical, thickness * 0.24)
                .frame(width: thickness)
            } else {
                HStack(spacing: thickness * 0.16) {
                    ForEach(kinds) { kind in
                        StatModule(kind: kind, model: model, height: thickness, onActivate: onActivate)
                    }
                }
                .padding(.horizontal, thickness * 0.26)
                .frame(height: thickness)
            }
        }
        .fixedSize()
        // Subtle lift on hover, so it reads as clickable.
        .background(Color.white.opacity(hover.on ? 0.07 : 0))
        .animation(.easeOut(duration: 0.15), value: hover.on)
        .onHover { hover.on = $0 }
    }
}

/// Hover flag (an ObservableObject instead of @State, which the Command Line Tools can't build).
final class HoverFlag: ObservableObject {
    @Published var on = false
}

/// A single stat in one of four styles. Used on the panels, in the Customize window
/// and in the Settings preview.
struct StatModule: View {
    let kind: StatKind
    @ObservedObject var model: StatsModel
    @ObservedObject var settings = AppSettings.shared
    let height: CGFloat
    /// nil follows the Settings choice.
    var style: TileStyle? = nil
    /// Narrow layout for side Docks: rings stack their value underneath.
    var compact: Bool = false
    /// What VoiceOver's "press" does (opens the details on the panels).
    var onActivate: (() -> Void)? = nil
    private var tileStyle: TileStyle { style ?? settings.style }

    private var labelSize: CGFloat { max(6, height * 0.17) }
    private var valueSize: CGFloat { max(9, height * 0.31) }
    private var vizHeight: CGFloat { max(2, height * 0.10) }

    private var moduleWidth: CGFloat {
        if compact { return height * 1.0 }
        if kind == .network { return height * 1.15 }
        switch tileStyle {
        case .numbers: return height * 0.86
        case .bars: return height * 0.92
        case .rings: return height * 1.30
        case .graph: return height * 1.10
        }
    }

    var body: some View {
        Group {
            if kind == .network {
                labelled { networkLines }
            } else {
                switch tileStyle {
                case .numbers:
                    labelled { value(valueText, size: valueSize * 1.12) }
                case .bars:
                    labelled {
                        value(valueText)
                        bar
                    }
                case .rings:
                    if compact { compactRingLayout } else { ringLayout }
                case .graph:
                    graphLayout
                }
            }
        }
        .frame(width: moduleWidth, alignment: .leading)
        // VoiceOver reads one sentence per stat instead of each fragment.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenDescription)
        .accessibilityHint(onActivate == nil ? "" : "Opens details")
        .accessibilityAddTraits(onActivate == nil ? [] : .isButton)
        .accessibilityAction { onActivate?() }
    }

    private var spokenDescription: String {
        switch kind {
        case .cpu: return "CPU \(Int(model.cpu.rounded())) percent"
        case .memory: return "Memory \(Int(model.memPercent.rounded())) percent used"
        case .temperature:
            guard let t = model.temperature else { return "Chip temperature unavailable" }
            let unit = settings.temperatureUnit
            return "Chip temperature \(Int(unit.convert(t).rounded())) degrees \(unit == .celsius ? "Celsius" : "Fahrenheit")"
        case .battery:
            guard let b = model.battery else { return "Battery unavailable" }
            let state = b.isCharging ? ", charging" : (b.onAC ? ", on power adapter" : "")
            return "Battery \(Int(b.percent.rounded())) percent\(state)"
        case .network:
            return "Network: download \(Format.spokenRate(model.netDown)), upload \(Format.spokenRate(model.netUp))"
        case .disk:
            return model.diskUsedPercent.map { "Disk \(Int($0.rounded())) percent full" } ?? "Disk"
        }
    }

    // MARK: Layouts

    private func labelled<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: height * 0.02) {
            label
            content()
        }
    }

    private var label: some View {
        Text(title)
            .font(.system(size: labelSize, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// Ring gauge with the label inside, value beside it.
    private var ringLayout: some View {
        let d = height * 0.66
        return HStack(spacing: height * 0.10) {
            ring(diameter: d)
            value(valueText, size: valueSize * 0.86)
        }
    }

    /// Ring above, value below: fits across a side Dock.
    private var compactRingLayout: some View {
        let d = height * 0.72
        return VStack(spacing: height * 0.06) {
            ring(diameter: d)
            value(valueText, size: valueSize * 0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private func ring(diameter d: CGFloat) -> some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.15), lineWidth: d * 0.12)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0.001, fraction ?? 0))))
                .stroke(AngularGradient(colors: [color.opacity(0.75), color], center: .center),
                        style: StrokeStyle(lineWidth: d * 0.12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.3), value: fraction ?? 0)
            Text(kind.label)
                .font(.system(size: d * 0.24, weight: .bold))
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(d * 0.14)
        }
        .frame(width: d, height: d)
    }

    /// Label and value on one line, a taller graph underneath.
    private var graphLayout: some View {
        VStack(alignment: .leading, spacing: height * 0.04) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                label
                Spacer(minLength: 0)
                value(valueText, size: valueSize * 0.72)
            }
            if let history, history.count > 1 {
                Sparkline(values: history.map(normalise), color: color)
                    .frame(height: height * 0.36)
            } else {
                Spacer(minLength: 0)
                bar
            }
        }
        .frame(height: height * 0.76)
    }

    // MARK: Pieces

    private var title: String {
        if kind == .battery, model.battery?.isCharging == true { return "BAT ⚡︎" }
        return kind.label
    }

    private var networkLines: some View {
        VStack(alignment: .leading, spacing: 0) {
            netLine("↓", model.netDown)
            netLine("↑", model.netUp)
        }
    }

    @ViewBuilder
    private var bar: some View {
        if kind == .cpu {
            Sparkline(values: model.cpuHistory, color: color)
                .frame(height: vizHeight * 1.6)
        } else if let f = fraction {
            Meter(fraction: f, color: color)
                .frame(height: vizHeight)
        }
    }

    /// The headline value for this stat.
    private var valueText: String {
        switch kind {
        case .cpu: return percent(model.cpu)
        case .memory: return percent(model.memPercent)
        case .temperature:
            guard let t = model.temperature else { return "–" }
            return "\(Int(settings.temperatureUnit.convert(t).rounded()))°"
        case .battery: return model.battery.map { percent($0.percent) } ?? "–"
        case .network: return Format.rate(model.netDown)
        case .disk: return model.diskUsedPercent.map(percent) ?? "–"
        }
    }

    /// 0...1 fill for bars and rings.
    private var fraction: Double? {
        switch kind {
        case .cpu: return model.cpu / 100
        case .memory: return model.memPercent / 100
        case .temperature: return model.temperature.map { ($0 - 30) / 70 }
        case .battery: return model.battery.map { $0.percent / 100 }
        case .network: return nil
        case .disk: return model.diskUsedPercent.map { $0 / 100 }
        }
    }

    private var color: Color {
        switch kind {
        case .cpu: return Palette.load(model.cpu)
        case .memory: return Palette.memory(model.memPercent)
        case .temperature: return Palette.temperature(model.temperature ?? 40)
        case .battery:
            guard let b = model.battery else { return Palette.green }
            return Palette.battery(b.percent, charging: b.isCharging || b.onAC)
        case .network: return Palette.blue
        case .disk: return Palette.load(model.diskUsedPercent ?? 0)
        }
    }

    /// History for the graph style, if this stat keeps one.
    private var history: [Double]? {
        switch kind {
        case .cpu: return model.cpuHistory
        case .memory: return model.memHistory
        case .temperature: return model.tempHistory
        default: return nil
        }
    }

    /// Maps a history value onto the 0...100 scale the sparkline draws.
    private func normalise(_ v: Double) -> Double {
        kind == .temperature ? (v - 30) / 50 * 100 : v   // 30–80 °C fills the graph
    }

    private func value(_ s: String, size: CGFloat? = nil) -> some View {
        Text(s)
            .font(.system(size: size ?? valueSize, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            // Digits roll to their new value instead of jumping.

    }

    private func netLine(_ arrow: String, _ bytesPerSec: Double) -> some View {
        HStack(spacing: 2) {
            Text(arrow).foregroundStyle(.secondary)
            Text(Format.rate(bytesPerSec)).foregroundStyle(.primary)
        }
        .font(.system(size: valueSize * 0.58, weight: .semibold, design: .rounded).monospacedDigit())
        .lineLimit(1)
    }

    private func percent(_ v: Double) -> String { "\(Int(v.rounded()))%" }
}

// MARK: - Small visualisations

struct Meter: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let f = CGFloat(min(1, max(0, fraction)))
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.15))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.8), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(geo.size.height, geo.size.width * f))
                    .animation(.smooth(duration: 0.3), value: f)
            }
        }
    }
}

struct Sparkline: View {
    let values: [Double]   // 0...100
    let color: Color
    /// How many of the most recent samples to show.
    var capacity: Int = 30

    var body: some View {
        GeometryReader { geo in
            let n = capacity
            let values = Array(self.values.suffix(capacity))
            let step = geo.size.width / CGFloat(max(1, n - 1))
            let offset = CGFloat(n - values.count) * step
            let points = values.enumerated().map { i, v in
                CGPoint(x: offset + CGFloat(i) * step,
                        y: geo.size.height * (1 - CGFloat(min(100, max(0, v)) / 100)))
            }
            ZStack {
                Capsule().fill(.primary.opacity(0.10))
                if points.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(color.opacity(0.35))
                    Path { p in
                        p.move(to: points[0])
                        points.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                }
            }
            .clipShape(Capsule())
        }
    }
}

// MARK: - Colours & formatting

enum Palette {
    // Tuned to macOS's dark-mode system colours so they sit naturally next to the Dock.
    static let green = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let yellow = Color(red: 1.00, green: 0.84, blue: 0.04)
    static let orange = Color(red: 1.00, green: 0.62, blue: 0.04)
    static let red = Color(red: 1.00, green: 0.27, blue: 0.23)
    static let blue = Color(red: 0.25, green: 0.61, blue: 1.00)
    static let pink = Color(red: 1.00, green: 0.42, blue: 0.62)

    static func load(_ p: Double) -> Color {
        p < 50 ? green : (p < 70 ? yellow : (p < 85 ? orange : red))
    }
    /// macOS keeps RAM busy on purpose, so memory only warns when it's really full.
    static func memory(_ p: Double) -> Color {
        p < 80 ? green : (p < 90 ? yellow : (p < 95 ? orange : red))
    }
    static func temperature(_ c: Double) -> Color {
        c < 55 ? blue : (c < 70 ? green : (c < 85 ? orange : red))
    }
    static func battery(_ p: Double, charging: Bool) -> Color {
        if charging { return green }
        return p > 20 ? green : (p > 10 ? yellow : red)
    }
}

enum Format {
    /// "11.8 GB". Memory uses binary units like Activity Monitor; disks use decimal like Finder.
    static func bytes(_ b: Double, decimal: Bool = false) -> String {
        let unit = decimal ? 1000.0 : 1024.0
        let gb = b / (unit * unit * unit)
        if gb >= 100 { return "\(Int(gb.rounded())) GB" }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return "\(Int((b / (unit * unit)).rounded())) MB"
    }

    /// "2 h 38 min" / "45 min".
    static func duration(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// "1.2 megabytes per second" for VoiceOver.
    static func spokenRate(_ bytesPerSec: Double) -> String {
        let kb = bytesPerSec / 1024
        if kb < 1000 { return "\(Int(kb.rounded())) kilobytes per second" }
        return String(format: "%.1f megabytes per second", kb / 1024)
    }

    /// Compact rate: "0K", "840K", "1.2M", "12M".
    static func rate(_ bytesPerSec: Double) -> String {
        let kb = bytesPerSec / 1024
        if kb < 1000 { return "\(Int(kb.rounded()))K" }
        let mb = kb / 1024
        return mb < 10 ? String(format: "%.1fM", mb) : "\(Int(mb.rounded()))M"
    }
}
