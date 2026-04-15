import WebKit

class WebViewStore: ObservableObject {
    static let shared = WebViewStore()
    weak var activeWebView: WKWebView?

    /// Keeps a throwaway WKWebView alive so the WebKit subsystem (content
    /// process, GPU process, font cache, shared caches) is already running by
    /// the time the user opens a document. Without this, the first document
    /// pays ~600ms of cold-start cost.
    private var warmupView: WKWebView?

    @MainActor
    func warmup() {
        guard warmupView == nil else { return }
        let t = PerfLog.begin(.preview, "warmup")
        let v = WKWebView(frame: .zero)
        v.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        warmupView = v
        PerfLog.end(t)
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
