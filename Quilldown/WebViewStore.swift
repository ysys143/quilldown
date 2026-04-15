import WebKit

class WebViewStore: ObservableObject {
    static let shared = WebViewStore()
    weak var activeWebView: WKWebView?

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
