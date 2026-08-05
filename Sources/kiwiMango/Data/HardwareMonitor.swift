import Darwin
import Foundation
import IOKit
import Observation

// MARK: - HardwareMonitor (§6 PLAN-V2)
//
// @Observable snapshot of local hardware. Pure data layer — no UI here.
// Timer is started/stopped from the OUTSIDE — never auto-starts in init,
// otherwise it burns CPU while nobody asked for it.
//
// Dashboard's own HardwareStrip UI was removed 2026-08-05 (Paweł already
// has Stats.app in the menu bar — this was a duplicate). This class stays
// only because Remote/StaticWebServer.swift still serves a hardware/process
// snapshot to the Remote Web UI; it starts its own instance on demand. Every
// property below is exactly what StaticWebServer reads — nothing more.
//
// Every reader degrades to nil on failure (pułapka #1/#2/#3): missing data
// is hidden, never faked as zero.
@MainActor
@Observable
final class HardwareMonitor {

    // MARK: CPU

    private(set) var cpuPercent: Double?

    // MARK: GPU

    private(set) var gpuDevicePercent: Double?

    // MARK: RAM

    private(set) var ramAppBytes: UInt64?
    private(set) var ramWiredBytes: UInt64?
    private(set) var ramCompressedBytes: UInt64?
    private(set) var ramTotalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory

    // MARK: SSD

    private(set) var ssdAvailableBytes: Int64?
    private(set) var ssdTotalBytes: Int64?

    // MARK: Network

    private(set) var netDownBytesPerSec: Double?
    private(set) var netUpBytesPerSec: Double?

    // MARK: Processes

    struct TopProcess: Identifiable {
        let id: pid_t
        let name: String
        let cpuPercent: Double
        let ramBytes: UInt64
    }
    private(set) var topProcesses: [TopProcess] = []

    // MARK: Lifecycle

    private var timer: Timer?
    private var lastCPUTicks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)]?
    private var lastNetSample: (time: Date, inBytes: UInt64, outBytes: UInt64)?
    private var lastProcSample: [pid_t: (userTime: UInt64, systemTime: UInt64)] = [:]
    private var lastProcSampleTime: Date?

    /// Starts the 2s refresh. Call from wherever needs live readings.
    func start() {
        stop()
        tick() // immediate first read so the UI isn't empty for 2s
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Stops the timer.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        readCPU()
        readGPU()
        readRAM()
        readSSD()
        readNetwork()
        readTopProcesses()
    }

    // MARK: - CPU

    private func readCPU() {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount)
        guard result == KERN_SUCCESS, let infoArray else {
            cpuPercent = nil
            return
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: infoArray), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        let cpuLoadInfo = infoArray.withMemoryRebound(to: processor_cpu_load_info_data_t.self, capacity: Int(cpuCount)) {
            UnsafeBufferPointer(start: $0, count: Int(cpuCount))
        }

        var ticksNow: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
        ticksNow.reserveCapacity(Int(cpuCount))
        for core in cpuLoadInfo {
            let t = core.cpu_ticks
            ticksNow.append((
                user: t.0,
                system: t.1,
                idle: t.2,
                nice: t.3
            ))
        }

        guard let previous = lastCPUTicks, previous.count == ticksNow.count else {
            // Pułapka #4: first tick has no delta — publish nothing, not 0%.
            lastCPUTicks = ticksNow
            cpuPercent = nil
            return
        }

        var totalUser: Double = 0
        var totalSystem: Double = 0
        var totalAll: Double = 0
        for (prev, now) in zip(previous, ticksNow) {
            let user = Double(diff(now.user, prev.user) + diff(now.nice, prev.nice))
            let system = Double(diff(now.system, prev.system))
            let idle = Double(diff(now.idle, prev.idle))
            totalUser += user
            totalSystem += system
            totalAll += user + system + idle
        }
        lastCPUTicks = ticksNow
        cpuPercent = totalAll > 0 ? (totalUser + totalSystem) / totalAll * 100 : nil
    }

    private func diff(_ now: UInt32, _ prev: UInt32) -> UInt32 {
        // Counters are monotonic increasing; guard against odd wraparound.
        now >= prev ? now - prev : 0
    }

    // MARK: - GPU

    private func readGPU() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            gpuDevicePercent = nil
            return
        }
        defer { IOObjectRelease(iterator) }

        var device: Double?

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = properties?.takeRetainedValue() as? [String: Any],
                  let stats = props["PerformanceStatistics"] as? [String: Any] else { continue }

            // Pułapka #2: key names vary by chip — match on suffix, don't hardcode.
            for (key, value) in stats where key.contains("Utilization %") {
                guard let percent = (value as? NSNumber)?.doubleValue else { continue }
                if key.hasPrefix("Device") { device = percent }
            }
        }

        gpuDevicePercent = device
    }

    // MARK: - RAM

    private func readRAM() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            ramAppBytes = nil
            ramWiredBytes = nil
            ramCompressedBytes = nil
            return
        }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)

        let active = UInt64(stats.active_count) * page
        let internalPages = UInt64(stats.internal_page_count) * page
        let purgeable = UInt64(stats.purgeable_count) * page
        ramAppBytes = (active + internalPages) > purgeable ? (active + internalPages - purgeable) : 0
        ramWiredBytes = UInt64(stats.wire_count) * page
        ramCompressedBytes = UInt64(stats.compressor_page_count) * page
    }

    // MARK: - SSD

    private func readSSD() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) else {
            ssdAvailableBytes = nil
            ssdTotalBytes = nil
            return
        }
        ssdAvailableBytes = values.volumeAvailableCapacityForImportantUsage
        if let total = values.volumeTotalCapacity {
            ssdTotalBytes = Int64(total)
        } else {
            ssdTotalBytes = nil
        }
    }

    // MARK: - Network

    private func readNetwork() {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            netDownBytesPerSec = nil
            netUpBytesPerSec = nil
            return
        }
        defer { freeifaddrs(ifaddrPtr) }

        var inBytes: UInt64?
        var outBytes: UInt64?

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let name = String(cString: interface.ifa_name)
            guard name == "en0" else { continue }

            // ponytail: byte counters live on the AF_LINK entry (if_data) —
            // bug found via the sanity-check run.
            if interface.ifa_addr.pointee.sa_family == UInt8(AF_LINK), let data = interface.ifa_data {
                let netData = data.withMemoryRebound(to: if_data.self, capacity: 1) { $0.pointee }
                inBytes = UInt64(netData.ifi_ibytes)
                outBytes = UInt64(netData.ifi_obytes)
            }
        }

        if let inBytes, let outBytes {
            let now = Date()
            if let last = lastNetSample {
                let elapsed = now.timeIntervalSince(last.time)
                if elapsed > 0 {
                    netDownBytesPerSec = Double(inBytes >= last.inBytes ? inBytes - last.inBytes : 0) / elapsed
                    netUpBytesPerSec = Double(outBytes >= last.outBytes ? outBytes - last.outBytes : 0) / elapsed
                }
            }
            lastNetSample = (now, inBytes, outBytes)
        } else {
            netDownBytesPerSec = nil
            netUpBytesPerSec = nil
        }
    }

    // MARK: - Processes

    private func readTopProcesses() {
        let bufferSize = proc_listallpids(nil, 0)
        guard bufferSize > 0 else { topProcesses = []; return }
        var pids = [pid_t](repeating: 0, count: Int(bufferSize))
        let actualCount = proc_listallpids(&pids, bufferSize * Int32(MemoryLayout<pid_t>.size))
        guard actualCount > 0 else { topProcesses = []; return }

        let now = Date()
        let elapsed = lastProcSampleTime.map { now.timeIntervalSince($0) } ?? 0
        var newSample: [pid_t: (userTime: UInt64, systemTime: UInt64)] = [:]
        var results: [TopProcess] = []

        for pid in pids.prefix(Int(actualCount)) where pid > 0 {
            var usage = rusage_info_current()
            let rc = withUnsafeMutablePointer(to: &usage) { ptr -> Int32 in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rusagePtr in
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rusagePtr)
                }
            }
            guard rc == 0 else { continue }

            newSample[pid] = (usage.ri_user_time, usage.ri_system_time)

            var cpuPercent = 0.0
            if elapsed > 0, let prev = lastProcSample[pid] {
                let deltaNanos = Double((usage.ri_user_time - prev.userTime) &+ (usage.ri_system_time - prev.systemTime))
                cpuPercent = (deltaNanos / 1_000_000_000) / elapsed * 100
            }

            var nameBuffer = [CChar](repeating: 0, count: 256)
            _ = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = String(cString: nameBuffer).isEmpty ? "pid \(pid)" : String(cString: nameBuffer)

            results.append(TopProcess(id: pid, name: name, cpuPercent: cpuPercent, ramBytes: usage.ri_phys_footprint))
        }

        lastProcSample = newSample
        lastProcSampleTime = now
        topProcesses = Array(results.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(8))
    }
}
