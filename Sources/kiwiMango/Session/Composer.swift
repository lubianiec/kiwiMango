import SwiftUI

// MARK: - Composer (PLAN-V2 §7.3)

struct Composer: View {
    @Binding var draft: String
    var placeholder: String
    /// "kontekst: X / Y tok." (Agent) or "model · X tok. · koszt" (Chat).
    var counterText: String
    /// Agent = microphone, Chat = "/" snippet trigger (PLAN-V2 §7.3).
    var thirdIcon: String
    var onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(KiwiMangoFont.sans(12))
                .lineLimit(1...4)
                .onSubmit(onSend)

            HStack(spacing: 10) {
                Image(systemName: "plus").kiwiComposerIcon()
                Image(systemName: "photo").kiwiComposerIcon()
                Image(systemName: thirdIcon).kiwiComposerIcon()

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

private extension Image {
    func kiwiComposerIcon() -> some View {
        self.font(.system(size: 12 + FontScale.bump))
            .foregroundStyle(Color.ink.opacity(0.45))
    }
}
