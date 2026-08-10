import SwiftUI

// MARK: - Composer (PLAN-V2 §7.3 → terminal-stream restyle)
//
// Was a boxed textarea: rounded panel, full border, filled circular send
// button. The mockup (kiwimango-okno-rozmowy-final.html `.composer`) drops
// the box entirely — just a flat prompt row continuing the stream's own
// idiom: `❯` then typed text, top hairline instead of a frame. Functionality
// is unchanged: send (Return or clicking the "⌘↵" hint), drag&drop
// attachments (handled by ConversationView's onDrop; this view only lists
// pendingAttachments), and the context counter — only the chrome moved.

struct Composer: View {
    @Binding var draft: String
    var placeholder: String
    /// "kontekst: X / Y tok." (Agent) or "model · X tok. · koszt" (Chat).
    var counterText: String
    @Binding var pendingAttachments: [PendingAttachment]
    var onSend: () -> Void
    /// When set, counterText renders as a button (context-usage popover trigger).
    var onTapCounter: (() -> Void)? = nil

    // MARK: F1 (PLAN-OKNO) — controls row, moved here from ConversationView's
    // title bar so everything about the outgoing message (model, thinking
    // level, attachments, context, send) sits in one place under the field
    // you're typing into, matching Claude Code desktop's composer.
    var onAttach: (() -> Void)? = nil
    var modelOptions: [String] = []
    var model: Binding<String>? = nil
    var reasoningOptions: [(label: String, value: String)] = []
    var reasoningEffort: Binding<String>? = nil

    // MARK: PLAN-VOICE-V3 — dyktowanie. Mikrofon obok pola tekstowego, tak jak
    // Paweł chciał od początku: transkrybuje mowę DO pola, nic więcej.
    var voiceState: VoiceAgentService.State = .idle
    var voiceLevel: Float = 0
    var onDictate: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pendingAttachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(pendingAttachments) { attachment in
                        HStack(spacing: 4) {
                            Text("⇪ \(attachment.filename)")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 140)
                            Button {
                                pendingAttachments.removeAll { $0.id == attachment.id }
                            } label: {
                                Text("✕")
                            }
                            .buttonStyle(.plain)
                        }
                        .font(KiwiMangoFont.mono(9.5))
                        .foregroundStyle(Color.ink.opacity(0.42))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.ink.opacity(0.14), lineWidth: 1))
                    }
                }
            }

            HStack(spacing: 11) {
                Text("❯")
                    .font(KiwiMangoFont.mono(14))
                    .foregroundStyle(Color.accent)

                TextField(
                    "",
                    text: $draft,
                    prompt: Text(placeholder)
                        .font(KiwiMangoFont.mono(12.5))
                        .foregroundStyle(Color.ink.opacity(0.28)),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(KiwiMangoFont.mono(12.5))
                .foregroundStyle(Color.ink)
                .lineLimit(1...4)
                .onSubmit(onSend)

                if let onDictate {
                    Button(action: onDictate) {
                        Group {
                            if voiceState == .listening {
                                VoiceWaveform(level: voiceLevel)
                            } else {
                                Image(systemName: micIcon)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(micTint)
                            }
                        }
                        // Bug zgłoszony przez Pawła: klik "nie działał" —
                        // 3 cienkie paski (16×14) to za mały cel. Cały kwadrat
                        // klikalny, nie tylko narysowane piksele.
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(micHelp)
                }
            }

            controlsRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 11)
        .padding(.bottom, 12)
        // F4 (PLAN-OKNO): composer jako wyodrębniony, "pływający" obszar zamiast
        // płaskiego paska z hairline u góry — Color.compbg istniał w DesignSystem
        // jako gotowy, nieużywany token (dokładnie "composer background") od
        // czasu redesignu, zanim composer w ogóle miał własne tło.
        .background(Color.compbg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.ink.opacity(0.14), lineWidth: 1))
    }

    // MARK: Controls row (F1) — attachments left, model/effort/context/send right.
    // Pułapka z planu: Pickery mają stałą szerokość (frame+layoutPriority), żeby
    // długa nazwa modelu nie rozepchnęła rzędu kosztem reszty kontrolek.
    private var controlsRow: some View {
        HStack(spacing: 11) {
            if let onAttach {
                Button(action: onAttach) {
                    Text("+")
                        .font(KiwiMangoFont.mono(13))
                        .foregroundStyle(Color.ink.opacity(0.42))
                }
                .buttonStyle(.plain)
                .help("Załącz plik")
            }

            Spacer(minLength: 8)

            if let model {
                Picker("", selection: model) {
                    ForEach(modelOptions, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
                .layoutPriority(1)
            }

            if let reasoningEffort {
                Picker("", selection: reasoningEffort) {
                    ForEach(reasoningOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 120)
                .help("Poziom myślenia agenta")
                .layoutPriority(1)
            }

            counterLabel

            Button(action: onSend) {
                Text("⌘↵")
                    .font(KiwiMangoFont.mono(9.5))
                    .foregroundStyle(Color.ink.opacity(0.28))
            }
            .buttonStyle(.plain)
            .help("Wyślij")
        }
    }

    // MARK: PLAN-VOICE-V3 — kolory z istniejącej palety, zero nowych (feedback_no_ai_slop_ui).
    private var micTint: Color {
        switch voiceState {
        case .idle: Color.ink.opacity(0.35)
        case .listening: Color.accent
        case .error: Color.danger
        }
    }

    private var micIcon: String {
        switch voiceState {
        case .idle: "mic"
        case .listening: "mic.fill"
        case .error: "mic.slash"
        }
    }

    private var micHelp: String {
        switch voiceState {
        case .idle: "Dyktuj — kliknij i mów po polsku"
        case .listening: "Nasłuchuję — kliknij, żeby wstawić tekst"
        case .error(let message): message
        }
    }

    @ViewBuilder
    private var counterLabel: some View {
        let text = Text(counterText)
            .font(KiwiMangoFont.mono(9.5))
            .foregroundStyle(Color.ink.opacity(0.28))
            .monospacedDigit()
        if let onTapCounter {
            Button(action: onTapCounter) { text }
                .buttonStyle(.plain)
        } else {
            text
        }
    }

}

// MARK: - VoiceWaveform (PLAN-VOICE-V3 §"bajer") — Paweł: "jakiś bajer taki".
// 4 paski reagujące na `voiceLevel` (RMS mikrofonu z VoiceAgentService, nie
// animacja na sztywno) — każdy z inną wagą, żeby nie ruszały się jak jeden
// słupek. `.animation` wygładza skoki między buforami (~90ms), inaczej
// migałoby klatkowo.
private struct VoiceWaveform: View {
    let level: Float
    private let weights: [CGFloat] = [0.5, 1.0, 0.7, 0.85]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<weights.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accent)
                    .frame(width: 2.5, height: barHeight(weights[i]))
            }
        }
        .frame(width: 16, height: 14)
        .animation(.easeOut(duration: 0.12), value: level)
    }

    private func barHeight(_ weight: CGFloat) -> CGFloat {
        let base: CGFloat = 3
        let extra = CGFloat(level) * weight * 11
        return min(14, base + extra)
    }
}
