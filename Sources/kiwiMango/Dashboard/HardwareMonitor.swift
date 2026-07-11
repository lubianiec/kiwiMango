import Darwin
import Foundation
import IOKit
import Network
import Observation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreWLAN)
import CoreWLAN
#endif

// MARK: - HardwareMonitor (§6 PLAN-V2)
//
// @Observable snapshot of local hardware. Pure data layer — no UI here.
// Timer is started/stopped from the OUTSIDE (Dashboard onAppear/onDisappear,
// pułapka #5) — never auto-starts in init, otherwise it burns CPU while the
// user is on Agent/Chat.
//
// Every reader degrades to nil on failure (pułapka #1/#2/#3): missing data
// is hidden, never faked as zero.
@MainActor
@Observable
final class HardwareMonitor {

    // MARK: CPU

    private(set) var cpuPercent: Double?
    /// Per logical core, in host_processor_info order.
    private(set) var perCorePercents: [Double] = []
    private(set) var eCoreCount: Int = 0
    private(set) var pCoreCount: Int = 0
    private(set) var loadAvg: (Double, Double, Double)?
    private(set) var uptime: TimeInterval?
    private(set) var cpuTempCelsius: Double?

    // MARK: GPU

    private(set) var gpuTempCelsius: Double?
    private(set) var gpuDevicePercent: Double?
    private(set) var gpuRendererPercent: Double?
    private(set) var gpuTilerPercent: Double?

    // MARK: RAM

    private(set) var ramAppBytes: UInt64?
    private(set) var ramWiredBytes: UInt64?
    private(set) var ramCompressedBytes: UInt64?
    private(set) var ramTotalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    /// 0 normal, from sysctl kern.memorystatus_vm_pressure_level (1 warn, 4 critical — see Apple headers).
    private(set) var ramPressureLevel: Int32?
    private(set) var swapUsedBytes: UInt64?
    private(set) var swapTotalBytes: UInt64?

    // MARK: SSD

    private(set) var ssdAvailableBytes: Int64?
    private(set) var ssdTotalBytes: Int64?

    // MARK: Network

    private(set) var netDownBytesPerSec: Double?
    private(set) var netUpBytesPerSec: Double?
    private(set) var netInterfaceName: String?
    private(set) var wifiSSID: String?
    private(set) var localIP: String?
    private(set) var publicIP: String?
    private(set) var latencyMs: Double?
    private(set) var netTotalDownBytes: UInt64 = 0
    private(set) var netTotalUpBytes: UInt64 = 0

    // MARK: Processes

    struct TopProcess: Identifiable {
        let id: pid_t
        let name: String
        let cpuPercent: Double
        let ramBytes: UInt64
        let bundleID: String?
    }
    private(set) var topProcesses: [TopProcess] = []

    // MARK: Lifecycle

    private var timer: Timer?
    private var lastCPUTicks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)]?
    private var lastNetSample: (time: Date, inBytes: UInt64, outBytes: UInt64)?
    private var lastProcSample: [pid_t: (userTime: UInt64, systemTime: UInt64)] = [:]
    private var lastProcSampleTime: Date?
    private var didFetchPublicIP = false

    init() {
        (eCoreCount, pCoreCount) = Self.readPerfLevels()
    }

    /// Starts the 2s refresh. Call from Dashboard `.onAppear`.
    func start() {
        stop()
        tick() // immediate first read so the UI isn't empty for 2s
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Stops the timer. Call from Dashboard `.onDisappear` — pułapka #5:
    /// without this the app keeps polling hardware while on Agent/Chat.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        readCPU()
        readLoadAndUptime()
        readTemperatures()
        readGPU()
        readRAM()
        readSSD()
        readNetwork()
        readTopProcesses()
        if !didFetchPublicIP {
            didFetchPublicIP = true
            fetchPublicIP()
        }
        measureLatency()
    }

    // MARK: - CPU

    private static func readPerfLevels() -> (e: Int, p: Int) {
        // ponytail: perflevel0 = P-cores, perflevel1 = E-cores per Apple's
        // sysctl convention; host_processor_info core ordering on Apple
        // Silicon puts P-cores first. If this ever mismatches the UI split,
        // it's cosmetic only — counts themselves are still correct.
        let p = sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        let e = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        return (e, p)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value: Int32 = 0
        var actualSize = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &actualSize, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private func readCPU() {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount)
        guard result == KERN_SUCCESS, let infoArray else {
            cpuPercent = nil
            perCorePercents = []
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
            perCorePercents = []
            return
        }

        var perCore: [Double] = []
        var totalUsed: Double = 0
        var totalAll: Double = 0
        for (prev, now) in zip(previous, ticksNow) {
            let used = Double(diff(now.user, prev.user) + diff(now.system, prev.system) + diff(now.nice, prev.nice))
            let idle = Double(diff(now.idle, prev.idle))
            let total = used + idle
            perCore.append(total > 0 ? (used / total) * 100 : 0)
            totalUsed += used
            totalAll += total
        }
        lastCPUTicks = ticksNow
        perCorePercents = perCore
        cpuPercent = totalAll > 0 ? (totalUsed / totalAll) * 100 : nil
    }

    private func diff(_ now: UInt32, _ prev: UInt32) -> UInt32 {
        // Counters are monotonic increasing; guard against odd wraparound.
        now >= prev ? now - prev : 0
    }

    private func readLoadAndUptime() {
        var avg = [Double](repeating: 0, count: 3)
        if getloadavg(&avg, 3) == 3 {
            loadAvg = (avg[0], avg[1], avg[2])
        } else {
            loadAvg = nil
        }

        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boottime, &size, nil, 0) == 0 {
            let bootDate = Date(timeIntervalSince1970: Double(boottime.tv_sec) + Double(boottime.tv_usec) / 1_000_000)
            uptime = Date().timeIntervalSince(bootDate)
        } else {
            uptime = nil
        }
    }

    // MARK: - Temperatures (IOHIDEventSystemClient, prywatne API)

    private func readTemperatures() {
        // Pułapka #1: private symbols, resolved via dlsym. Any failure →
        // hide the field. Never surface a fake 0°.
        guard let client = HIDTemperature.makeClient() else {
            cpuTempCelsius = nil
            gpuTempCelsius = nil
            return
        }
        let readings = HIDTemperature.readAll(client: client)
        cpuTempCelsius = HIDTemperature.averageMatching(readings, containing: ["tdie", "tcxo", "pmu tdie"])
        gpuTempCelsius = HIDTemperature.averageMatching(readings, containing: ["gpu"])
    }

    // MARK: - GPU

    private func readGPU() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            gpuDevicePercent = nil
            gpuRendererPercent = nil
            gpuTilerPercent = nil
            return
        }
        defer { IOObjectRelease(iterator) }

        var device: Double?
        var renderer: Double?
        var tiler: Double?

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
                else if key.hasPrefix("Renderer") { renderer = percent }
                else if key.hasPrefix("Tiler") { tiler = percent }
            }
        }

        gpuDevicePercent = device
        gpuRendererPercent = renderer
        gpuTilerPercent = tiler
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

        ramPressureLevel = Self.sysctlInt32("kern.memorystatus_vm_pressure_level")

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            swapUsedBytes = swap.xsu_used
            swapTotalBytes = swap.xsu_total
        } else {
            swapUsedBytes = nil
            swapTotalBytes = nil
        }
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
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
        var ip: String?

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let name = String(cString: interface.ifa_name)
            guard name == "en0" else { continue }

            let family = interface.ifa_addr.pointee.sa_family
            // ponytail: byte counters live on the AF_LINK entry (if_data),
            // the address itself is on a separate AF_INET entry for the
            // same interface name — bug found via the sanity-check run.
            if family == UInt8(AF_LINK), let data = interface.ifa_data {
                let netData = data.withMemoryRebound(to: if_data.self, capacity: 1) { $0.pointee }
                inBytes = UInt64(netData.ifi_ibytes)
                outBytes = UInt64(netData.ifi_obytes)
            }
            if family == UInt8(AF_INET) {
                var addr = interface.ifa_addr.pointee
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    ip = String(cString: host)
                }
            }
        }

        netInterfaceName = (inBytes != nil) ? "en0" : nil
        localIP = ip

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
            netTotalDownBytes = inBytes
            netTotalUpBytes = outBytes
        } else {
            netDownBytesPerSec = nil
            netUpBytesPerSec = nil
        }

        readSSID()
    }

    private func readSSID() {
        #if canImport(CoreWLAN)
        // Pułapka #3: SSID requires Location permission on Sonoma+. Never
        // prompt for it — if nil, UI just shows "Wi-Fi (en0)" without SSID.
        wifiSSID = CWWiFiClient.shared().interface()?.ssid()
        #else
        wifiSSID = nil
        #endif
    }

    private func fetchPublicIP() {
        guard let url = URL(string: "https://api.ipify.org") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self, error == nil, let data, let ip = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self.publicIP = ip }
        }.resume()
    }

    /// ponytail: tiny reference box so the Sendable closure below has a
    /// single mutable cell instead of a captured local var.
    private final class SettledFlag: @unchecked Sendable {
        var value = false
    }

    private func measureLatency() {
        let start = Date()
        let connection = NWConnection(host: "1.1.1.1", port: 443, using: .tcp)
        let settled = SettledFlag()
        connection.stateUpdateHandler = { [weak self] state in
            guard !settled.value else { return }
            switch state {
            case .ready:
                settled.value = true
                let elapsed = Date().timeIntervalSince(start) * 1000
                Task { @MainActor in self?.latencyMs = elapsed }
                connection.cancel()
            case .failed:
                settled.value = true
                Task { @MainActor in self?.latencyMs = nil }
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if !settled.value { connection.cancel() }
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

            #if canImport(AppKit)
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            #else
            let bundleID: String? = nil
            #endif

            results.append(TopProcess(id: pid, name: name, cpuPercent: cpuPercent, ramBytes: usage.ri_phys_footprint, bundleID: bundleID))
        }

        lastProcSample = newSample
        lastProcSampleTime = now
        topProcesses = Array(results.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(5))
    }
}

// MARK: - HIDTemperature (private IOHIDEventSystemClient bridge)
//
// ponytail: no public SMC API on Apple Silicon. This mirrors the
// widely-used community pattern (dlsym against IOKit's private HID sensor
// client) — kept in one small enum so a failure anywhere just returns nil.
private enum HIDTemperature {
    private typealias CreateFn = @convention(c) (CFAllocator?, Int32, CFDictionary?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?

    struct Reading { let name: String; let celsius: Double }

    static func makeClient() -> AnyObject? {
        guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
        guard let createSym = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let matchSym = dlsym(handle, "IOHIDEventSystemClientSetMatching") else { return nil }

        let create = unsafeBitCast(createSym, to: CreateFn.self)
        let setMatching = unsafeBitCast(matchSym, to: SetMatchingFn.self)

        guard let client = create(kCFAllocatorDefault, 0, nil) else { return nil }
        let matching: [String: Any] = ["PrimaryUsagePage": 0xFF00, "PrimaryUsageID": 0x0005]
        setMatching(client.takeUnretainedValue(), matching as CFDictionary)
        return client.takeUnretainedValue()
    }

    static func readAll(client: AnyObject) -> [Reading] {
        guard let handle = dlopen(nil, RTLD_NOW),
              let copyServicesSym = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let copyEventSym = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let getFloatSym = dlsym(handle, "IOHIDEventGetFloatValue"),
              let copyPropSym = dlsym(handle, "IOHIDServiceClientCopyProperty") else { return [] }

        let copyServices = unsafeBitCast(copyServicesSym, to: CopyServicesFn.self)
        let copyEvent = unsafeBitCast(copyEventSym, to: CopyEventFn.self)
        let getFloat = unsafeBitCast(getFloatSym, to: GetFloatFn.self)
        let copyProperty = unsafeBitCast(copyPropSym, to: CopyPropertyFn.self)

        guard let servicesRef = copyServices(client) else { return [] }
        let services = servicesRef.takeRetainedValue() as [AnyObject]

        let kIOHIDEventTypeTemperature: Int64 = 15
        let eventField = (kIOHIDEventTypeTemperature << 16) // IOHIDEventFieldBase

        var readings: [Reading] = []
        for service in services {
            guard let nameRef = copyProperty(service, "Product" as CFString) else { continue }
            let name = (nameRef.takeRetainedValue() as? String) ?? ""
            guard let eventRef = copyEvent(service, kIOHIDEventTypeTemperature, 0, 0) else { continue }
            let value = getFloat(eventRef.takeRetainedValue(), Int32(eventField))
            if value.isFinite, value > 0, value < 150 {
                readings.append(Reading(name: name, celsius: value))
            }
        }
        return readings
    }

    static func averageMatching(_ readings: [Reading], containing needles: [String]) -> Double? {
        let matches = readings.filter { reading in
            let lower = reading.name.lowercased()
            return needles.contains { lower.contains($0) }
        }
        guard !matches.isEmpty else { return nil }
        return matches.map(\.celsius).reduce(0, +) / Double(matches.count)
    }
}
