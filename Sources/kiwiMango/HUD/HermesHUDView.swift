import SwiftUI
import WebKit

// MARK: - HermesHUDView

/// Hermes HUD osadzony jako pełna sekcja kiwiMango (nie osobne okno).
/// Wyświetla lokalny hermes-hudui w WKWebView, dopasowany do stylu aplikacji.
struct HermesHUDView: View {
    @Bindable var manager: HermesHUDManager

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider().overlay(Color.white.opacity(0.08))
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.kiwiMangoSurface)
        .onAppear { manager.check() }
        .onDisappear { manager.stopServer() }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: statusIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
                Text(statusText)
                    .font(KiwiMangoFont.mono(10.5, weight: .semibold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
            }

            Spacer()

            if case .ready = manager.state {
                Button {
                    manager.stopServer()
                    manager.startServer()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                        Text("Odśwież")
                            .font(KiwiMangoFont.mono(10.5))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.kiwiMangoAccent)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Color.kiwiMangoChrome)
    }

    @ViewBuilder
    private var content: some View {
        switch manager.state {
        case .idle, .checking, .starting:
            loadingView("Ładowanie Hermes HUD…")
        case .missing:
            installPromptView
        case .installing(let python):
            logView("Instaluję hermes-hudui przez \(python)…")
        case .failed(let error):
            errorView(error)
        case .ready(let url):
            HUDWebView(url: url)
        }
    }

    private var installPromptView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.kiwiMangoAccent.opacity(0.7))
            Text("Hermes HUD nie jest zainstalowany")
                .font(KiwiMangoFont.mono(13, weight: .bold))
                .foregroundStyle(Color.kiwiMangoTextPrimary)
            Text("Kliknij poniżej, żeby pobrać i zbudować lokalny dashboard.")
                .font(KiwiMangoFont.mono(11))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
                .multilineTextAlignment(.center)
            Button {
                manager.install()
            } label: {
                Text("Zainstaluj hermes-hudui")
                    .font(KiwiMangoFont.mono(12, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.kiwiMangoAccent)
                    .foregroundStyle(Color.black)
                    .clipShape(.rect(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(24)
    }

    private func loadingView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
            Text(message)
                .font(KiwiMangoFont.mono(11))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
            Spacer()
        }
    }

    private func logView(_ message: String) -> some View {
        VStack(spacing: 0) {
            Text(message)
                .font(KiwiMangoFont.mono(11))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
                .padding(12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(manager.logLines, id: \.self) { line in
                        Text(line)
                            .font(KiwiMangoFont.mono(9))
                            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.kiwiMangoBackground)
        }
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.kiwiMangoDanger)
            Text("⚠️ \(error)")
                .font(KiwiMangoFont.mono(12))
                .foregroundStyle(Color.kiwiMangoDanger)
                .multilineTextAlignment(.center)
            Button {
                manager.check()
            } label: {
                Text("Spróbuj ponownie")
                    .font(KiwiMangoFont.mono(11, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color.kiwiMangoAccent)
                    .foregroundStyle(Color.black)
                    .clipShape(.rect(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(24)
    }

    // MARK: - Status helpers

    private var statusIcon: String {
        switch manager.state {
        case .ready: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .missing: return "xmark.circle.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var statusColor: Color {
        switch manager.state {
        case .ready: return Color.kiwiMangoAccent
        case .failed, .missing: return Color.kiwiMangoDanger
        default: return Color.kiwiMangoTextPrimary.opacity(0.55)
        }
    }

    private var statusText: String {
        switch manager.state {
        case .idle, .checking: return "Inicjalizacja…"
        case .starting: return "Uruchamianie serwera…"
        case .ready: return "Hermes HUD aktywny"
        case .missing: return "Brak instalacji"
        case .installing: return "Instalacja…"
        case .failed(let error): return "Błąd: \(error)"
        }
    }
}

// MARK: - HUDWebView

private struct HUDWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        // Wstrzyknij polski język + ukryj webowy toggle języka zanim React załaduje UI.
        let bootstrap = """
        (function(){
            localStorage.setItem('hermes-hudui-lang','pl');
            try {
                document.documentElement.setAttribute('lang','pl');
            } catch(e){}
            var style = document.createElement('style');
            style.textContent = '[data-testid=\"lang-toggle\"],button[title*=\"Switch to\"],button[title*=\"切换到\"]{display:none!important;}';
            (document.head||document.documentElement).appendChild(style);
        })();
        """
        let script = WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(script)

        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url != url {
            nsView.load(URLRequest(url: url))
        }
    }
}
