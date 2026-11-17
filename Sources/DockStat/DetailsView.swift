import SwiftUI

/// The popover shown when a panel is clicked: one card per stat, with 2-minute graphs.
/// The clicked panel's stats come first.
struct DetailsView: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var layout: LayoutStore
    let side: PanelSide
    let onCustomize: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    private var ordered: [StatKind] {
        let first = layout.stats(on: side)
        let other = layout.stats(on: side == .left ? .right : .left)
        let rest = StatKind.available.filter { !first.contains($0) && !other.contains($0) }
        return first + other + rest
    }

    var body: some View {
        let kinds = ordered
        let leftColumn = kinds.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let rightColumn = kinds.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)

        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("DockStat")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text(AppSettings.shared.historyDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onCustomize) {
                    Label("Customize", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Settings")
                Button(action: onQuit) {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Quit DockStat")
            }

            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 10) { ForEach(leftColumn) { card(for: $0) } }
                VStack(spacing: 10) { ForEach(rightColumn) { card(for: $0) } }
            }
        }
        .padding(14)
        .frame(width: 600)
    }

    @ViewBuilder
    private func card(for kind: StatKind) -> some View {
        switch kind {
        case .cpu: CPUCard(model: model)
        case .memory: MemoryCard(model: model)
        case .temperature: TemperatureCard(model: model)
        case .battery: BatteryCard(model: model)
        case .network: NetworkCard(model: model)
        case .disk: DiskCard(model: model)
        }
    }
}

// MARK: - Cards

private struct Card<Content: View>: View {
    let kind: StatKind
    let value: String
    var valueColor: Color = .primary
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(kind.title, systemImage: kind.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(valueColor)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.06))
        )
    }
}

private struct CPUCard: View {
    @ObservedObject var model: StatsModel

    var body: some View {
        Card(kind: .cpu, value: "\(Int(model.cpu.rounded()))%") {
            HistoryChart(series: [(model.cpuHistory, Palette.load(model.cpu))], maxValue: 100)
            if !model.cores.isEmpty {
                if model.efficiencyCores > 0 {
                    coreRow("Efficiency", model.cores.filter(\.isEfficiency))
                    coreRow("Performance", model.cores.filter { !$0.isEfficiency })
                } else {
                    // Intel and other Macs without efficiency cores.
                    coreRow("Cores", model.cores)
                }
            }
        }
    }

    private func coreRow(_ title: String, _ cores: [CoreUsage]) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(cores) { core in
                    VerticalBar(fraction: core.usage / 100, color: Palette.load(core.usage))
                        .frame(width: 10, height: 22)
                        .help("Core \(core.id + 1): \(Int(core.usage.rounded()))%")
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct MemoryCard: View {
    @ObservedObject var model: StatsModel

    var body: some View {
        Card(kind: .memory, value: "\(Int(model.memPercent.rounded()))%") {
            HStack {
                Text("\(Format.bytes(model.memUsed)) of \(Format.bytes(model.memTotal))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let p = model.memDetail?.pressure {
                    HStack(spacing: 4) {
                        Circle().fill(color(p)).frame(width: 7, height: 7)
                        Text("Pressure: \(p.label)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            HistoryChart(series: [(model.memHistory, Palette.memory(model.memPercent))], maxValue: 100)
            if let d = model.memDetail {
                VStack(spacing: 3) {
                    DetailRow("App memory", Format.bytes(d.app))
                    DetailRow("Wired", Format.bytes(d.wired))
                    DetailRow("Compressed", Format.bytes(d.compressed))
                    DetailRow("Cached files", Format.bytes(d.cached))
                    DetailRow("Swap used", Format.bytes(d.swapUsed))
                }
            }
        }
    }

    private func color(_ p: MemoryPressure) -> Color {
        switch p {
        case .normal: return Palette.green
        case .warning: return Palette.yellow
        case .critical: return Palette.red
        }
    }
}

private struct TemperatureCard: View {
    @ObservedObject var model: StatsModel

    var body: some View {
        let t = model.temperature
        let unit = AppSettings.shared.temperatureUnit
        Card(kind: .temperature, value: t.map { "\(Int(unit.convert($0).rounded()))\(unit.symbol)" } ?? "–",
             valueColor: t.map(Palette.temperature) ?? .primary) {
            HistoryChart(series: [(model.tempHistory, Palette.temperature(t ?? 40))],
                         minValue: 25, maxValue: 105)
            if let lo = model.tempHistory.min(), let hi = model.tempHistory.max() {
                DetailRow("Range", "\(Int(unit.convert(lo).rounded()))° – \(Int(unit.convert(hi).rounded()))°")
            }
            Text("Average of the chip's die sensors")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct BatteryCard: View {
    @ObservedObject var model: StatsModel

    var body: some View {
        let b = model.battery
        let d = model.batteryDetail
        Card(kind: .battery, value: b.map { "\(Int($0.percent.rounded()))%" } ?? "–") {
            if let b {
                Meter(fraction: b.percent / 100, color: Palette.battery(b.percent, charging: b.isCharging || b.onAC))
                    .frame(height: 6)
                VStack(spacing: 3) {
                    DetailRow("Status", status(b))
                    if let m = d?.minutesRemaining {
                        DetailRow(b.isCharging ? "Until full" : "Time left", Format.duration(minutes: m))
                    }
                    if let w = d?.powerWatts, abs(w) > 0.05 {
                        DetailRow(w < 0 ? "Drawing" : "Charging at", String(format: "%.1f W", abs(w)))
                    }
                    if let h = d?.healthPercent {
                        DetailRow("Health", "\(Int(h.rounded()))%")
                    }
                    if let c = d?.cycleCount {
                        DetailRow("Cycles", "\(c)")
                    }
                    if let t = d?.temperature {
                        DetailRow("Battery temp", "\(Int(AppSettings.shared.temperatureUnit.convert(t).rounded()))\(AppSettings.shared.temperatureUnit.symbol)")
                    }
                }
            } else {
                Text("No battery found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func status(_ b: BatteryReading) -> String {
        if b.isCharging { return "Charging" }
        if b.onAC { return "On power adapter" }
        return "On battery"
    }
}

private struct NetworkCard: View {
    @ObservedObject var model: StatsModel

    var body: some View {
        Card(kind: .network, value: "↓ \(Format.rate(model.netDown))") {
            let peak = max(model.netDownHistory.max() ?? 0, model.netUpHistory.max() ?? 0, 64 * 1024)
            HistoryChart(series: [(model.netDownHistory, Palette.blue),
                                  (model.netUpHistory, Palette.pink)],
                         maxValue: peak)
            HStack(spacing: 12) {
                legend("↓", Palette.blue, model.netDown)
                legend("↑", Palette.pink, model.netUp)
                Spacer()
                Text("peak \(Format.rate(peak))/s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func legend(_ title: String, _ color: Color, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(title) \(Format.rate(value))/s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}

private struct DiskCard: View {
    @ObservedObject var model: StatsModel

    var body: some View {
        let d = model.diskDetail
        let pct = d.map { $0.total > 0 ? $0.used / $0.total * 100 : 0 } ?? model.diskUsedPercent ?? 0
        Card(kind: .disk, value: "\(Int(pct.rounded()))%") {
            Meter(fraction: pct / 100, color: Palette.load(pct))
                .frame(height: 6)
            if let d {
                VStack(spacing: 3) {
                    DetailRow("Free", Format.bytes(d.free, decimal: true))
                    DetailRow("Used", Format.bytes(d.used, decimal: true))
                    DetailRow("Capacity", Format.bytes(d.total, decimal: true))
                }
            }
        }
    }
}

// MARK: - Building blocks

private struct DetailRow: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }
}

private struct VerticalBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let f = CGFloat(min(1, max(0, fraction)))
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2.5).fill(.primary.opacity(0.12))
                RoundedRectangle(cornerRadius: 2.5).fill(color)
                    .frame(height: max(2, geo.size.height * f))
            }
        }
    }
}

/// Area + line chart of the last 2 minutes. Several series share one scale.
struct HistoryChart: View {
    let series: [([Double], Color)]
    var minValue: Double = 0
    var maxValue: Double = 100
    var height: CGFloat = 46

    var body: some View {
        GeometryReader { geo in
            let n = StatsModel.historyLength
            let step = geo.size.width / CGFloat(max(1, n - 1))
            let span = max(0.0001, maxValue - minValue)
            ZStack {
                // Quarter grid lines.
                ForEach(1..<4) { i in
                    Path { p in
                        let y = geo.size.height * CGFloat(i) / 4
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(.primary.opacity(0.06), lineWidth: 1)
                }
                ForEach(series.indices, id: \.self) { s in
                    let (values, color) = series[s]
                    let offset = CGFloat(n - values.count) * step
                    let points = values.enumerated().map { i, v in
                        CGPoint(x: offset + CGFloat(i) * step,
                                y: geo.size.height * (1 - CGFloat(min(1, max(0, (v - minValue) / span)))))
                    }
                    if points.count > 1 {
                        Path { p in
                            p.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                            points.forEach { p.addLine(to: $0) }
                            p.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                            p.closeSubpath()
                        }
                        .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.03)],
                                             startPoint: .top, endPoint: .bottom))
                        Path { p in
                            p.move(to: points[0])
                            points.dropFirst().forEach { p.addLine(to: $0) }
                        }
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
        .frame(height: height)
        .padding(4)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
