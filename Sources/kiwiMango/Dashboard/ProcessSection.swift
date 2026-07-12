import AppKit
import Darwin
import SwiftUI

// MARK: - ProcessSection ("03 PROCESY", PLAN-V2 §7.2 pt.5)
//
// Reads `HardwareMonitor.topProcesses` (already computed by Fala 1 — no
// second process scan here). `hardware` is passed in by whoever owns the
// HardwareMonitor instance (the hardware strip) so both views share one
// 2s-timer/one process snapshot instead of running two scanners.
struct ProcessSection: View {
    let hardware: HardwareMonitor

    @State private var openPopoverPID: pid_t?
    @State private var pendingAction: PendingProcessAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead("03", "Procesy") {
                Text("top \(hardware.topProcesses.count) · CPU").font(KiwiMangoFont.sans(9.5)).foregroundStyle(Color.ink.opacity(0.55))
            }

            HStack(spacing: 10) {
                Spacer().frame(width: 18)
                Text("Nazwa").frame(maxWidth: .infinity, alignment: .leading)
                Text("PID").frame(width: 48, alignment: .trailing)
                Text("CPU").frame(width: 52, alignment: .trailing)
                Text("RAM").frame(width: 58, alignment: .trailing)
                Spacer().frame(width: 46)
            }
            .font(KiwiMangoFont.sans(8, weight: .semibold)).tracking(1).textCase(.uppercase)
            .foregroundStyle(Color.ink.opacity(0.3))
            .padding(.bottom, 6)

            if hardware.topProcesses.isEmpty {
                Text("brak danych").font(KiwiMangoFont.sans(10)).foregroundStyle(Color.ink.opacity(0.45))
            } else {
                ForEach(hardware.topProcesses) { process in
                    processRow(process)
                }
            }
        }
        .alert(item: $pendingAction) { action in
            Alert(
                title: Text(action.title),
                message: Text(action.message),
                primaryButton: action.isDestructive ? .destructive(Text(action.confirmLabel)) { action.perform() }
                                                     : .default(Text(action.confirmLabel)) { action.perform() },
                secondaryButton: .cancel(Text("Anuluj"))
            )
        }
    }

    private func processRow(_ process: HardwareMonitor.TopProcess) -> some View {
        HStack(spacing: 10) {
            processIcon(process)
                .frame(width: 18, height: 18)
            Text(process.name)
                .font(KiwiMangoFont.sans(11.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(process.id)")
                .font(KiwiMangoFont.mono(9))
                .foregroundStyle(Color.ink.opacity(0.35))
                .frame(width: 48, alignment: .trailing)
            Text(String(format: "%.0f%%", process.cpuPercent))
                .font(KiwiMangoFont.mono(10))
                .foregroundStyle(Color.ink.opacity(0.6))
                .frame(width: 52, alignment: .trailing)
            Text(Self.formatBytes(process.ramBytes))
                .font(KiwiMangoFont.mono(10))
                .foregroundStyle(Color.ink.opacity(0.6))
                .frame(width: 58, alignment: .trailing)
            Rectangle().fill(Color.ink.opacity(0.1)).frame(width: 46, height: 1)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { openPopoverPID = process.id }
        .popover(isPresented: Binding(
            get: { openPopoverPID == process.id },
            set: { if !$0 { openPopoverPID = nil } }
        )) {
            ProcessActionsPopover(process: process) { action in
                openPopoverPID = nil
                pendingAction = action
            }
        }
    }

    private func processIcon(_ process: HardwareMonitor.TopProcess) -> some View {
        Group {
            if let icon = NSRunningApplication(processIdentifier: process.id)?.icon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "gearshape")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.ink.opacity(0.6))
                    .frame(width: 18, height: 18)
                    .background(Color.ink.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}

// MARK: - Popover (PLAN-V2 §7.2 pt.5 — Restart / Wyczyść cache / Zamknij)

private struct ProcessActionsPopover: View {
    let process: HardwareMonitor.TopProcess
    let onAction: (PendingProcessAction) -> Void

    /// Pułapka #8: only a real GUI app (bundle + bundle URL) is eligible for
    /// any destructive action. Daemons/system processes (WindowServer,
    /// kernel_task, …) get an info-only popover.
    private var app: NSRunningApplication? { NSRunningApplication(processIdentifier: process.id) }
    private var bundleURL: URL? { app?.bundleURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(process.name.uppercased())
                .font(KiwiMangoFont.sans(9, weight: .semibold)).tracking(0.8)
                .foregroundStyle(Color.ink.opacity(0.4))
                .padding(.horizontal, 8).padding(.top, 5).padding(.bottom, 6)

            if let bundleURL {
                actionButton("arrow.clockwise", "Restart") {
                    onAction(.restart(pid: process.id, name: process.name, bundleURL: bundleURL))
                }
                actionButton("trash", "Wyczyść cache") {
                    onAction(.clearCache(pid: process.id, name: process.name, bundleID: app?.bundleIdentifier ?? ""))
                }
                actionButton("xmark.circle", "Zamknij proces", danger: true) {
                    onAction(.quit(pid: process.id, name: process.name))
                }
            } else {
                Text("Proces systemowy — brak dostępnych akcji.")
                    .font(KiwiMangoFont.sans(10.5))
                    .foregroundStyle(Color.ink.opacity(0.5))
                    .padding(.horizontal, 8).padding(.bottom, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 172)
        .padding(4)
    }

    private func actionButton(_ icon: String, _ label: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 10)).frame(width: 14)
                Text(label).font(KiwiMangoFont.sans(11))
            }
            .foregroundStyle(danger ? Color.danger : Color.txt)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - PendingProcessAction (confirm-then-perform)

struct PendingProcessAction: Identifiable {
    enum Kind {
        case restart(pid: pid_t, name: String, bundleURL: URL)
        case clearCache(pid: pid_t, name: String, bundleID: String)
        case quit(pid: pid_t, name: String)
    }
    let kind: Kind
    var id: String {
        switch kind {
        case .restart(let pid, _, _): "restart-\(pid)"
        case .clearCache(let pid, _, _): "cache-\(pid)"
        case .quit(let pid, _): "quit-\(pid)"
        }
    }

    static func restart(pid: pid_t, name: String, bundleURL: URL) -> Self { .init(kind: .restart(pid: pid, name: name, bundleURL: bundleURL)) }
    static func clearCache(pid: pid_t, name: String, bundleID: String) -> Self { .init(kind: .clearCache(pid: pid, name: name, bundleID: bundleID)) }
    static func quit(pid: pid_t, name: String) -> Self { .init(kind: .quit(pid: pid, name: name)) }

    var title: String {
        switch kind {
        case .restart(_, let name, _): "Zrestartować \(name)?"
        case .clearCache(_, let name, _): "Wyczyścić cache \(name)?"
        case .quit(_, let name): "Zamknąć \(name)?"
        }
    }

    var message: String {
        switch kind {
        case .restart: "Aplikacja zostanie zamknięta i uruchomiona ponownie."
        case .clearCache: "Usunięty zostanie folder cache aplikacji z ~/Library/Caches."
        case .quit: "Aplikacja zostanie zamknięta. Niezapisane dane mogą zostać utracone."
        }
    }

    var confirmLabel: String {
        switch kind {
        case .restart: "Restart"
        case .clearCache: "Wyczyść"
        case .quit: "Zamknij"
        }
    }

    var isDestructive: Bool {
        if case .quit = kind { return true }
        return false
    }

    func perform() {
        switch kind {
        case .restart(let pid, _, let bundleURL):
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.terminate()
            }
            // ponytail: fire-and-forget relaunch shortly after — terminate()
            // is async on macOS's side, a short delay avoids racing the quit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSWorkspace.shared.open(bundleURL)
            }
        case .clearCache(_, _, let bundleID):
            guard !bundleID.isEmpty else { return }
            let cacheURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/\(bundleID)", isDirectory: true)
            guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }
            // ponytail: trashItem (recoverable) rather than removeItem — same
            // "reversible deletion" principle as MoleView's Clean tab (§7.5).
            try? FileManager.default.trashItem(at: cacheURL, resultingItemURL: nil)
        case .quit(let pid, _):
            if let app = NSRunningApplication(processIdentifier: pid) {
                let started = app.terminate()
                if !started {
                    kill(pid, SIGTERM) // pułapka #8 fallback — only reached for a real app that refused terminate()
                }
            }
        }
    }
}
