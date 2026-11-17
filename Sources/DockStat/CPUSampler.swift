import Darwin

/// Total CPU usage across all cores, from the kernel's cumulative tick counters.
/// One cheap Mach call per sample; no processes spawned, no polling threads.
final class CPUSampler {
    private var previous: host_cpu_load_info?

    /// Returns usage 0...100 since the previous call, or nil on the very first call / on error.
    func sample() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        defer { previous = info }
        guard let prev = previous else { return nil }

        // cpu_ticks is a tuple: (user, system, idle, nice). Counters are UInt32 and may wrap.
        let user   = Double(info.cpu_ticks.0 &- prev.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idle   = Double(info.cpu_ticks.2 &- prev.cpu_ticks.2)
        let nice   = Double(info.cpu_ticks.3 &- prev.cpu_ticks.3)

        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return 0 }
        return min(100, max(0, busy / total * 100))
    }
}
