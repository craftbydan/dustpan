// System readers for the menu-bar gauge: CPU, memory, battery, network.
//
// Adapted from Stats (https://github.com/exelban/stats, Modules/{CPU,RAM,Battery,Net}/readers.swift),
// Copyright (c) 2019 Serhiy Mytrovtsiy, MIT License — full notice in THIRD_PARTY_NOTICES.md.
// Changes: rewritten as small synchronous readers owned by `SystemMonitor`; the processor-info
// buffer is copied and freed on every read; the host port and IORegistry entries are released;
// no SMC, temperatures, fans, per-process lists or Wi-Fi details.

import Darwin
import Foundation
import IOKit
import IOKit.ps

/// What one sample holds. Values are nil when that reader didn't run (popover closed) or has
/// nothing to say (no battery, first CPU/network reading).
struct SystemSample: Sendable, Equatable {
    var date: Date
    var disk: DiskSpace?
    /// Share of all cores busy since the previous reading, 0…1.
    var cpu: Double?
    var memory: MemoryReading?
    var battery: BatteryReading?
    var network: NetworkRate?
}

/// Memory pressure as macOS reports it (`kern.memorystatus_vm_pressure_level`).
enum MemoryPressure: Int, Sendable, Equatable {
    case normal = 1
    case warning = 2
    case critical = 4

    /// Calm words for the gauge.
    var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Busy"
        case .critical: "Very busy"
        }
    }
}

struct MemoryReading: Sendable, Equatable {
    /// Physical memory installed.
    var totalBytes: UInt64
    /// In use by apps and the system (active + inactive + speculative + wired + compressed − purgeable − file-backed).
    var usedBytes: UInt64
    var pressure: MemoryPressure

    var usedFraction: Double { totalBytes > 0 ? min(Double(usedBytes) / Double(totalBytes), 1) : 0 }
}

struct BatteryReading: Sendable, Equatable {
    /// Charge, 0…1.
    var level: Double
    var isCharging: Bool
    var isOnPower: Bool
    /// Full-charge capacity as a share of the design capacity (0…100), when the battery reports it.
    var healthPercent: Int?
    var cycles: Int?
}

struct NetworkRate: Sendable, Equatable {
    var bytesInPerSecond: Double
    var bytesOutPerSecond: Double
}

// MARK: - CPU

/// Busy share across all cores from `host_processor_info` tick deltas.
final class CPUReader {
    private let host = mach_host_self()
    private var previous: [Int32]?

    deinit { mach_port_deallocate(mach_task_self_, host) }

    /// Forgets the last reading (the next `read()` only sets a baseline).
    func reset() { previous = nil }

    /// 0…1, or nil on the first call after `reset()` (a delta needs two readings).
    func read() -> Double? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
            let info
        else { return nil }
        // Copy the ticks and give the kernel's buffer back straight away.
        let ticks = Array(UnsafeBufferPointer(start: info, count: Int(infoCount)))
        vm_deallocate(
            mach_task_self_, vm_address_t(bitPattern: info),
            vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))

        defer { previous = ticks }
        guard let previous, previous.count == ticks.count else { return nil }
        return Self.busyShare(previous: previous, current: ticks, cpus: Int(cpuCount))
    }

    /// Busy ticks / all ticks between two `PROCESSOR_CPU_LOAD_INFO` arrays. Counters wrap, so
    /// differences use wrapping arithmetic on the unsigned values.
    static func busyShare(previous: [Int32], current: [Int32], cpus: Int) -> Double? {
        let stride = Int(CPU_STATE_MAX)
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for cpu in 0..<cpus {
            func delta(_ state: Int32) -> UInt64 {
                let index = cpu * stride + Int(state)
                guard index < current.count, index < previous.count else { return 0 }
                return UInt64(UInt32(bitPattern: current[index]) &- UInt32(bitPattern: previous[index]))
            }
            let user = delta(CPU_STATE_USER)
            let system = delta(CPU_STATE_SYSTEM)
            let nice = delta(CPU_STATE_NICE)
            let idle = delta(CPU_STATE_IDLE)
            busy += user + system + nice
            total += user + system + nice + idle
        }
        guard total > 0 else { return nil }
        return min(max(Double(busy) / Double(total), 0), 1)
    }
}

// MARK: - Memory

/// Memory in use and pressure, from `host_statistics64(HOST_VM_INFO64)` and sysctl.
final class MemoryReader {
    private let host = mach_host_self()

    deinit { mach_port_deallocate(mach_task_self_, host) }

    func read() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        let inUse =
            UInt64(stats.active_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)
            + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        let reclaimable = UInt64(stats.purgeable_count) + UInt64(stats.external_page_count)
        let total = ProcessInfo.processInfo.physicalMemory
        let used = min((inUse > reclaimable ? inUse - reclaimable : 0) * page, total)

        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let pressure: MemoryPressure =
            sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
            ? MemoryPressure(rawValue: Int(level)) ?? .normal : .normal
        return MemoryReading(totalBytes: total, usedBytes: used, pressure: pressure)
    }
}

// MARK: - Battery

/// The internal battery from `IOPSCopyPowerSourcesInfo`, plus health and cycle count from the
/// `AppleSmartBattery` IORegistry entry when there is one. Nil on Macs without a battery.
enum BatteryReader {
    static func read() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        guard
            let battery = descriptions.first(where: {
                $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            })
        else { return nil }

        let current = battery[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = battery[kIOPSMaxCapacityKey] as? Int ?? 100
        var reading = BatteryReading(
            level: max > 0 ? min(Double(current) / Double(max), 1) : 0,
            isCharging: battery[kIOPSIsChargingKey] as? Bool ?? false,
            isOnPower: battery[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
            healthPercent: nil, cycles: nil)

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return reading }
        defer { IOObjectRelease(service) }
        func int(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
        }
        reading.cycles = int("CycleCount")
        let design = int("DesignCapacity") ?? 0
        #if arch(arm64)
            let full = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity")
        #else
            let full = int("MaxCapacity") ?? int("NominalChargeCapacity")
        #endif
        if let full, design > 0 {
            reading.healthPercent = Swift.min(Int((100 * Double(full) / Double(design)).rounded()), 100)
        }
        return reading
    }
}

// MARK: - Network

/// Bytes per second in and out across the physical interfaces, from `getifaddrs` counters.
final class NetworkReader {
    private var previous: [String: (input: UInt32, output: UInt32)] = [:]
    private var previousTime: ContinuousClock.Instant?

    /// Tunnels, peer-to-peer Wi-Fi and bridges carry traffic already counted on a real interface.
    static let skippedPrefixes = ["lo", "utun", "awdl", "llw", "bridge", "gif", "stf", "anpi", "ap", "ipsec", "ppp"]

    func reset() {
        previous = [:]
        previousTime = nil
    }

    /// Nil on the first call after `reset()`.
    func read(now: ContinuousClock.Instant = .now) -> NetworkRate? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return nil }
        defer { freeifaddrs(addresses) }

        var counters: [String: (input: UInt32, output: UInt32)] = [:]
        var pointer = addresses
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                let data = current.pointee.ifa_data
            else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard !Self.skippedPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            let ifData = data.assumingMemoryBound(to: if_data.self).pointee
            counters[name] = (ifData.ifi_ibytes, ifData.ifi_obytes)
        }

        defer {
            previous = counters
            previousTime = now
        }
        guard let previousTime else { return nil }
        let seconds =
            Double((now - previousTime).components.seconds)
            + Double((now - previousTime).components.attoseconds) / 1e18
        guard seconds > 0 else { return nil }
        var input: UInt64 = 0
        var output: UInt64 = 0
        for (name, value) in counters {
            guard let old = previous[name],
                let inDelta = Self.counterDelta(old: old.input, new: value.input),
                let outDelta = Self.counterDelta(old: old.output, new: value.output)
            else { continue }
            input += inDelta
            output += outDelta
        }
        return NetworkRate(bytesInPerSecond: Double(input) / seconds, bytesOutPerSecond: Double(output) / seconds)
    }

    /// Bytes between two readings of a 32-bit interface counter. A counter that went down from the
    /// upper half wrapped (wrapping subtraction gives the delta); one that went down from the lower
    /// half was reset (interface restarted) — nil, so that interface sits this sample out.
    static func counterDelta(old: UInt32, new: UInt32) -> UInt64? {
        if new >= old { return UInt64(new - old) }
        guard old >= UInt32.max / 2 else { return nil }
        return UInt64(new &- old)
    }
}
