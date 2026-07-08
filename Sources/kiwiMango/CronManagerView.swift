import SwiftUI

// MARK: - CronManagerView

/// F25.1: thin UI over Hermes's OWN scheduler (`cron.manage` on the gateway,
/// already runs jobs like the 60-min vault-sync) — per Fable's review,
/// kiwiMango does NOT run a second scheduler. List / add / pause-resume /
/// remove, opened as a `.sheet` from `RootView`'s sidebar.
struct CronManagerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var jobs: [HermesGatewayClient.CronJob] = []
    @State private var isLoading = false
    @State private var loadError: String?

    @State private var newName = ""
    @State private var newSchedule = ""
    @State private var newPrompt = ""
    @State private var isCreating = false
    @State private var createError: String?

    @State private var busyJobIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            header
            newJobForm
            content
        }
        .frame(minWidth: 480, minHeight: 520)
        .background(Color.kiwiMangoSurface)
        .task { await reload() }
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(Color.kiwiMangoAccent)
                    .frame(width: 7, height: 7)
                Text("kiwiMango — automaty (cron)")
                    .font(KiwiMangoFont.mono(10.5, weight: .medium))
                    .tracking(0.5)
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
                    .textCase(.lowercase)
            }
            Spacer()
            Button("Odśwież") { Task { await reload() } }
                .buttonStyle(.plain)
                .font(KiwiMangoFont.mono(10.5))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
                .disabled(isLoading)
            Button("Zamknij") { dismiss() }
                .buttonStyle(.plain)
                .font(KiwiMangoFont.mono(10.5))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color.kiwiMangoChrome)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MOJE_AUTOMATY")
                .font(KiwiMangoFont.mono(14, weight: .bold))
                .foregroundStyle(Color.kiwiMangoTextPrimary)
            Text("zadania cykliczne Hermesa — działają nawet gdy appka jest zamknięta")
                .font(KiwiMangoFont.mono(11.5))
                .foregroundStyle(Color.kiwiMangoAccent.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - New job form

    private var newJobForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOWY AUTOMAT")
                .font(KiwiMangoFont.mono(10, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))

            fieldRow(placeholder: "nazwa (np. \"poranny raport\")", text: $newName)
            fieldRow(placeholder: "harmonogram: \"every 2h\", \"0 9 * * *\" (cron) lub \"30m\"", text: $newSchedule)
            fieldRow(placeholder: "co ma zrobić agent…", text: $newPrompt)

            HStack {
                if let createError {
                    Text(createError)
                        .font(KiwiMangoFont.mono(10.5))
                        .foregroundStyle(Color.kiwiMangoDanger)
                }
                Spacer()
                Button(isCreating ? "Tworzę…" : "+ Dodaj automat") {
                    Task { await createJob() }
                }
                .buttonStyle(.plain)
                .font(KiwiMangoFont.mono(11, weight: .semibold))
                .foregroundStyle(Color.kiwiMangoAccentText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.kiwiMangoAccent, in: RoundedRectangle(cornerRadius: 4))
                .disabled(isCreating || newSchedule.trimmingCharacters(in: .whitespaces).isEmpty || newPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private func fieldRow(placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.4)))
            .textFieldStyle(.plain)
            .font(KiwiMangoFont.mono(11.5))
            .foregroundStyle(Color.kiwiMangoTextPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.kiwiMangoComposerBg)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        if isLoading, jobs.isEmpty {
            Spacer()
            ProgressView().controlSize(.small)
            Spacer()
        } else if let loadError {
            Spacer()
            Text(loadError)
                .font(KiwiMangoFont.mono(11))
                .foregroundStyle(Color.kiwiMangoDanger)
                .padding()
            Spacer()
        } else if jobs.isEmpty {
            Spacer()
            Text("Brak automatów. Dodaj pierwszy powyżej.")
                .font(KiwiMangoFont.mono(11))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(jobs) { job in
                        jobRow(job)
                        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
                    }
                }
            }
        }
    }

    private func jobRow(_ job: HermesGatewayClient.CronJob) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job.name)
                        .font(KiwiMangoFont.mono(12, weight: .semibold))
                        .foregroundStyle(Color.kiwiMangoTextPrimary)
                    if !job.enabled {
                        Text("WSTRZYMANY")
                            .font(KiwiMangoFont.mono(9, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(Color.kiwiMangoDanger)
                    }
                }
                Text(job.schedule)
                    .font(KiwiMangoFont.mono(10.5))
                    .foregroundStyle(Color.kiwiMangoAccent.opacity(0.8))
                if !job.promptPreview.isEmpty {
                    Text(job.promptPreview)
                        .font(KiwiMangoFont.mono(10.5))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
                        .lineLimit(2)
                }
                if let lastRunAt = job.lastRunAt {
                    Text("ostatnio: \(lastRunAt)" + (job.lastStatus.map { " (\($0))" } ?? ""))
                        .font(KiwiMangoFont.mono(9.5))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.4))
                }
            }
            Spacer()
            HStack(spacing: 10) {
                Button(job.enabled ? "Wstrzymaj" : "Wznów") {
                    Task { await toggle(job) }
                }
                .buttonStyle(.plain)
                .font(KiwiMangoFont.mono(10.5))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.72))

                Button("Usuń") {
                    Task { await remove(job) }
                }
                .buttonStyle(.plain)
                .font(KiwiMangoFont.mono(10.5))
                .foregroundStyle(Color.kiwiMangoDanger)
            }
            .disabled(busyJobIDs.contains(job.id))
            .opacity(busyJobIDs.contains(job.id) ? 0.4 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func reload() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            try await HermesGatewayClient.shared.connectIfNeeded()
            jobs = try await HermesGatewayClient.shared.listCronJobs()
        } catch {
            loadError = "Nie udało się połączyć z Hermes Gateway: \(error.localizedDescription)"
        }
    }

    private func createJob() async {
        isCreating = true
        createError = nil
        defer { isCreating = false }
        do {
            try await HermesGatewayClient.shared.connectIfNeeded()
            let name = newName.trimmingCharacters(in: .whitespaces)
            try await HermesGatewayClient.shared.createCronJob(
                name: name.isEmpty ? newPrompt : name,
                schedule: newSchedule.trimmingCharacters(in: .whitespaces),
                prompt: newPrompt.trimmingCharacters(in: .whitespaces)
            )
            newName = ""
            newSchedule = ""
            newPrompt = ""
            await reload()
        } catch {
            createError = error.localizedDescription
        }
    }

    private func toggle(_ job: HermesGatewayClient.CronJob) async {
        busyJobIDs.insert(job.id)
        defer { busyJobIDs.remove(job.id) }
        do {
            if job.enabled {
                try await HermesGatewayClient.shared.pauseCronJob(id: job.id)
            } else {
                try await HermesGatewayClient.shared.resumeCronJob(id: job.id)
            }
            await reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func remove(_ job: HermesGatewayClient.CronJob) async {
        busyJobIDs.insert(job.id)
        defer { busyJobIDs.remove(job.id) }
        do {
            try await HermesGatewayClient.shared.removeCronJob(id: job.id)
            await reload()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
