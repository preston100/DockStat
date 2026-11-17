import Foundation
import Darwin
import IOKit
import IOKit.ps

// MARK: - Memory

/// RAM in use, computed the way Activity Monitor's "Memory Used" is:
/// app memory (internal - purgeable) + wired + compressed.
enum MemorySampler {
    static let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)

    static func sample() -> (used: Double, total: Double)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = Double(getpagesize())
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let wired = Double(stats.wire_count)
        let compressed = Double(stats.compressor_page_count)
        let used = (app + wired + compressed) * page
        return (min(used, totalBytes), totalBytes)
    }
}

// MARK: - Battery

struct BatteryReading {
    var percent: Double
    var isCharging: Bool
    var onAC: Bool
}

enum BatterySampler {
    static func sample() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Double ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Double ?? 100
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return BatteryReading(percent: max > 0 ? current / max * 100 : 0, isCharging: charging, onAC: onAC)
        }
        return nil
    }
}

// MARK: - Network

/// Bytes/second down and up across physical interfaces (en*), from the kernel's
/// per-interface counters. Loopback and VPN tunnels are skipped to avoid double counting.
final class NetworkSampler {
    private var lastIn: UInt64 = 0
    private var lastOut: UInt64 = 0
    private var lastTime: TimeInterval = 0

    func sample() -> (down: Double, up: Double)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr {
            let entry = ifa.pointee
            if let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               let data = entry.ifa_data,
               String(cString: entry.ifa_name).hasPrefix("en") {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                totalIn += UInt64(d.ifi_ibytes)
                totalOut += UInt64(d.ifi_obytes)
            }
            ptr = entry.ifa_next
        }

        let now = ProcessInfo.processInfo.systemUptime
        defer { lastIn = totalIn; lastOut = totalOut; lastTime = now }
        guard lastTime > 0, now > lastTime else { return nil }

        let dt = now - lastTime
        // Counters are 32-bit per interface and can wrap; a negative delta just reads as 0.
        let down = totalIn >= lastIn ? Double(totalIn - lastIn) / dt : 0
        let up = totalOut >= lastOut ? Double(totalOut - lastOut) / dt : 0
        return (down, up)
    }
}

// MARK: - Temperature (Apple Silicon)

// Private IOKit HID calls. These are the same ones used by other open-source Apple Silicon
// monitors; they need no special permissions. If Apple removes them, temperature just disappears.
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ match: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

/// Average SoC die temperature in °C, from the "PMU tdie" sensors.
final class TemperatureSampler {
    private static let temperatureEvent: Int64 = 15            // kIOHIDEventTypeTemperature
    private static let temperatureField: Int32 = 15 << 16     // kIOHIDEventFieldTemperatureLevel

    private let client: AnyObject?
    private let dieSensors: [AnyObject]

    init() {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else {
            self.client = nil; self.dieSensors = []; return
        }
        // Usage page 0xff00 / usage 5 = Apple vendor temperature sensors.
        _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let services = (IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        // Keep only die sensors, chosen once, so each read touches ~14 services instead of ~50.
        self.client = client
        self.dieSensors = services.filter { service in
            let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String
            return name?.hasPrefix("PMU tdie") == true
        }
    }

    var isAvailable: Bool { !dieSensors.isEmpty }

    func sample() -> Double? {
        var sum = 0.0
        var n = 0.0
        for sensor in dieSensors {
            guard let event = IOHIDServiceClientCopyEvent(sensor, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let value = IOHIDEventGetFloatValue(event, Self.temperatureField)
            if value > 0 && value < 150 { sum += value; n += 1 }   // drop bogus readings
        }
        return n > 0 ? sum / n : nil
    }
}

// MARK: - Disk

enum DiskSampler {
    /// Percent of the startup volume in use (counting purgeable space as free, like Finder).
    static func usedPercent() -> Double? {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                         .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity, total > 0,
              let free = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return min(100, max(0, (1 - Double(free) / Double(total)) * 100))
    }
}
