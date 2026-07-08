import AppKit
import CryptoKit
import WebKit

// MARK: - MermaidRenderer

/// F26.9: renders ```mermaid blocks to a static image via ONE shared, offscreen
/// `WKWebView` reused across every diagram in the app — per Fable's review, a
/// WKWebView per bubble would be a real-RAM problem on 16GB with many diagrams
/// in history. Mermaid.js is bundled (`Resources/mermaid.min.js`, F26.9 spec:
/// zero network access for UI). Results are cached by content hash so
/// scrolling past the same diagram twice never re-renders it.
@MainActor
final class MermaidRenderer {
    static let shared = MermaidRenderer()

    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var navigationDelegate: NavigationWaiter?
    private var cache: [String: NSImage] = [:]
    private var isBusy = false
    private var mermaidJS: String?

    private init() {}

    /// Bridges `WKNavigationDelegate` callbacks to `async`/`await`. Polling
    /// `document.readyState` instead of this reliably raced `loadFileURL`: the
    /// reused WKWebView's *previous* document (already "complete") answered the
    /// poll before the new page had even started navigating, so every render
    /// after the first evaluated `mermaid` against stale/blank content —
    /// verified live (instant "mermaid global missing", zero JS errors, because
    /// the JS never ran against the real page at all).
    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Never>?

        func waitForLoad(_ webView: WKWebView) async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                webView.navigationDelegate = self
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            NSLog("[Mermaid] navigation didFail: \(error)")
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            NSLog("[Mermaid] navigation didFailProvisional: \(error)")
            continuation?.resume()
            continuation = nil
        }
    }

    /// Returns `nil` on any failure (missing bundle resource, JS error, timeout)
    /// — callers fall back to showing the raw ```mermaid source as a code block,
    /// per spec: never a blank screen.
    func render(code: String) async -> NSImage? {
        let key = Self.hash(code)
        if let cached = cache[key] { return cached }

        while isBusy {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let cached = cache[key] { return cached }
        isBusy = true
        defer { isBusy = false }

        guard let image = await performRender(code: code) else { return nil }
        cache[key] = image
        return image
    }

    private func performRender(code: String) async -> NSImage? {
        guard let js = loadMermaidJS() else { return nil }
        let webView = ensureWebView()

        let escaped = code
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;padding:0;background:transparent;}
        .mermaid{background:transparent;}</style>
        <script>
        // Must run BEFORE the mermaid bundle below: a runtime error thrown while
        // mermaid.min.js executes is only caught if window.onerror already exists
        // at that point — installing it in a later <script> tag misses it entirely
        // (verified: this was silently swallowing the real error, showing up
        // downstream as "mermaid global missing" with zero diagnostic).
        window.__jsErrors = [];
        window.onerror = function(msg, src, line, col, err) {
            window.__jsErrors.push(String(msg) + ' @' + line + ':' + col + (err && err.stack ? ' ' + err.stack : ''));
        };
        window.addEventListener('unhandledrejection', function(e) {
            window.__jsErrors.push('unhandledrejection: ' + String(e.reason && e.reason.message || e.reason));
        });
        var __origConsoleError = console.error;
        console.error = function() {
            window.__jsErrors.push('console.error: ' + Array.prototype.slice.call(arguments).join(' '));
            __origConsoleError.apply(console, arguments);
        };
        </script>
        <script>\(js)</script>
        </head><body>
        <div class="mermaid">\(escaped)</div>
        <script>
        if (typeof mermaid !== 'undefined') {
            mermaid.initialize({startOnLoad:false,theme:'dark'});
        }
        </script>
        </body></html>
        """
        // `loadHTMLString(_:baseURL: nil)` gives the page a null/opaque origin,
        // which sandboxes enough web platform surface (module loading, workers)
        // that `mermaid.run()`'s Promise never settled — verified live (no JS
        // error surfaced anywhere, it just hung). A real `file://` origin via a
        // temp file avoids that.
        let tempDir = FileManager.default.temporaryDirectory
        let htmlURL = tempDir.appendingPathComponent("kiwimango-mermaid-\(UUID().uuidString).html")
        defer { try? FileManager.default.removeItem(at: htmlURL) }
        try? html.write(to: htmlURL, atomically: true, encoding: .utf8)

        let waiter = NavigationWaiter()
        navigationDelegate = waiter
        webView.navigationDelegate = waiter
        webView.loadFileURL(htmlURL, allowingReadAccessTo: tempDir)
        await waiter.waitForLoad(webView)

        // Fire `mermaid.run()` without awaiting its Promise through `evaluateJavaScript`
        // — an async-IIFE completion value reliably threw WKErrorDomain code 5
        // ("unsupported type") in this WebKit, verified live. Poll a plain global
        // boolean instead: every synchronous JS call here returns a primitive.
        do {
            _ = try await webView.evaluateJavaScript(
                "window.__mermaidDone = false; window.__mermaidError = null; " +
                "typeof mermaid === 'undefined' ? (window.__mermaidError = 'mermaid global missing', window.__mermaidDone = true) : " +
                "mermaid.run({querySelector: '.mermaid'})" +
                ".then(() => { window.__mermaidDone = true; })" +
                ".catch((e) => { window.__mermaidError = String((e && e.message) || e); window.__mermaidDone = true; });"
            )
        } catch {
            NSLog("[Mermaid] kickoff evaluateJavaScript threw: \(error)")
        }

        let runDeadline = Date().addingTimeInterval(5)
        while Date() < runDeadline {
            if let done = try? await webView.evaluateJavaScript("window.__mermaidDone === true") as? Bool, done {
                break
            }
            try? await Task.sleep(for: .milliseconds(80))
        }

        if let errorText = try? await webView.evaluateJavaScript("window.__mermaidError") as? String {
            let jsErrors = (try? await webView.evaluateJavaScript("JSON.stringify(window.__jsErrors || [])")) as? String
            NSLog("[Mermaid] mermaid.run() failed: \(errorText), jsErrors=\(jsErrors ?? "?")")
            return nil
        }

        guard let rectJSON = try? await webView.evaluateJavaScript(
            "(() => { const s = document.querySelector('svg'); if (!s) return null; " +
            "const r = s.getBoundingClientRect(); return JSON.stringify({w: Math.ceil(r.width), h: Math.ceil(r.height)}); })()"
        ) as? String else {
            NSLog("[Mermaid] no svg found after render")
            return nil
        }
        guard let data = rectJSON.data(using: .utf8),
              let size = try? JSONDecoder().decode(RectSize.self, from: data),
              size.w > 0, size.h > 0 else {
            NSLog("[Mermaid] bad rect JSON: \(rectJSON)")
            return nil
        }

        let width = min(size.w, 700)
        let scale = width / size.w
        let height = size.h * scale
        webView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        // Let AppKit actually lay out + repaint at the new frame size before
        // snapshotting it — resizing and snapshotting in the same runloop turn
        // can capture a stale/blank frame.
        try? await Task.sleep(for: .milliseconds(100))

        return await withCheckedContinuation { continuation in
            let config = WKSnapshotConfiguration()
            config.rect = NSRect(x: 0, y: 0, width: width, height: height)
            webView.takeSnapshot(with: config) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private struct RectSize: Decodable { let w: Double; let h: Double }

    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        wv.underPageBackgroundColor = .clear

        // WebKit throttles/suspends rendering work (rAF, timers — `mermaid.run()`'s
        // Promise hung forever under this, verified live) for pages it considers
        // "not visible". Both a near-zero-alpha subview AND a subview z-ordered
        // behind opaque siblings still tripped that. Fix (standard offscreen-WKWebView
        // pattern): a genuinely separate, ordered-front `NSWindow` parked at
        // coordinates outside every physical display — WebKit sees a displayed
        // window and never throttles it, but no monitor covers those coordinates
        // so the user never sees it either.
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = wv
        window.orderFront(nil)
        hostWindow = window

        webView = wv
        return wv
    }

    private func loadMermaidJS() -> String? {
        if let mermaidJS { return mermaidJS }
        guard let url = Bundle.module.url(forResource: "mermaid.min", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        mermaidJS = js
        return js
    }

    private static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
