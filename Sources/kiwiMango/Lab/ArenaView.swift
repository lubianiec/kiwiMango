import SwiftUI

// MARK: - ArenaView

/// Sets up and displays a model Arena round: 2–3 cloud models answer the same
/// prompt side by side, then the user votes for a winner. See `ArenaState`.
struct ArenaView: View {
    @Environment(ChatState.self) private var chatState
    let arena: ArenaState

    private var cloudModels: [OllamaService.ModelInfo] {
        chatState.availableModels.filter(\.isCloud)
    }

    var body: some View {
        @Bindable var arena = arena
        VStack(spacing: 0) {
            header
            if arena.columns.isEmpty {
                setupView
            } else {
                columnsView
            }
        }
        .kiwiMangoNoirBackground()
        .onAppear { arena.refreshRanking() }
    }

    private var header: some View {
        HStack {
            Text("🏆 ARENA MODELI")
                .font(KiwiMangoFont.mono(13, weight: .bold))
                .foregroundStyle(Color.kiwiMangoAccent)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.kiwiMangoChrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.kiwiMangoAccent.opacity(0.15)).frame(height: 1)
        }
    }

    // MARK: - Setup

    private var setupView: some View {
        @Bindable var arena = arena
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("WYBIERZ 2–3 MODELE CLOUD")
                    .font(KiwiMangoFont.mono(10, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.72))

                if cloudModels.isEmpty {
                    Text("Brak modeli cloud — sprawdź połączenie z Ollama.")
                        .font(KiwiMangoFont.mono(11.5))
                        .foregroundStyle(Color.kiwiMangoDanger)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(cloudModels, id: \.name) { model in
                            modelCheckbox(model)
                        }
                    }
                }

                TextField("Prompt dla wszystkich modeli…", text: $arena.promptDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(KiwiMangoFont.mono(12.5))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
                    .lineLimit(2...6)
                    .padding(10)
                    .background(Color.kiwiMangoComposerBg)
                    .neonBorder(Color.kiwiMangoAccent, cornerRadius: 4)

                Button(action: startRound) {
                    Text("[ START ARENY ]")
                        .font(KiwiMangoFont.mono(12, weight: .bold))
                        .foregroundStyle(Color.kiwiMangoAccentText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.kiwiMangoAccent, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
                .opacity(canStart ? 1 : 0.4)

                if !arena.votingRanking.isEmpty {
                    rankingBar
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var canStart: Bool {
        (2...3).contains(arena.selectedModels.count)
            && !arena.promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func modelCheckbox(_ model: OllamaService.ModelInfo) -> some View {
        @Bindable var arena = arena
        let isSelected = arena.selectedModels.contains(model.name)
        return Button {
            if isSelected {
                arena.selectedModels.remove(model.name)
            } else if arena.selectedModels.count < 3 {
                arena.selectedModels.insert(model.name)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.kiwiMangoAccent : Color.kiwiMangoTextPrimary.opacity(0.66))
                Text(model.name)
                    .font(KiwiMangoFont.mono(11.5))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.8))
            }
        }
        .buttonStyle(.plain)
    }

    private func startRound() {
        guard canStart else { return }
        let models = Array(arena.selectedModels)
        let prompt = arena.promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let thinking = Set(chatState.availableModels.filter(\.supportsThinking).map(\.name))
        arena.start(models: models, prompt: prompt, thinkingModels: thinking)
    }

    // MARK: - Columns

    private var columnsView: some View {
        VStack(spacing: 0) {
            ScrollView {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(arena.columns.enumerated()), id: \.element.id) { index, column in
                        columnView(column, index: index)
                    }
                }
                .padding(16)
                .frame(minWidth: arena.columns.count >= 3 ? 900 : 0, maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)

            newRoundBar
        }
    }

    private func columnView(_ column: ArenaState.Column, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(column.model)
                .font(KiwiMangoFont.mono(11, weight: .bold))
                .foregroundStyle(Color.kiwiMangoAccent)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .neonBorder(Color.kiwiMangoAccent, cornerRadius: 4)

            ScrollView {
                if let errorMessage = column.errorMessage {
                    Text("⚠️ \(errorMessage)")
                        .font(KiwiMangoFont.mono(11))
                        .foregroundStyle(Color.kiwiMangoDanger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(alignment: .bottom, spacing: 0) {
                        MarkdownText(content: column.text)
                        if column.isStreaming {
                            Text("▌")
                                .font(KiwiMangoFont.mono(13))
                                .foregroundStyle(Color.kiwiMangoAccent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: 220, maxHeight: .infinity)

            if let statsLine = column.statsLine {
                Text(statsLine)
                    .font(KiwiMangoFont.mono(10))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.63))
            }

            if !arena.isRunning && column.errorMessage == nil {
                Button {
                    arena.vote(for: index)
                } label: {
                    Text(column.voted ? "[⭐ ZAGŁOSOWANO]" : "[⭐ WYGRYWA]")
                        .font(KiwiMangoFont.mono(11, weight: .bold))
                        .foregroundStyle(column.voted ? Color.kiwiMangoTextPrimary.opacity(0.66) : Color.kiwiMangoPurple)
                }
                .buttonStyle(.plain)
                .disabled(column.voted)
            }
        }
        .padding(12)
        .frame(minWidth: 260, maxWidth: .infinity, alignment: .topLeading)
        .background(Color.kiwiMangoSurface.opacity(0.4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var newRoundBar: some View {
        @Bindable var arena = arena
        return VStack(alignment: .leading, spacing: 10) {
            if !arena.votingRanking.isEmpty {
                rankingBar
            }
            HStack {
                TextField("Nowy prompt…", text: $arena.promptDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(KiwiMangoFont.mono(12))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
                    .lineLimit(1...4)
                    .padding(8)
                    .background(Color.kiwiMangoComposerBg)
                    .neonBorder(Color.kiwiMangoAccent, cornerRadius: 4)
                Button(action: startRound) {
                    Text("[NOWA_RUNDA]")
                        .font(KiwiMangoFont.mono(11, weight: .bold))
                        .foregroundStyle(Color.kiwiMangoAccentText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.kiwiMangoAccent, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
                .opacity(canStart ? 1 : 0.4)
            }
        }
        .padding(16)
        .background(Color.kiwiMangoChrome)
    }

    private var rankingBar: some View {
        Text(arena.votingRanking.map { "\($0.model): \($0.votes) ⭐" }.joined(separator: "  ·  "))
            .font(KiwiMangoFont.mono(10.5))
            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
    }
}
