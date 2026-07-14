import SwiftUI

// MARK: - Composer (PLAN-V2 §7.3)

struct Composer: View {
    @Binding var draft: String
    var placeholder: String
    /// "kontekst: X / Y tok." (Agent) or "model · X tok. · koszt" (Chat).
    var counterText: String
    @Binding var pendingAttachments: [PendingAttachment]
    var onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pendingAttachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(pendingAttachments) { attachment in
                        HStack(spacing: 4) {
                            Text("\(attachment.kind == .image ? "🖼" : attachment.kind == .pdf ? "📄" : "📎") \(attachment.filename)")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 100)
                            Button {
                                pendingAttachments.removeAll { $0.id == attachment.id }
                            } label: {
                                Text("✕")
                            }
                            .buttonStyle(.plain)
                        }
                        .font(KiwiMangoFont.mono(9))
                        .foregroundStyle(Color.ink.opacity(0.55))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(Capsule().strokeBorder(Color.ink.opacity(0.14), lineWidth: 1))
                    }
                }
            }

            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(KiwiMangoFont.sans(12))
                .lineLimit(1...4)
                .onSubmit(onSend)

            HStack(spacing: 10) {
                Text(counterText)
                    .font(KiwiMangoFont.sans(9))
                    .foregroundStyle(Color.ink.opacity(0.4))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11 + FontScale.bump, weight: .semibold))
                        .foregroundStyle(Color.bg)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.accent))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color.compbg)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.ink.opacity(0.1), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
