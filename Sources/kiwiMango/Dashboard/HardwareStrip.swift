import SwiftUI

// MARK: - HardwareStrip (PLAN-V2 §7.2 pkt 2)
//
// 5 cells (CPU/GPU/RAM/SSD/SIEĆ) reading HardwareMonitor. Click expands one
// detail panel below the strip (only one open at a time — pułapka handled by
// `open` being a single optional, not five booleans). SSD's panel is a
// placeholder — Mole itself is Fala 3/C2.

struct HardwareStrip: View {
    let monitor: HardwareMonitor

    enum Cell: String { case cpu, gpu, ram, ssd, net }
    @State private var open: Cell?
    @State private var moleEngine = MoleEngine()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                cpuCell
                divider
                gpuCell
                divider
                ramCell
                divider
                ssdCell
                divider
                netCell
            }
            .padding(.vertical, 9)
            .overlay(alignment: .top) { Rectangle().fill(Color.ink.opacity(0.08)).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Color.ink.opacity(0.08)).frame(height: 1) }

            if let open {
                detailPanel(for: open)
                    .padding(.vertical, 16)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.ink.opacity(0.08)).frame(height: 1) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: open)
    }

    private var divider: some View {
        Rectangle().fill(Color.ink.opacity(0.08)).frame(width: 1)
    }

    private func toggle(_ cell: Cell) {
        open = (open == cell) ? nil : cell
    }

    // MARK: - Cells

    private var cpuCell: some View {
        HWCell(
            label: "CPU", tempCelsius: monitor.cpuTempCelsius,
            valueText: monitor.cpuPercent.map { plNumber($0, 0) }, unitText: "%",
            valueColor: cpuLoadColor(monitor.cpuPercent),
            history: monitor.cpuHistory, sparklineColor: Color.accent,
            isOpen: open == .cpu
        ) { toggle(.cpu) }
    }

    private var gpuCell: some View {
        HWCell(
            label: "GPU", tempCelsius: monitor.gpuTempCelsius,
            valueText: monitor.gpuDevicePercent.map { plNumber($0, 0) }, unitText: "%",
            valueColor: Color.blue,
            history: monitor.gpuHistory, sparklineColor: Color.blue,
            isOpen: open == .gpu
        ) { toggle(.gpu) }
    }

    private var ramCell: some View {
        let used = ramUsedBytes(monitor)
        let fraction = used.map { Double($0) / Double(max(monitor.ramTotalBytes, 1)) }
        return HWCell(
            label: "RAM", tempCelsius: nil,
            valueText: used.map { plNumber(Double($0) / 1e9, 1) },
            unitText: "/\(Int((Double(monitor.ramTotalBytes) / 1e9).rounded()))G",
            valueColor: Color.green,
            hairlineFraction: fraction, hairlineColor: Color.green,
            isOpen: open == .ram
        ) { toggle(.ram) }
    }

    private var ssdCell: some View {
        HWCell(
            label: "SSD", tempCelsius: nil,
            valueText: monitor.ssdAvailableBytes.map { plNumber(Double($0) / 1e9, 0) },
            unitText: "G wolne",
            valueColor: Color.txt,
            hairlineFraction: ssdUsedFraction(monitor), hairlineColor: Color.ink.opacity(0.5),
            isOpen: open == .ssd
        ) { toggle(.ssd) }
    }

    private var netCell: some View {
        HWCell(
            label: "SIEĆ", tempCelsius: nil,
            valueText: nil, unitText: "M/s",
            valueColor: Color.txt,
            history: monitor.netDownHistory, sparklineColor: Color.teal,
            netDown: monitor.netDownBytesPerSec, netUp: monitor.netUpBytesPerSec,
            isOpen: open == .net
        ) { toggle(.net) }
    }

    // MARK: - Derived (RAM/SSD)

    private func ramUsedBytes(_ m: HardwareMonitor) -> UInt64? {
        guard let app = m.ramAppBytes, let wired = m.ramWiredBytes, let compressed = m.ramCompressedBytes else { return nil }
        return app + wired + compressed
    }

    private func ssdUsedFraction(_ m: HardwareMonitor) -> Double? {
        guard let available = m.ssdAvailableBytes, let total = m.ssdTotalBytes, total > 0 else { return nil }
        return Double(total - available) / Double(total)
    }

    private func cpuLoadColor(_ percent: Double?) -> Color {
        guard let percent else { return Color.txt.opacity(0.4) }
        if percent > 85 { return Color.danger }
        if percent > 60 { return Color.accent }
        return Color.green
    }

    // MARK: - Detail panels

    @ViewBuilder
    private func detailPanel(for cell: Cell) -> some View {
        switch cell {
        case .cpu: CPUDetailPanel(monitor: monitor)
        case .gpu: GPUDetailPanel(monitor: monitor)
        case .ram: RAMDetailPanel(monitor: monitor)
        case .net: NetDetailPanel(monitor: monitor)
        case .ssd:
            MoleView(engine: moleEngine, monitor: monitor) { open = nil }
        }
    }
}

// MARK: - HWCell (one of the 5 strip cells)

private struct HWCell: View {
    let label: String
    var tempCelsius: Double? = nil
    var valueText: String? = nil
    var unitText: String = ""
    var valueColor: Color = .txt
    var history: [Double]? = nil
    var sparklineColor: Color = .accent
    var hairlineFraction: Double? = nil
    var hairlineColor: Color = .accent
    var netDown: Double? = nil
    var netUp: Double? = nil
    let isOpen: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Text(label)
                        .font(.system(size: 8.5, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Color.ink.opacity(0.45))
                    if let tempCelsius {
                        Text("\(Int(tempCelsius.rounded()))°")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.ink.opacity(0.5))
                            .monospacedDigit()
                    }
                }
                .textCase(.uppercase)

                if let netDown {
                    // ponytail: net cell has its own two-number layout (↓/↑), not the single valueText path
                    HStack(spacing: 1) {
                        Text("↓").font(.system(size: 12.5))
                        Text(plNumber(netDown / 1_000_000, 1)).foregroundStyle(Color.teal)
                        Text(" ↑").font(.system(size: 12.5))
                        Text(plNumber((netUp ?? 0) / 1_000_000, 1)).foregroundStyle(Color.rose)
                        Text(" \(unitText)").font(.system(size: 9)).foregroundStyle(Color.ink.opacity(0.5))
                    }
                    .font(.system(size: 12.5, weight: .light))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                } else if let valueText {
                    HStack(spacing: 1) {
                        Text(valueText).foregroundStyle(valueColor)
                        Text(unitText).font(.system(size: 9)).foregroundStyle(Color.ink.opacity(0.5))
                    }
                    .font(.system(size: 15, weight: .light))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                } else {
                    Text("brak danych")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.ink.opacity(0.35))
                }

                if let history {
                    Sparkline(data: history, color: sparklineColor)
                } else if let hairlineFraction {
                    HairlineBar(fraction: hairlineFraction, color: hairlineColor)
                        .frame(width: 85 * 0.01 * 100) // 85% of cell width, matches mockup
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 15)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .background(hovering || isOpen ? Color.ink.opacity(isOpen ? 0.06 : 0.04) : .clear)
        .onHover { hovering = $0 }
    }
}

// MARK: - Sparkline (Canvas — pułapka #13: size comes from the draw closure, never cached from init)

private struct Sparkline: View {
    let data: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard data.count > 1 else { return }
            let maxV = max(data.max() ?? 1, 1)
            var line = Path()
            for (i, v) in data.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(data.count - 1)
                let y = size.height - CGFloat(v / maxV) * size.height * 0.9 - 1
                if i == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(line, with: .color(color), lineWidth: 1.5)

            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [color.opacity(0.33), color.opacity(0)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)
            ))
        }
        .frame(height: 24)
        .padding(.top, 6)
    }
}

private struct HairlineBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.ink.opacity(0.15))
                Capsule().fill(color).frame(width: geo.size.width * max(0, min(fraction, 1)))
            }
        }
        .frame(height: 2)
        .padding(.top, 6)
    }
}

// MARK: - Shared detail-panel bits

/// The ring gauge used by CPU/GPU panels (§7.2). `value` 0...1.
struct DetailRing: View {
    let value: Double
    let color: Color
    let bigLabel: String
    let smallLabel: String

    var body: some View {
        ZStack {
            Circle().stroke(Color.ink.opacity(0.12), lineWidth: 5)
            Circle()
                .trim(from: 0, to: max(0, min(value, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.8), value: value)
            VStack(spacing: 1) {
                Text(bigLabel).font(.system(size: 13, weight: .light)).monospacedDigit().contentTransition(.numericText())
                Text(smallLabel).font(.system(size: 7)).tracking(0.8).textCase(.uppercase).foregroundStyle(Color.ink.opacity(0.45))
            }
        }
        .frame(width: 64, height: 64)
    }
}

/// "SECTION LABEL —————" divider used inside detail panels (`.dsec`).
struct DetailSectionLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Color.ink.opacity(0.3))
            Rectangle().fill(Color.ink.opacity(0.06)).frame(height: 1)
        }
        .padding(.vertical, 6)
    }
}

/// A "label ................ value" row (`.drow`).
struct DetailRow: View {
    let key: String
    var chip: Color? = nil
    let value: String
    var valueColor: Color = .txt

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                if let chip {
                    RoundedRectangle(cornerRadius: 2.5).fill(chip).frame(width: 8, height: 8)
                }
                Text(key).foregroundStyle(Color.ink.opacity(0.55))
            }
            Spacer()
            Text(value).foregroundStyle(valueColor).monospacedDigit().contentTransition(.numericText())
        }
        .font(.system(size: 11))
        .padding(.vertical, 4)
    }
}

// MARK: - CPU detail panel

private struct CPUDetailPanel: View {
    let monitor: HardwareMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                DetailRing(value: (monitor.cpuTempCelsius ?? 0) / 100, color: Color.accent,
                           bigLabel: monitor.cpuTempCelsius.map { "\(Int($0.rounded()))°C" } ?? "—", smallLabel: "temp")
                Spacer()
                DetailRing(value: (monitor.cpuPercent ?? 0) / 100, color: Color.accent,
                           bigLabel: monitor.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "—", smallLabel: "użycie")
                Spacer()
                DetailRing(value: (monitor.loadAvg?.0 ?? 0) / 8, color: Color.accent,
                           bigLabel: monitor.loadAvg.map { plNumber($0.0, 1) } ?? "—", smallLabel: "load")
                Spacer()
            }
            .padding(.bottom, 6)

            DetailSectionLabel(text: "Rdzenie — \(monitor.eCoreCount)E + \(monitor.pCoreCount)P")
            CoreBars(percents: monitor.perCorePercents, pCoreCount: monitor.pCoreCount)

            DetailSectionLabel(text: "Szczegóły")
            if let user = monitor.cpuUserPercent, let system = monitor.cpuSystemPercent, let idle = monitor.cpuIdlePercent {
                DetailRow(key: "System / Użytkownik / Bezczynny", value: "\(Int(system))% · \(Int(user))% · \(Int(idle))%")
            }
            if let load = monitor.loadAvg {
                DetailRow(key: "Średnie obciążenie (1/5/15 min)", value: "\(plNumber(load.0, 2)) · \(plNumber(load.1, 2)) · \(plNumber(load.2, 2))")
            }
            if let uptime = monitor.uptime {
                DetailRow(key: "Czas pracy", value: formatUptime(uptime))
            }
        }
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        return "\(h) godz. \(m) min"
    }
}

/// E/P core bars (§7.2: 4 teal E + 6 violet P, or whatever the real M4 layout is).
private struct CoreBars: View {
    let percents: [Double]
    let pCoreCount: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(percents.enumerated()), id: \.offset) { index, percent in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index < pCoreCount ? Color.coreP : Color.teal)
                    .frame(height: max(2, 36 * CGFloat(percent) / 100))
                    .animation(.easeInOut(duration: 0.7), value: percent)
            }
        }
        .frame(height: 36, alignment: .bottom)
        .padding(.vertical, 4)
    }
}

// MARK: - GPU detail panel

private struct GPUDetailPanel: View {
    let monitor: HardwareMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                DetailRing(value: (monitor.gpuDevicePercent ?? 0) / 100, color: Color.blue,
                           bigLabel: monitor.gpuDevicePercent.map { "\(Int($0.rounded()))%" } ?? "—", smallLabel: "użycie")
                Spacer()
                DetailRing(value: (monitor.gpuRendererPercent ?? 0) / 100, color: Color.blue,
                           bigLabel: monitor.gpuRendererPercent.map { "\(Int($0.rounded()))%" } ?? "—", smallLabel: "render")
                Spacer()
                DetailRing(value: (monitor.gpuTilerPercent ?? 0) / 100, color: Color.blue,
                           bigLabel: monitor.gpuTilerPercent.map { "\(Int($0.rounded()))%" } ?? "—", smallLabel: "tiler")
                Spacer()
            }
            .padding(.bottom, 6)

            DetailSectionLabel(text: "Historia użycia")
            Sparkline(data: monitor.gpuHistory, color: Color.blue).frame(height: 44)

            DetailSectionLabel(text: "Szczegóły")
            if let temp = monitor.gpuTempCelsius {
                DetailRow(key: "Temperatura", value: "\(Int(temp.rounded()))°C")
            }
        }
    }
}

// MARK: - RAM detail panel

private struct RAMDetailPanel: View {
    let monitor: HardwareMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailSectionLabel(text: pressureLabel)

            if let app = monitor.ramAppBytes, let wired = monitor.ramWiredBytes, let compressed = monitor.ramCompressedBytes {
                let total = Double(monitor.ramTotalBytes)
                let free = max(0, total - Double(app + wired + compressed))
                SplitBar(segments: [
                    (Double(app) / total, Color.accent),
                    (Double(wired) / total, Color.coreP),
                    (Double(compressed) / total, Color.rose),
                    (free / total, Color.ink.opacity(0.12)),
                ])
                DetailRow(key: "Aplikacje", chip: Color.accent, value: "\(plNumber(Double(app) / 1e9, 2)) GB")
                DetailRow(key: "Układowa (wired)", chip: Color.coreP, value: "\(plNumber(Double(wired) / 1e9, 2)) GB")
                DetailRow(key: "Skompresowana", chip: Color.rose, value: "\(plNumber(Double(compressed) / 1e9, 2)) GB")
                DetailRow(key: "Wolna", chip: Color.ink.opacity(0.25), value: "\(plNumber(free / 1e9, 2)) GB")
            }
            if let swapUsed = monitor.swapUsedBytes {
                DetailRow(key: "Pamięć wymiany (swap)", value: "\(plNumber(Double(swapUsed) / 1e9, 2)) GB")
            }

            let topByRAM = monitor.topProcesses.sorted { $0.ramBytes > $1.ramBytes }.prefix(3)
            if !topByRAM.isEmpty {
                DetailSectionLabel(text: "Top procesy — RAM")
                ForEach(Array(topByRAM), id: \.id) { proc in
                    DetailRow(key: proc.name, value: "\(plNumber(Double(proc.ramBytes) / 1e9, 2)) GB")
                }
            }
        }
    }

    private var pressureLabel: String {
        switch monitor.ramPressureLevel {
        case .some(1): return "Pamięć — presja podwyższona"
        case .some(let l) where l > 1: return "Pamięć — presja krytyczna"
        case .some: return "Pamięć — presja normalna"
        case .none: return "Pamięć"
        }
    }
}

private struct SplitBar: View {
    /// (fraction, color) segments, left to right.
    let segments: [(Double, Color)]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle().fill(segment.1).frame(width: geo.size.width * max(0, segment.0))
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .padding(.vertical, 6)
    }
}

// MARK: - Network detail panel

private struct NetDetailPanel: View {
    let monitor: HardwareMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailSectionLabel(text: "Historia — ↓ teal · ↑ róż")
            ZStack {
                Sparkline(data: monitor.netDownHistory, color: Color.teal)
                Sparkline(data: monitor.netUpHistory, color: Color.rose)
            }
            .frame(height: 44)

            DetailSectionLabel(text: "Interfejs")
            DetailRow(key: "Interfejs", value: interfaceLine)
            if let localIP = monitor.localIP { DetailRow(key: "Lokalny IP", value: localIP) }
            if let publicIP = monitor.publicIP { DetailRow(key: "Publiczny IP", value: publicIP) }
            if let latency = monitor.latencyMs { DetailRow(key: "Opóźnienie", value: "\(Int(latency.rounded())) ms") }

            DetailSectionLabel(text: "Od uruchomienia")
            DetailRow(key: "Pobrano", chip: Color.teal, value: "\(plNumber(Double(monitor.netTotalDownBytes) / 1e9, 1)) GB")
            DetailRow(key: "Wysłano", chip: Color.rose, value: "\(plNumber(Double(monitor.netTotalUpBytes) / 1e9, 1)) GB")
        }
    }

    private var interfaceLine: String {
        guard let name = monitor.netInterfaceName else { return "brak danych" }
        if let ssid = monitor.wifiSSID { return "Wi-Fi (\(name)) · \(ssid)" }
        return "Wi-Fi (\(name))"
    }
}

// MARK: - Shared number formatting (PL locale — comma decimal separator, per mockup)

func plNumber(_ value: Double, _ decimals: Int) -> String {
    String(format: "%.\(decimals)f", value).replacingOccurrences(of: ".", with: ",")
}
