import SwiftUI

// MARK: - DashboardView (PLAN-V2 §7.2, reorder 2026-08-05 per Claude Design mockup)
//
// Vertical order: HardwareStrip → QuoteBlock → CostsBlock → StatusLine.
// StatusLine (Agenci/Ollama/Flow/version) moved to the bottom as a quiet
// footer — Paweł flagged it as clutter up top; it's still the only entry
// point to the Agents window and to launching Flow. Only Dashboard scrolls
// (§7.1) — HardwareMonitor's timer starts/stops with this view (pułapka #5).

struct DashboardView: View {
    @State private var monitor = HardwareMonitor()
    @State private var store = DashboardStore()
    @State private var services = ServiceStatus()
    @State private var agents = AgentsMonitor()

    var body: some View {
        // ponytail: an earlier pass forced this VStack to the viewport's
        // minHeight and sprinkled flexible Spacers to kill the dead zone at
        // the bottom — but HardwareStrip's 1pt-wide divider Rectangles have
        // no height of their own, so they greedily filled whatever extra
        // height the forced minHeight pushed down, stretching the whole
        // strip into empty space (Paweł caught it on screenshot). Natural,
        // unforced sizing — the fill instead comes from deliberately larger
        // fixed heights in CostsBlock's chart/model rows (see CostsBlock.swift).
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HardwareStrip(monitor: monitor)
                    .padding(.top, 18)

                QuoteBlock()
                    .padding(.top, 8)

                CostsBlock(store: store)
                    .padding(.top, 8)
                // Procesy przeniesione do panelu detali RAM (klik w RAM na
                // stripie) — decyzja Pawła 2026-08-05: psuły kompozycję.

                StatusLine(store: store, services: services, agents: agents)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 18)
            }
            // ponytail: ContentView already pads horizontal/top/bottom around
            // every page (nav clearance) — Dashboard doesn't re-pad on top of that.
        }
        .scrollIndicators(.hidden)
        .onAppear {
            monitor.start()
            store.start()
            services.start()
        }
        .onDisappear {
            monitor.stop() // pułapka #5 — must go silent off Dashboard
            services.stop()
        }
        // Full agent list moved out of the main view 2026-07-12 (it dominated
        // the first screen) — the status line's "Agenci N" opens it in a
        // sheet instead. Polling lives here so the count is live even before
        // the sheet is ever opened.
        .task {
            while !Task.isCancelled {
                await agents.poll()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }
}

// MARK: - QuoteBlock (mockup §2 — centered, own breathing room)

private struct QuoteBlock: View {
    @State private var quote: Quote?
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 6) {
            if let quote {
                Text("„\(quote.text)”")
                    .font(.system(size: 17.5 + FontScale.bump, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(Color.txt.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .lineSpacing(6.3) // line-height 1.36 @ 17.5pt
                    .fixedSize(horizontal: false, vertical: true)

                Text("— \(quote.author)")
                    .font(.system(size: 12 + FontScale.bump))
                    .foregroundStyle(Color.ink.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 6)
        .task {
            quote = await QuoteProvider.shared.nextQuote()
            withAnimation(.easeOut(duration: 0.35)) { appeared = true }
        }
    }
}

/// Git-derived build identifier stamped by Makefile — one glance tells you
/// exactly which commit is installed, no more guessing vs GitHub/disk.
/// `git describe --tags --always --dirty` can append `-N-gHASH-dirty`; UI
/// only wants the tag itself, so we cut at the first `-` (ponytail: string
/// slice over touching the Makefile, which the plan explicitly forbids).
private var appVersionLabel: String {
    let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    return raw.split(separator: "-", maxSplits: 1).first.map(String.init) ?? raw
}

/// One nowrap 9.5pt status line: service dots + model + quick actions +
/// version, quietest element last (opacity 0.25, same 9pt as the rest).
private struct StatusLine: View {
    let store: DashboardStore
    let services: ServiceStatus
    let agents: AgentsMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 5) {
            ServiceDot(alive: store.gatewayState?.isAlive ?? false)
            Text("Hermes")

            ServiceDot(alive: services.ollamaAlive)
            Text("Ollama")

            Button(action: services.launchFlow) {
                HStack(spacing: 6) {
                    ServiceDot(alive: services.flowAlive)
                    Text("Flow ↗")
                }
            }
            .buttonStyle(.plain)
            .help("Uruchom Flow w tle")

            if let model = store.configSummary?.activeModel {
                Text("· \(model)")
            }

            QuickAction(title: "Agenci \(agents.activeCount)") { openWindow(id: "agents") }

            Text("· \(appVersionLabel)")
                .foregroundStyle(Color.ink.opacity(0.25))
        }
        .font(.system(size: 9 + FontScale.bump))
        .foregroundStyle(Color.ink.opacity(0.45))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ServiceDot: View {
    let alive: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(alive ? Color.green : Color.ink.opacity(0.25))
            .frame(width: 6, height: 6)
            .shadow(color: alive ? Color.green.opacity(0.6) : .clear, radius: 3)
            .opacity(alive && pulse ? 0.45 : 1)
            .animation(alive ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { if alive { pulse = true } }
            .onChange(of: alive) { _, newValue in pulse = newValue }
    }
}

private struct QuickAction: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? Color.accent : Color.ink.opacity(0.4))
        .shadow(color: hovering ? Color.accent.opacity(0.4) : .clear, radius: 6)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .padding(.leading, 10)
    }
}

// MARK: - ServiceStatus (Ollama/Flow aliveness poll — §7.2/§11 pułapka #7)

/// Polls Ollama (localhost:11434) and Flow (127.0.0.1:8765) every 5s while
/// Dashboard is visible. Hermes aliveness comes straight from
/// `DashboardStore.gatewayState` (file+pid check, already reactive) — no
/// separate poll needed for it.
@MainActor
@Observable
final class ServiceStatus {
    private(set) var ollamaAlive = false
    private(set) var flowAlive = false

    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.pollOnce()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func pollOnce() async {
        async let ollama = Self.ping("http://localhost:11434/api/version")
        async let flow = Self.ping("http://127.0.0.1:8765/health")
        ollamaAlive = await ollama
        flowAlive = await flow
    }

    private static func ping(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    /// `-g` = don't raise Chrome (pułapka #7) — the tab opens in the background.
    func launchFlow() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-a", "Google Chrome", "https://labs.google/fx/tools/flow"]
        try? process.run()
    }
}

