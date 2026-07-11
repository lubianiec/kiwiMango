import AppKit
import SwiftUI

// MARK: - TopSystemBar

/// Window-top bar stripped down to identity + live status only.
/// All navigation buttons moved to the left control panel so they are big,
/// high-contrast, and one below another.
struct TopSystemBar: View {
    @State private var monitor = OllamaStatusMonitor()
    @State private var appLaunchTime = Date()
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                logoMark
                Text("kiwiMango")
                    .font(KiwiMangoFont.mono(12, weight: .bold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
            }

            Spacer()

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ollamaIcon
                        .frame(width: 14, height: 14)

                    Text("●")
                        .font(.system(size: 7))
                        .foregroundStyle(monitor.isOnline ? Color.kiwiMangoTextPrimary : Color.kiwiMangoDanger)
                        .realBloom(strength: 1.4, radius: 2)

                    Text(monitor.isOnline ? "Ollama" : "offline")
                        .foregroundStyle(Color.kiwiMangoTextPrimary)

                    if let latency = monitor.latencyMs {
                        Text("\(latency)ms")
                            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
                    }
                }

                Text("·")
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.4))

                Text(sessionTimeLabel)
                    .monospacedDigit()
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.65))
            }
        }
        .font(KiwiMangoFont.mono(10))
        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.72))
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(
            Color.kiwiMangoChrome
                .shadow(.inner(color: Color.white.opacity(0.04), radius: 0, x: 0, y: 1))
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        .task {
            monitor.start()
            appLaunchTime = Date()
        }
        .onReceive(ticker) { _ in now = Date() }
    }

    // Realna ikona apki zamiast białego kwadratu z "K" — NSApp zawsze coś zwraca
    // (AppIcon.icns z bundle'a, generyczna gdy brak).
    private var logoMark: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 20, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var ollamaIcon: some View {
        Group {
            if let nsImage = ollamaAppIcon() {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "circle.hexagongrid.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
            }
        }
    }

    private var sessionTimeLabel: String {
        let seconds = Int(now.timeIntervalSince(appLaunchTime))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m \(s)s"
    }
}

private func ollamaAppIcon() -> NSImage? {
    guard let url = Bundle.module.url(forResource: "OllamaIcon", withExtension: "icns") else { return nil }
    let image = NSImage(contentsOf: url)
    image?.isTemplate = false
    return image
}
