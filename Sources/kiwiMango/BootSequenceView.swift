import SwiftUI

// MARK: - BootSequenceView

/// One-shot boot animation shown over the whole window at launch. Lines print
/// sequentially with real data (Ollama ping, model/conversation counts) — never
/// mocked. Removed from the view hierarchy entirely once done, so it costs
/// nothing after the first ~2 seconds.
struct BootSequenceView: View {
    @Environment(ChatState.self) private var chatState
    let onDone: () -> Void

    private struct Line: Identifiable {
        let id = UUID()
        let text: String
        let color: Color
    }

    @State private var lines: [Line] = []
    @State private var opacity: Double = 1
    @State private var sequenceTask: Task<Void, Never>?
    @State private var finished = false

    var body: some View {
        ZStack {
            Color.kiwiMangoBackground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 5) {
                ForEach(lines) { line in
                    Text(line.text)
                        .foregroundStyle(line.color)
                }
            }
            .font(KiwiMangoFont.mono(13))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)
        }
        .opacity(opacity)
        .contentShape(Rectangle())
        .onTapGesture { skip() }
        .task {
            let task = Task { await runSequence() }
            sequenceTask = task
            await task.value
        }
    }

    private func runSequence() async {
        await addLine("KM// BIOS v2.0", color: .kiwiMangoAccent, delayMs: 200)
        guard !Task.isCancelled else { return }
        await addLine("MEM CHECK............... OK", color: .kiwiMangoAccent, delayMs: 200)
        guard !Task.isCancelled else { return }

        let ping = await OllamaService().ping()
        let handshakeLine = ping.online
            ? "OLLAMA HANDSHAKE........ ● online"
            : "OLLAMA HANDSHAKE........ ✗ offline"
        await addLine(handshakeLine, color: ping.online ? .kiwiMangoAccent : .kiwiMangoDanger, delayMs: 220)
        guard !Task.isCancelled else { return }

        let modelCount = chatState.availableModels.isEmpty ? "..." : "\(chatState.availableModels.count)"
        await addLine("MODELE.................. \(modelCount)", color: .kiwiMangoAccent, delayMs: 200)
        guard !Task.isCancelled else { return }

        await addLine("KONWERSACJE............. \(chatState.conversations.count)", color: .kiwiMangoAccent, delayMs: 200)
        guard !Task.isCancelled else { return }

        await addLine("BOOT COMPLETE_", color: .kiwiMangoAccent, delayMs: 150)
        guard !Task.isCancelled else { return }

        finish(fast: false)
    }

    private func addLine(_ text: String, color: Color, delayMs: Int) async {
        lines.append(Line(text: text, color: color))
        try? await Task.sleep(for: .milliseconds(delayMs))
    }

    private func skip() {
        sequenceTask?.cancel()
        finish(fast: true)
    }

    private func finish(fast: Bool) {
        guard !finished else { return }
        finished = true
        withAnimation(.easeOut(duration: fast ? 0.2 : 0.3)) {
            opacity = 0
        }
        Task {
            try? await Task.sleep(for: .milliseconds(fast ? 200 : 300))
            onDone()
        }
    }
}
