import Foundation
import Darwin
import IOKit
import IOKit.ps

// Extra readings used only by the details popover, sampled only while it is open.

// MARK: - Per-core CPU

struct CoreUsage: Identifiable {
    let id: Int
    let usage: Double        // 0...100
    let isEfficiency: Bool
}

final class PerCoreSampler {
    private var previous: [[UInt32]] = []

    /// Efficiency cores come first in the kernel's numbering on Apple Silicon.
    let efficiencyCount: Int = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
    let performanceCount: Int = sysctlInt("hw.perflevel0.logicalcpu") ?? 0

    func sample() -> [CoreUsage]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let stride = Int(CPU_STATE_MAX)
        var current: [[UInt32]] = []
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * stride
            current.append((0..<stride).map { UInt32(bitPattern: info[base + $0]) })
        }
        defer { previous = current }
        guard previous.count == current.count else { return nil }

        return current.indices.map { i in
            let now = current[i], before = previous[i]
            let user = Double(now[Int(CPU_STATE_USER)] &- before[Int(CPU_STATE_USER)])
            let sys = Double(now[Int(CPU_STATE_SYSTEM)] &- before[Int(CPU_STATE_SYSTEM)])
            let nice = Double(now[Int(CPU_STATE_NICE)] &- before[Int(CPU_STATE_NICE)])
            let idle = Double(now[Int(CPU_STATE_IDLE)] &- before[Int(CPU_STATE_IDLE)])
            let total = user + sys + nice + idle
            let usage = total > 0 ? (user + sys + nice) / total * 100 : 0
            return CoreUsage(id: i, usage: usage, isEfficiency: i < efficiencyCount)
        }
    }
}

// MARK: - Memory breakdown

enum MemoryPressure: Int {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Elevated"
        case .critical: return "Critical"
        }
    }
}

struct MemoryDetail {
    var app: Double
    var wired: Double
    var compressed: Double
    var cached: Double
    var swapUsed: Double
    var pressure: MemoryPressure
}

enum MemoryDetailSampler {
    static func sample() -> MemoryDetail? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Double(getpagesize())

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 ? Double(swap.xsu_used) : 0

        let level = sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1

        return MemoryDetail(
            app: (Double(stats.internal_page_count) - Double(stats.purgeable_count)) * page,
            wired: Double(stats.wire_count) * page,
            compressed: Double(stats.compressor_page_count) * page,
            cached: (Double(stats.external_page_count) + Double(stats.purgeable_count)) * page,
            swapUsed: swapUsed,
            pressure: MemoryPressure(rawValue: level) ?? .normal)
    }
}

// MARK: - Battery health

struct BatteryDetail {
    var healthPercent: Double?     // like System Settings' "Maximum Capacity"
    var cycleCount: Int?
    var temperature: Double?       // °C
    var powerWatts: Double?        // + charging / - discharging
    var minutesRemaining: Int?     // to empty, or to full while charging
    var isCharging: Bool
    var onAC: Bool
}

enum BatteryDetailSampler {
    static func sample() -> BatteryDetail? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else { return nil }
        let data = props["BatteryData"] as? [String: Any] ?? [:]

        func num(_ key: String) -> NSNumber? {
            (props[key] as? NSNumber) ?? (data[key] as? NSNumber)
        }

        var health: Double?
        if let design = num("DesignCapacity")?.doubleValue, design > 0,
           let full = (num("NominalChargeCapacity") ?? num("AppleRawMaxCapacity"))?.doubleValue {
            health = min(100, full / design * 100)
        }

        var watts: Double?
        if let mv = num("Voltage")?.doubleValue, let ma = num("Amperage")?.int64Value {
            watts = mv * Double(ma) / 1_000_000
        }

        let charging = (props["IsCharging"] as? Bool) ?? false
        let onAC = (props["ExternalConnected"] as? Bool) ?? false

        var minutes: Int?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
           let first = list.first,
           let desc = IOPSGetPowerSourceDescription(info, first)?.takeUnretainedValue() as? [String: Any] {
            let key = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            if let m = desc[key] as? Int, m > 0 { minutes = m }
        }

        return BatteryDetail(
            healthPercent: health,
            cycleCount: num("CycleCount")?.intValue,
            temperature: num("Temperature").map { $0.doubleValue / 100 },
            powerWatts: watts,
            minutesRemaining: minutes,
            isCharging: charging,
            onAC: onAC)
    }
}

// MARK: - Disk

struct DiskDetail {
    var total: Double
    var free: Double
    var used: Double { total - free }
}

enum DiskDetailSampler {
    static func sample() -> DiskDetail? {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                         .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity,
              let free = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskDetail(total: Double(total), free: Double(free))
    }
}

// MARK: - Helpers

func sysctlInt(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
}
