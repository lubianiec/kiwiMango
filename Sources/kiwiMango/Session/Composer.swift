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
        .padding(.horizontal, 16)
        .padding(.top, 11)
        .padding(.bottom, 12)
        .background(Color.black.opacity(0.12))
        .overlay(Rectangle().fill(Color.ink.opacity(0.14)).frame(height: 1), alignment: .top)
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
