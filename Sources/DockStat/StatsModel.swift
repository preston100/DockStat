import Foundation
import Combine

/// Latest readings plus short histories, published to the panels, the Customize window
/// and the details popover.
final class StatsModel: ObservableObject {
    /// Samples kept for graphs: 60 × 2 s = 2 minutes.
    static let historyLength = 60

    @Published var cpu: Double = 0
    @Published var cpuHistory: [Double] = []
    @Published var memUsed: Double = 0
    @Published var memTotal: Double = MemorySampler.totalBytes
    @Published var memHistory: [Double] = []
    @Published var temperature: Double?
    @Published var tempHistory: [Double] = []
    @Published var battery: BatteryReading?
    @Published var netDown: Double = 0
    @Published var netUp: Double = 0
    @Published var netDownHistory: [Double] = []
    @Published var netUpHistory: [Double] = []
    @Published var diskUsedPercent: Double?

    // Only filled while the details popover is open.
    @Published var cores: [CoreUsage] = []
    @Published var memDetail: MemoryDetail?
    @Published var batteryDetail: BatteryDetail?
    @Published var diskDetail: DiskDetail?

    var memPercent: Double { memTotal > 0 ? memUsed / memTotal * 100 : 0 }

    // Sampling happens off the main thread; only the publish hops back.
    private let queue = DispatchQueue(label: "DockStat.sampling", qos: .utility)
    private let cpuSampler = CPUSampler()
    private let netSampler = NetworkSampler()
    private let coreSampler = PerCoreSampler()
    private lazy var tempSampler = TemperatureSampler()
    private var tick = 0

    var efficiencyCores: Int { coreSampler.efficiencyCount }
    var performanceCores: Int { coreSampler.performanceCount }

    init() {
        queue.async { [cpuSampler] in
            _ = cpuSampler.sample()   // prime deltas
        }
    }

    /// Samples only what is shown (`kinds`), plus CPU and memory which are nearly free.
    /// `everything` is used while the Customize window or the details are open so every
    /// value is live; `details` adds the popover-only readings.
    func refresh(kinds: Set<StatKind>, everything: Bool = false, details: Bool = false,
                 completion: @escaping () -> Void) {
        let want = everything || details ? Set(StatKind.available) : kinds
        queue.async { [weak self] in
            guard let self else { return }
            self.tick += 1
            let cpu = self.cpuSampler.sample()
            let mem = MemorySampler.sample()
            // Network deltas need consecutive samples, so read it every tick while wanted.
            let net = want.contains(.network) ? self.netSampler.sample() : nil
            // Temperature and battery change slowly; read them every other tick.
            let slowTick = self.tick % 2 == 1
            let temp = slowTick && want.contains(.temperature) ? self.tempSampler.sample() : nil
            let battery = slowTick && want.contains(.battery) ? BatterySampler.sample() : nil
            // Disk barely moves; every 15 ticks (about 30 s), and on the first tick.
            let disk = (self.tick % 15 == 1) && want.contains(.disk) ? DiskSampler.usedPercent() : nil

            let cores = details ? self.coreSampler.sample() : nil
            let memDetail = details ? MemoryDetailSampler.sample() : nil
            let batteryDetail = details && slowTick ? BatteryDetailSampler.sample() : nil
            let diskDetail = details && (self.tick % 15 == 1) ? DiskDetailSampler.sample() : nil

            DispatchQueue.main.async {
                if let cpu {
                    self.cpu = cpu
                    Self.push(cpu, into: &self.cpuHistory)
                }
                if let mem {
                    self.memUsed = mem.used
                    self.memTotal = mem.total
                    Self.push(self.memPercent, into: &self.memHistory)
                }
                if let net {
                    self.netDown = net.down
                    self.netUp = net.up
                    Self.push(net.down, into: &self.netDownHistory)
                    Self.push(net.up, into: &self.netUpHistory)
                }
                if let temp {
                    self.temperature = temp
                    Self.push(temp, into: &self.tempHistory)
                }
                if let battery { self.battery = battery }
                if let disk { self.diskUsedPercent = disk }
                if let cores { self.cores = cores }
                if let memDetail { self.memDetail = memDetail }
                if let batteryDetail { self.batteryDetail = batteryDetail }
                if let diskDetail { self.diskDetail = diskDetail }
                completion()
            }
        }
    }

    /// Forces the slow stats to be read on the next tick (e.g. a view that needs them opened).
    func resetSlowTimers() {
        queue.async { [weak self] in self?.tick = 0 }
    }

    private static func push(_ value: Double, into history: inout [Double]) {
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }
}
