import Darwin
import Foundation

extension SystemMemory {
    private static let host = mach_host_self()

    /// Physical memory, memory in use (app + wired + compressed, as Activity Monitor counts it),
    /// swap and the kernel's pressure level.
    public static func current() -> SystemMemory {
        let swap = swapUsage()
        return SystemMemory(
            physical: Foundation.ProcessInfo.processInfo.physicalMemory,
            used: usedMemory() ?? 0,
            swapUsed: swap.used,
            swapTotal: swap.total,
            pressure: pressureLevel()
        )
    }

    static func usedMemory() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        let anonymous = UInt64(stats.internal_page_count)
        let app = anonymous - min(anonymous, UInt64(stats.purgeable_count))
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    static func swapUsage() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    static func pressureLevel() -> Pressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }
}
