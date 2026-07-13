import SwiftUI

// MARK: - MoleView (PLAN-V2 §7.5) — GUI clean/uninstall/optimize/analyze/status.
// Opens under the hardware strip when SSD is clicked (HardwareStrip.swift).

struct MoleView: View {
    @Bindable var engine: MoleEngine
    let monitor: HardwareMonitor
    let onClose: () -> Void

    enum Tab: String, CaseIterable { case clean = "Clean", uninstall = "Uninstall", optimize = "Optimize", analyze = "Analyze", status = "Status" }
    @State private var tab: Tab = .clean
    @State private var pending: PendingMoleAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Mole — czyszczenie i optymalizacja")
                    .font(.system(size: 8.5 + FontScale.bump, weight: .semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.ink.opacity(0.45))
                Spacer()
                Button(action: onClose) {
                    Text("✕").font(.system(size: 11 + FontScale.bump)).foregroundStyle(Color.ink.opacity(0.4))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 12)

            segmentedTabs

            Group {
                switch tab {
                case .clean: CleanTab(engine: engine, pending: $pending)
                case .uninstall: UninstallTab(engine: engine, pending: $pending)
                case .optimize: OptimizeTab(engine: engine)
                case .analyze: AnalyzeTab(engine: engine, pending: $pending)
                case .status: StatusTab(engine: engine, monitor: monitor)
                }
            }
        }
        .task(id: tab) {
            switch tab {
            case .clean: await engine.loadCleanSizes()
            case .uninstall: await engine.loadApps()
            case .analyze: await engine.loadAnalyzeCurrentDir()
            default: break
            }
        }
        .alert(item: $pending) { action in
            Alert(
                title: Text(action.title),
                message: Text(action.message),
                primaryButton: .destructive(Text(action.confirmLabel)) { Task { await action.perform(engine) } },
                secondaryButton: .cancel(Text("Anuluj"))
            )
        }
    }

    private var segmentedTabs: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { t in
                Text(t.rawValue)
                    .font(.system(size: 8.5 + FontScale.bump, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(tab == t ? Color.accent : Color.ink.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(tab == t ? Color.accent.opacity(0.16) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .onTapGesture { tab = t }
            }
        }
        .padding(2)
        .background(Color.ink.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.bottom, 14)
    }
}

// MARK: - Confirm dialog (one Identifiable enum, one alert — pattern from ProcessSection.swift)

private struct PendingMoleAction: Identifiable {
    enum Kind {
        case clean(bytes: UInt64)
        case uninstall(MoleEngine.InstalledApp)
        case trashAnalyze(MoleEngine.AnalyzeEntry)
    }
    let kind: Kind
    var id: String {
        switch kind {
        case .clean: "clean"
        case .uninstall(let app): "uninstall-\(app.id)"
        case .trashAnalyze(let e): "trash-\(e.id)"
        }
    }

    var title: String {
        switch kind {
        case .clean: "Wyczyścić zaznaczone?"
        case .uninstall(let app): "Odinstalować \(app.name)?"
        case .trashAnalyze(let e): "Przenieść \(e.name) do Kosza?"
        }
    }

    var message: String {
        switch kind {
        case .clean: "Cache/logi/instalatory trafią do Kosza (odwracalne). Kosz zostanie opróżniony trwale, jeśli jest zaznaczony."
        case .uninstall: "Aplikacja + cache/preferencje/LaunchAgents trafią do Kosza."
        case .trashAnalyze: "Element trafi do Kosza."
        }
    }

    var confirmLabel: String {
        switch kind {
        case .clean: "Wyczyść"
        case .uninstall: "Odinstaluj"
        case .trashAnalyze: "Do Kosza"
        }
    }

    func perform(_ engine: MoleEngine) async {
        switch kind {
        case .clean: await engine.runClean()
        case .uninstall(let app): await engine.uninstall(app)
        case .trashAnalyze(let entry): await engine.trashAnalyzeEntry(entry)
        }
    }
}

// MARK: - Clean tab

private struct CleanTab: View {
    @Bindable var engine: MoleEngine
    @Binding var pending: PendingMoleAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(engine.cleanCategories) { category in
                HStack(spacing: 10) {
                    checkbox(category)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(category.title).font(.system(size: 11.5 + FontScale.bump))
                        Text(category.subtitle).font(.system(size: 9 + FontScale.bump)).foregroundStyle(Color.ink.opacity(0.4))
                    }
                    Spacer()
                    if let size = category.sizeBytes {
                        Text(formatGB(size)).font(.system(size: 11 + FontScale.bump)).foregroundStyle(Color.ink.opacity(0.7)).monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small).frame(width: 40)
                    }
                }
                .padding(.vertical, 7).padding(.horizontal, 4)
            }

            if engine.isCleaning {
                ProgressView(value: engine.cleanProgress)
                    .tint(Color.accent)
                    .frame(height: 3)
                    .padding(.top, 10)
            }

            HStack {
                if let result = engine.lastCleanResultText {
                    Text(result).font(.system(size: 10 + FontScale.bump)).foregroundStyle(Color.green)
                } else {
                    Text("Zaznaczone: \(formatGB(engine.cleanSelectedTotalBytes))")
                        .font(.system(size: 10 + FontScale.bump)).foregroundStyle(Color.ink.opacity(0.55)).monospacedDigit()
                }
                Spacer()
                Button("Wyczyść") { pending = PendingMoleAction(kind: .clean(bytes: engine.cleanSelectedTotalBytes)) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11 + FontScale.bump, weight: .semibold))
                    .foregroundStyle(Color.bg)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .disabled(engine.isCleaning || engine.cleanSelectedTotalBytes == 0)
            }
            .padding(.top, 12)
        }
    }

    private func checkbox(_ category: MoleEngine.CleanCategory) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(category.isSelected ? Color.accent : .clear)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(category.isSelected ? Color.accent : Color.ink.opacity(0.3)))
            .overlay { if category.isSelected { Text("✓").font(.system(size: 9 + FontScale.bump)).foregroundStyle(Color.bg) } }
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
            .onTapGesture { engine.toggleClean(category.kind) }
    }
}

// MARK: - Uninstall tab

private struct UninstallTab: View {
    @Bindable var engine: MoleEngine
    @Binding var pending: PendingMoleAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if engine.isLoadingApps && engine.installedApps.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 20)
            } else if engine.installedApps.isEmpty {
                Text("Brak aplikacji do pokazania").font(.system(size: 10.5 + FontScale.bump)).foregroundStyle(Color.ink.opacity(0.45))
                    .padding(.vertical, 12)
            } else {
                ForEach(engine.installedApps) { app in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name).font(.system(size: 11.5 + FontScale.bump))
                            if let companion = app.companionBytes, companion > 0 {
                                Text("+ \(formatGB(companion)) plików towarzyszących").font(.system(size: 9 + FontScale.bump)).foregroundStyle(Color.ink.opacity(0.4))
                            }
                        }
                        Spacer()
                        if let size = app.sizeBytes {
                            Text(formatGB(size)).font(.system(size: 11 + FontScale.bump)).foregroundStyle(Color.ink.opacity(0.7)).monospacedDigit()
                        }
                        Button("Odinstaluj") { pending = PendingMoleAction(kind: .uninstall(app)) }
                            .buttonStyle(.plain)
                            .font(.system(size: 9.5 + FontScale.bump, weight: .semibold))
                            .foregroundStyle(Color.danger)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.danger.opacity(0.4)))
                    }
                    .padding(.vertical, 7).padding(.horizontal, 4)
                }
            }
            Text("Usuwa apkę + preferencje + cache + LaunchAgents")
                .font(.system(size: 10 + FontScale.bump)).foregroundStyle(Color.ink.opacity(0.55))
                .padding(.top, 10)
        }
    }
}

// MARK: - Optimize tab

private struct OptimizeTab: View {
    @Bindable var engine: MoleEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(engine.optimizeActions) { action in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(action.title).font(.system(size: 11.5 + FontScale.bump))
                        Text(action.subtitle).font(.system(size: 9 + FontScale.bump)).foregroundStyle(Color.ink.opacity(0.4))
                    }
                    Spacer()
                    if let result = engine.optimizeResults[action.id] {
                        Text(result)
                            .font(.system(size: 9.5 + FontScale.bump))
                            .foregroundStyle(result.hasPrefix("✓") ? Color.green : Color.danger)
                    }
                    Button(engine.optimizeRunning.contains(action.id) ? "…" : "Uruchom") {
                        Task { await engine.runOptimize(action.id) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10 + FontScale.bump, weight: .semibold))
                    .foregroundStyle(Color.txt)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.ink.opacity(0.2)))
                    .disabled(engine.optimizeRunning.contains(action.id))
                }
                .padding(.vertical, 8).padding(.horizontal, 4)
            }
        }
    }
}

// MARK: - Analyze tab

private struct AnalyzeTab: View {
    @Bindable var engine: MoleEngine
    @Binding var pending: PendingMoleAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            breadcrumb
            let maxSize = max(engine.analyzeEntries.compactMap(\.sizeBytes).max() ?? 1, 1)
            ForEach(engine.analyzeEntries) { entry in
                HStack(spacing: 10) {
                    Text(entry.sizeBytes.map { formatGB($0) } ?? "…")
                        .font(.system(size: 10.5 + FontScale.bump)).foregroundStyle(Color.txt).monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                    GeometryReader { geo in
                        Capsule().fill(Color.ink.opacity(0.08))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.accent)
                                    .frame(width: geo.size.width * CGFloat((entry.sizeBytes ?? 0)) / CGFloat(maxSize))
                            }
                    }
                    .frame(width: 96, height: 7)
                    Text(entry.name + (entry.isDirectory ? "/" : ""))
                        .font(.system(size: 11 + FontScale.bump))
                        .foregroundStyle(entry.isDirectory ? Color.blue : Color.ink.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                }
                .padding(.vertical, 5).padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onTapGesture { if entry.isDirectory { engine.analyzeNavigate(to: entry.url) } }
                .contextMenu {
                    Button("Pokaż w Finderze") { engine.revealInFinder(entry) }
                    Button("Przenieś do Kosza", role: .destructive) { pending = PendingMoleAction(kind: .trashAnalyze(entry)) }
                }
            }
            if engine.isLoadingAnalyze {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            Text("Klik = wejdź głębiej · prawy klik = pokaż w Finderze / usuń")
                .font(.system(size: 10 + FontScale.bump)).foregroundStyle(Color.ink.opacity(0.55))
                .padding(.top, 10)
        }
        .task(id: engine.analyzeCurrentDir) { await engine.loadAnalyzeCurrentDir() }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            ForEach(Array(engine.analyzeBreadcrumb.enumerated()), id: \.element) { index, url in
                if index > 0 { Text("/").font(.system(size: 10 + FontScale.bump)).foregroundStyle(Color.ink.opacity(0.3)) }
                Text(url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent)
                    .font(.system(size: 10 + FontScale.bump, weight: index == engine.analyzeBreadcrumb.count - 1 ? .semibold : .regular))
                    .foregroundStyle(index == engine.analyzeBreadcrumb.count - 1 ? Color.txt : Color.ink.opacity(0.5))
                    .onTapGesture { engine.analyzeNavigate(to: url) }
            }
        }
        .padding(.bottom, 10)
    }
}

// MARK: - Status tab (reuses DetailRow/DetailSectionLabel from HardwareStrip.swift)

private struct StatusTab: View {
    @Bindable var engine: MoleEngine
    let monitor: HardwareMonitor
    @State private var status: MoleEngine.StatusInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let status {
                DetailRow(key: "Kondycja SSD (SMART)", value: status.smartStatus ?? "brak danych",
                          valueColor: (status.smartStatus == "Verified") ? Color.green : Color.txt)
                DetailRow(key: "Ciśnienie pamięci", value: status.pressureText,
                          valueColor: status.pressureText == "normalne" ? Color.green : Color.danger)
                DetailRow(key: "Termika CPU", value: status.throttleText,
                          valueColor: status.throttleText == "brak throttlingu" ? Color.green : Color.danger)
                DetailRow(key: "Elementy startowe", value: status.launchAgentsCount.map { "\($0) LaunchAgents" } ?? "brak danych")
                DetailRow(key: "Ostatni pełny clean", value: status.lastCleanText ?? "brak danych")
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 20)
            }
        }
        .task { status = await engine.loadStatus(ramPressureLevel: monitor.ramPressureLevel) }
    }
}
