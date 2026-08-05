import SwiftUI

// MARK: - HardwareStrip (PLAN-V2 §7.2 pkt 2)
//
// 5 cells (CPU/GPU/RAM/SSD/SIEĆ) reading HardwareMonitor. Exactly one detail
// panel is always shown below the strip, in a fixed-height container so
// switching panels never reflows the layout (default: RAM, per mockup).
// SSD and RAM are special: a second click while one of them is already open
// swaps its stats panel for an alt view (`altViewOpen`) — SSD → Mole game,
// RAM → process list. CPU/GPU/SIEĆ have no alt view.

struct HardwareStrip: View {
    let monitor: HardwareMonitor

    enum Cell: String { case cpu, gpu, ram, ssd, net }
    // ponytail: always one panel open (default RAM per mockup) — a nil
    // state made the whole strip layout jump on close, which Paweł's mockup
    // doesn't have. Fixed-height container below absorbs any size delta
    // between panels instead.
    @State private var open: Cell = .ram
    @State private var altViewOpen = false
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
            // ponytail: the divider Rectangles below only set a width, so
            // they're happy to stretch to whatever height a parent proposes
            // (that's what turned this row into a tall empty strip once —
            // see DashboardView.swift). fixedSize pins the row to its own
            // content height no matter what the parent offers.
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .top) { Rectangle().fill(Color.ink.opacity(0.08)).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Color.ink.opacity(0.08)).frame(height: 1) }

            // 160 not the mockup's 148 — global FontScale.bump = 2 makes
            // every line in the panels a touch taller.
            VStack(alignment: .leading, spacing: 0) {
                detailPanel(for: open)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .frame(height: 160)
            .clipped()
            .overlay(alignment: .bottom) { Rectangle().fill(Color.ink.opacity(0.08)).frame(height: 1) }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: open)
    }

    private var divider: some View {
        Rectangle().fill(Color.ink.opacity(0.08)).frame(width: 1)
    }

    private func select(_ cell: Cell) {
        // ponytail: second click on an already-open cell that has an alt
        // view reveals it (SSD → mole game, RAM → process list) instead of
        // the stats panel; picking any other cell always resets
        // altViewOpen so no alt view lingers behind another panel. CPU/GPU/
        // SIEĆ have no alt view, so a second click on them is a no-op.
        if cell == open, hasAltView(cell) {
            altViewOpen = true
        } else {
            altViewOpen = false
            open = cell
        }
    }

    private func hasAltView(_ cell: Cell) -> Bool {
        cell == .ssd || cell == .ram
    }

    // MARK: - Cells

    private var cpuCell: some View {
        HWCell(
            label: "CPU", tempCelsius: monitor.cpuTempCelsius,
            valueText: monitor.cpuPercent.map { plNumber($0, 0) }, unitText: "%",
            valueColor: cpuLoadColor(monitor.cpuPercent),
            history: monitor.cpuHistory, sparkColor: cpuLoadColor(monitor.cpuPercent),
            isOpen: open == .cpu
        ) { select(.cpu) }
    }

    private var gpuCell: some View {
        HWCell(
            label: "GPU", tempCelsius: monitor.gpuTempCelsius,
            valueText: monitor.gpuDevicePercent.map { plNumber($0, 0) }, unitText: "%",
            valueColor: Color.blue,
            history: monitor.gpuHistory, sparkColor: Color.blue,
            isOpen: open == .gpu
        ) { select(.gpu) }
    }

    private var ramCell: some View {
        let used = ramUsedBytes(monitor)
        return HWCell(
            label: "RAM", tempCelsius: nil,
            valueText: used.map { plNumber(Double($0) / 1e9, 1) },
            unitText: "/\(Int((Double(monitor.ramTotalBytes) / 1e9).rounded()))G",
            valueColor: Color.green,
            history: monitor.ramHistory, sparkColor: Color.green,
            isOpen: open == .ram
        ) { select(.ram) }
    }

    private var ssdCell: some View {
        HWCell(
            label: "SSD", tempCelsius: nil,
            valueText: monitor.ssdAvailableBytes.map { plNumber(Double($0) / 1e9, 0) },
            unitText: "G wolne",
            valueColor: Color.txt,
            history: monitor.ssdHistory, sparkColor: Color.teal,
            isOpen: open == .ssd
        ) { select(.ssd) }
    }

    private var netCell: some View {
        HWCell(
            label: "SIEĆ", tempCelsius: nil,
            valueText: nil, unitText: "M/s",
            valueColor: Color.txt,
            history: monitor.netDownHistory, sparkColor: Color.teal,
            netDown: monitor.netDownBytesPerSec, netUp: monitor.netUpBytesPerSec,
            isOpen: open == .net
        ) { select(.net) }
    }

    // MARK: - Derived (RAM/SSD)

    private func ramUsedBytes(_ m: HardwareMonitor) -> UInt64? {
        guard let app = m.ramAppBytes, let wired = m.ramWiredBytes, let compressed = m.ramCompressedBytes else { return nil }
        return app + wired + compressed
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
        case .ram:
            if altViewOpen {
                ProcessSection(hardware: monitor, compact: true)
            } else {
                RAMDetailPanel(monitor: monitor)
            }
        case .net: NetDetailPanel(monitor: monitor)
        case .ssd:
            if altViewOpen {
                MoleView(engine: moleEngine, monitor: monitor) { altViewOpen = false }
            } else {
                SSDDetailPanel(monitor: monitor)
            }
        }
    }
}

// MARK: - HWCell (one of the 5 strip cells)

// ponytail: unified 2026-08-05 — every cell renders the exact same three
// rows — label(+temp) → value+unit → a mini area-chart sparkline (CellSpark,
// below) plotting that cell's own history — so the strip reads as one
// instrument, not five different widgets.
private struct HWCell: View {
    let label: String
    var tempCelsius: Double? = nil
    var valueText: String? = nil
    var unitText: String = ""
    var valueColor: Color = .txt
    var history: [Double] = []
    var sparkColor: Color = .accent
    var netDown: Double? = nil
    var netUp: Double? = nil
    let isOpen: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 3) {
                    Text(label)
                        .font(.system(size: 8.5 + FontScale.bump, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Color.ink.opacity(0.45))
                    if let tempCelsius {
                        Text("\(Int(tempCelsius.rounded()))°")
                            .font(.system(size: 9 + FontScale.bump))
                            .foregroundStyle(Color.ink.opacity(0.5))
                            .monospacedDigit()
                    }
                }
                .textCase(.uppercase)

                if let netDown {
                    // ponytail: net cell has its own two-number layout (↓/↑), not the single valueText path
                    HStack(spacing: 1) {
                        Text("↓").font(.system(size: 12.5 + FontScale.bump))
                        Text(plNumber(netDown / 1_000_000, 1)).foregroundStyle(Color.teal)
                        Text(" ↑").font(.system(size: 12.5 + FontScale.bump))
                        Text(plNumber((netUp ?? 0) / 1_000_000, 1)).foregroundStyle(Color.rose)
                        Text(" \(unitText)").font(.system(size: 9 + FontScale.bump)).foregroundStyle(Color.ink.opacity(0.5))
                    }
                    .font(.system(size: 12.5 + FontScale.bump, weight: .light))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                } else if let valueText {
                    HStack(spacing: 1) {
                        Text(valueText).foregroundStyle(valueColor)
                        Text(unitText).font(.system(size: 9 + FontScale.bump)).foregroundStyle(Color.ink.opacity(0.5))
                    }
                    .font(.system(size: 15 + FontScale.bump, weight: .light))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                } else {
                    Text("brak danych")
                        .font(.system(size: 10 + FontScale.bump))
                        .foregroundStyle(Color.ink.opacity(0.35))
                }

                CellSpark(data: history, color: sparkColor)
                    .frame(height: 20)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .contentShape(Rectangle()) // ponytail: cała komórka klikalna, nie tylko tekst
        }
        .buttonStyle(.plain)
        .background(hovering || isOpen ? Color.ink.opacity(isOpen ? 0.06 : 0.04) : .clear)
        .onHover { hovering = $0 }
    }
}

// MARK: - Sparkline (Canvas — pułapka #13: size comes from the draw closure, never cached from init)
//
// ponytail: labels are a thin overlay — the max label sits top-right, the
// current value bottom-right, the unit is passed by the caller so the same
// Sparkline works for %, MB/s, and dimensionless GPU utilization.

private struct Sparkline: View {
    let data: [Double]
    let color: Color
    var unit: String = ""   // e.g. "%", "MB/s" — shown next to current value
    var height: CGFloat = 24

    var body: some View {
        let maxV = max(data.max() ?? 0, 0.1)
        let current = data.last ?? 0
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Text(unit.isEmpty ? "" : String(format: "%.0f", maxV))
                    .font(.system(size: 7 + FontScale.bump, weight: .medium))
                    .foregroundStyle(Color.ink.opacity(0.3))
                    .monospacedDigit()
                if !unit.isEmpty { Text(unit).font(.system(size: 6.5 + FontScale.bump)).foregroundStyle(Color.ink.opacity(0.25)) }
                Spacer()
                Text(String(format: "%.0f", current))
                    .font(.system(size: 7 + FontScale.bump, weight: .semibold))
                    .foregroundStyle(color.opacity(0.8))
                    .monospacedDigit()
            }
            Canvas { context, size in
                guard data.count > 1 else {
                    context.draw(Text("brak").font(.system(size: 8 + FontScale.bump)).foregroundColor(Color.ink.opacity(0.25)),
                                 at: CGPoint(x: size.width / 2, y: size.height / 2))
                    return
                }
                var line = Path()
                for (i, v) in data.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(data.count - 1)
                    let y = size.height - CGFloat(v / maxV) * size.height * 0.85 - 1
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

                // ponytail: current-value dot — gives the eye a "where are we now" anchor
                if let lastPoint = data.indices.last {
                    let x = size.width
                    let y = size.height - CGFloat(data[lastPoint] / maxV) * size.height * 0.85 - 1
                    context.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: y - 2.5, width: 4, height: 4)),
                                 with: .color(color))
                }
            }
            .frame(height: height)
        }
    }
}

// ponytail: mini area chart for the strip cells — no min/max/current labels
// (Paweł already had us strip those once from the panel Sparkline; this one
// never had them). Scale = data max, floor = 0, stretched to the cell width
// (no aspect-ratio preservation, matching the mockup's `preserveAspectRatio:
// none`).
private struct CellSpark: View {
    let data: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard data.count > 1 else { return }
            let maxV = max(data.max() ?? 0, 0.1)

            var line = Path()
            for (i, v) in data.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(data.count - 1)
                let y = size.height - CGFloat(v / maxV) * size.height
                if i == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(line, with: .color(color), lineWidth: 1.4)

            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(color.opacity(0.16)))
        }
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
                Text(bigLabel).font(.system(size: 13 + FontScale.bump, weight: .light)).monospacedDigit().contentTransition(.numericText())
                Text(smallLabel).font(.system(size: 7 + FontScale.bump)).tracking(0.8).textCase(.uppercase).foregroundStyle(Color.ink.opacity(0.45))
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
                .font(.system(size: 8 + FontScale.bump, weight: .semibold))
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
        .font(.system(size: 11 + FontScale.bump))
        .padding(.vertical, 4)
    }
}

// MARK: - CPU detail panel

private struct CPUDetailPanel: View {
    let monitor: HardwareMonitor

    var body: some View {
        // ponytail: mockup layout is horizontal — [ring temp] [ring użycie]
        // [flex column: rdzenie + load]. The old vertical stack spaced the
        // rings out with Spacers across the full width and stretched the
        // core bars into horizontal stripes; this HStack fixes both.
        HStack(alignment: .center, spacing: 20) {
            DetailRing(value: (monitor.cpuTempCelsius ?? 0) / 100, color: Color.accent,
                       bigLabel: monitor.cpuTempCelsius.map { "\(Int($0.rounded()))°C" } ?? "—", smallLabel: "temp")
            DetailRing(value: (monitor.cpuPercent ?? 0) / 100, color: Color.accent,
                       bigLabel: monitor.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "—", smallLabel: "użycie")

            // ponytail: mockup CPU panel = 2 pierścienie + słupki rdzeni +
            // jedna linia "Load 1 min · uptime". Trzeci pierścień (load) i
            // osobne wiersze user/system/idle wycięte — przy stałych 160pt
            // (fixed-height panel container) nie mieściły się wszystkie
            // dawne wiersze naraz; surowe dane zostają w monitorze.
            VStack(alignment: .leading, spacing: 0) {
                Text("RDZENIE — \(monitor.eCoreCount)E + \(monitor.pCoreCount)P")
                    .font(.system(size: 8 + FontScale.bump, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(Color.ink.opacity(0.3))
                    .padding(.bottom, 5)

                CoreBars(percents: monitor.perCorePercents, pCoreCount: monitor.pCoreCount)

                if let load = monitor.loadAvg, let uptime = monitor.uptime {
                    (Text("Load 1 min: ").foregroundStyle(Color.ink.opacity(0.55))
                        + Text(plNumber(load.0, 2)).foregroundStyle(Color.txt)
                        + Text(" · \(formatUptime(uptime))").foregroundStyle(Color.ink.opacity(0.55)))
                        .font(.system(size: 10 + FontScale.bump))
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(percents.enumerated()), id: \.offset) { index, percent in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index < pCoreCount ? Color.coreP : Color.teal)
                    .frame(width: 8, height: max(2, 22 * CGFloat(percent) / 100))
                    .animation(.easeInOut(duration: 0.7), value: percent)
            }
        }
        .frame(height: 22, alignment: .bottom)
    }
}

// MARK: - GPU detail panel

private struct GPUDetailPanel: View {
    let monitor: HardwareMonitor

    var body: some View {
        // ponytail: same horizontal skeleton as CPUDetailPanel — [ring
        // użycie] [ring temp] [flex column: historia].
        HStack(alignment: .center, spacing: 20) {
            DetailRing(value: (monitor.gpuDevicePercent ?? 0) / 100, color: Color.blue,
                       bigLabel: monitor.gpuDevicePercent.map { "\(Int($0.rounded()))%" } ?? "—", smallLabel: "użycie")
            DetailRing(value: (monitor.gpuTempCelsius ?? 0) / 100, color: Color.blue,
                       bigLabel: monitor.gpuTempCelsius.map { "\(Int($0.rounded()))°C" } ?? "—", smallLabel: "temp")

            // ponytail: mockup GPU panel = 2 pierścienie + historia.
            // Renderer/tiler pierścienie i osobny wiersz "Szczegóły" wycięte
            // — nie mieszczą się w stałych 160pt razem z historią; te dwie
            // wartości nadal czytane w HardwareMonitor gdyby miały wrócić.
            VStack(alignment: .leading, spacing: 0) {
                Text("HISTORIA UŻYCIA")
                    .font(.system(size: 8 + FontScale.bump, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(Color.ink.opacity(0.3))
                    .padding(.bottom, 5)

                Sparkline(data: monitor.gpuHistory, color: Color.blue, unit: "%", height: 44)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
                // ponytail: mockup pairs the 4 legend items into 2 rows of 2
                // (Aplikacje+Układowa, Skompresowana+Wolna) — RAMLegendItem
                // below is the "krótszy" of the two options the task offered.
                HStack(spacing: 14) {
                    RAMLegendItem(color: Color.accent, name: "Aplikacje", value: "\(plNumber(Double(app) / 1e9, 2)) GB")
                    RAMLegendItem(color: Color.coreP, name: "Układowa", value: "\(plNumber(Double(wired) / 1e9, 2)) GB")
                    Spacer()
                }
                HStack(spacing: 14) {
                    RAMLegendItem(color: Color.rose, name: "Skompresowana", value: "\(plNumber(Double(compressed) / 1e9, 2)) GB")
                    RAMLegendItem(color: Color.ink.opacity(0.25), name: "Wolna", value: "\(plNumber(free / 1e9, 2)) GB")
                    Spacer()
                }
            }
            if let swapUsed = monitor.swapUsedBytes {
                Text("Pamięć wymiany (swap): \(plNumber(Double(swapUsed) / 1e9, 2)) GB")
                    .font(.system(size: 11 + FontScale.bump))
                    .foregroundStyle(Color.ink.opacity(0.55))
                    .padding(.top, 6)
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

/// One "chip · name · value" legend entry, two of which sit side by side in
/// the RAM panel (§4 of the mockup pass — replaces the old one-per-row DetailRow).
private struct RAMLegendItem: View {
    let color: Color
    let name: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
            Text(name).foregroundStyle(Color.ink.opacity(0.55))
            Text(value).foregroundStyle(Color.txt).monospacedDigit().contentTransition(.numericText())
        }
        .font(.system(size: 11 + FontScale.bump))
        .padding(.vertical, 2)
    }
}

// MARK: - SSD detail panel

/// Disk stats — shown while `open == .ssd` and the mole game hasn't been
/// summoned by a second click (see `HardwareStrip.select`).
private struct SSDDetailPanel: View {
    let monitor: HardwareMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailSectionLabel(text: "Dysk")

            if let available = monitor.ssdAvailableBytes, let total = monitor.ssdTotalBytes, total > 0 {
                let used = Double(total) - Double(available)
                SplitBar(segments: [
                    (used / Double(total), Color.ink.opacity(0.3)),
                    (Double(available) / Double(total), Color.teal),
                ])
                HStack {
                    Text("Zajęte \(plNumber(used / 1e9, 0)) G").foregroundStyle(Color.ink.opacity(0.55))
                    Spacer()
                    Text("Wolne \(plNumber(Double(available) / 1e9, 0)) G").foregroundStyle(Color.teal)
                    Spacer()
                    Text("Całość \(plNumber(Double(total) / 1e9, 0)) G").foregroundStyle(Color.ink.opacity(0.55))
                }
                .font(.system(size: 11 + FontScale.bump))
                .monospacedDigit()
                .padding(.top, 8)
            } else {
                Text("brak danych")
                    .font(.system(size: 10 + FontScale.bump))
                    .foregroundStyle(Color.ink.opacity(0.35))
            }
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
            DetailSectionLabel(text: "Historia — ↓ teal · ↑ róż (MB/s)")
            ZStack {
                Sparkline(data: monitor.netDownHistory, color: Color.teal, unit: "MB/s", height: 44)
                Sparkline(data: monitor.netUpHistory, color: Color.rose, unit: "", height: 44)
            }
            .frame(height: 44)

            // ponytail: mockup SIEĆ = historia + jedna linia interfejs/ping +
            // jedna linia suma od uruchomienia. Osobne wiersze lokalny/
            // publiczny IP wycięte — nie mieszczą się w 160pt obok historii;
            // monitor.localIP/publicIP wciąż czytane, gdyby wróciły do UI.
            Text(interfaceAndPingLine)
                .font(.system(size: 11 + FontScale.bump))
                .foregroundStyle(Color.ink.opacity(0.55))
                .monospacedDigit()
                .padding(.top, 10)

            Text("Od uruchomienia — ↓ \(plNumber(Double(monitor.netTotalDownBytes) / 1e9, 1)) GB · ↑ \(plNumber(Double(monitor.netTotalUpBytes) / 1e9, 1)) GB")
                .font(.system(size: 11 + FontScale.bump))
                .foregroundStyle(Color.ink.opacity(0.55))
                .monospacedDigit()
                .padding(.top, 4)
        }
    }

    private var interfaceAndPingLine: String {
        let base: String
        if let name = monitor.netInterfaceName {
            base = monitor.wifiSSID.map { "Wi-Fi (\(name)) · \($0)" } ?? "Wi-Fi (\(name))"
        } else {
            base = "brak danych"
        }
        guard let latency = monitor.latencyMs else { return base }
        return "\(base) · \(Int(latency.rounded())) ms"
    }
}

// MARK: - Shared number formatting (PL locale — comma decimal separator, per mockup)

func plNumber(_ value: Double, _ decimals: Int) -> String {
    String(format: "%.\(decimals)f", value).replacingOccurrences(of: ".", with: ",")
}
