import WebKit

/// Pool-backed WKWebView store. At app launch we eagerly create a fully-
/// configured WKWebView and load render.html into it, then hand it to the
/// first MarkdownWebView that asks. This converts the ~600ms cold start
/// (WebKit framework init + JS parse + HTML parse) into a background task
/// that happens while the user is still looking at the Finder open panel.
///
/// Pool size is 1 — typical usage is one document at a time. Additional
/// windows fall back to creating fresh WKWebView instances.
class WebViewStore: ObservableObject {
    static let shared = WebViewStore()
    weak var activeWebView: WKWebView?

    private var pool: [WKWebView] = []
    private let poolCapacity = 1

    /// Eagerly creates and fully loads a WKWebView so the first document
    /// acquired from the pool can render immediately.
    @MainActor
    func warmup() {
        guard pool.isEmpty else { return }
        let t = PerfLog.begin(.preview, "warmup")
        let view = makeConfiguredWebView()
        loadRenderHTML(into: view)
        pool.append(view)
        PerfLog.end(t)
    }

    /// Takes a warmed WKWebView out of the pool, if any. Returns nil when the
    /// pool is empty; caller should create a fresh instance in that case.
    @MainActor
    func acquireWebView() -> WKWebView? {
        guard !pool.isEmpty else { return nil }
        let view = pool.removeLast()
        view.navigationDelegate = nil
        // Drop any message handlers so the new owner can register fresh.
        view.configuration.userContentController.removeScriptMessageHandler(forName: "scrollSync")
        return view
    }

    /// Returns a WKWebView to the pool when its owning view goes away, so the
    /// next document to open can reuse it.
    @MainActor
    func releaseWebView(_ view: WKWebView) {
        guard pool.count < poolCapacity else { return }
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "scrollSync")
        // Don't bother clearing the rendered content: the next document's
        // render() will replace #content.innerHTML wholesale. An extra
        // evaluateJavaScript here just queues behind the next render() and
        // inflates its measured latency.
        pool.append(view)
    }

    /// Same configuration used by MarkdownWebView for live views so pooled
    /// instances are drop-in compatible.
    @MainActor
    func makeConfiguredWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: LocalFileSchemeHandler.scheme)
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.wantsLayer = true
        #if DEBUG
        view.isInspectable = true
        #endif
        return view
    }

    @MainActor
    func loadRenderHTML(into view: WKWebView) {
        guard let url = Bundle.main.url(forResource: "render", withExtension: "html") else { return }
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    /// Highlights the next (or previous) match of `query` in the active preview.
    /// Uses WKWebView's native find API (macOS 14+).
    @MainActor
    @discardableResult
    func findInPreview(_ query: String, forward: Bool = true, wraps: Bool = true) async -> Bool {
        guard let webView = activeWebView, !query.isEmpty else { return false }
        let config = WKFindConfiguration()
        config.backwards = !forward
        config.wraps = wraps
        config.caseSensitive = false
        let t = PerfLog.begin(.search, "webkit.find")
        defer { PerfLog.end(t, "q=\"\(query.prefix(20))\" fwd=\(forward)") }
        do {
            let result = try await webView.find(query, configuration: config)
            return result.matchFound
        } catch {
            return false
        }
    }

    /// Clears selection and any lingering find highlight in the preview.
    @MainActor
    func clearPreviewFind() {
        guard let webView = activeWebView else { return }
        webView.evaluateJavaScript("window.getSelection().removeAllRanges();")
    }
}
