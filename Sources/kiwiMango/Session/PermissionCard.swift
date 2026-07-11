import SwiftUI

// MARK: - PermissionCard (PLAN-V2 §7.3)

/// Terminal-style permission prompt. Chat: mapped from claude CLI's
/// `--permission-mode` stream-json events. Agent: from the gateway's approval
/// events if it exposes them — no card is shown otherwise (caller's choice).
struct PermissionCard: View {
    @Bindable var request: PermissionRequest

    var isDone: Bool { request.decision != .pending }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("⚠ PROŚBA O UPRAWNIENIE")
                .font(KiwiMangoFont.sans(9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Color.accent)

            Text(request.command)
                .font(KiwiMangoFont.mono(10))
                .foregroundStyle(Color.ink.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 5))

            if isDone {
                if let resultLine = request.resultLine {
                    Text(resultLine)
                        .font(KiwiMangoFont.sans(9.5))
                        .foregroundStyle(Color.green)
                }
            } else {
                HStack(spacing: 6) {
                    decisionButton("Zezwól", filled: true) { decide(.allowed, result: "✓ zezwolono") }
                    decisionButton("Zezwól na sesję", filled: false) { decide(.allowedForSession, result: "✓ zezwolono na sesję") }
                    decisionButton("Odmów", filled: false) { decide(.denied, result: nil) }
                }
            }
        }
        .padding(13)
        .frame(maxWidth: 340, alignment: .leading)
        .background(Color.accent.opacity(0.07))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accent.opacity(0.3), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(isDone ? 0.55 : 1)
    }

    private func decide(_ decision: PermissionRequest.Decision, result: String?) {
        request.decision = decision
        request.resultLine = result
        request.onDecide?(decision != .denied)
    }

    private func decisionButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(KiwiMangoFont.sans(9, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(filled ? Color.bg : Color.ink.opacity(0.6))
            .background(filled ? Color.accent : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(filled ? .clear : Color.ink.opacity(0.15), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
