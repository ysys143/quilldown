import SwiftUI
import WebKit

struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    @Binding var scrollToAnchor: String?

    class Coordinator: NSObject, WKNavigationDelegate {
        var lastScrollY: CGFloat = 0

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                // Allow initial page load and anchor navigation
                if url.scheme == "about" || url.absoluteString.contains("{{") || navigationAction.navigationType == .other {
                    decisionHandler(.allow)
                    return
                }
                // Open external links in default browser
                if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator

        // Register with the global store
        WebViewStore.shared.activeWebView = webView

        loadContent(in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Keep store reference current
        WebViewStore.shared.activeWebView = webView

        // Save scroll position before reloading
        webView.evaluateJavaScript("window.scrollY") { result, _ in
            if let y = result as? CGFloat {
                context.coordinator.lastScrollY = y
            }
        }

        loadContent(in: webView, coordinator: context.coordinator)

        // Handle TOC anchor scrolling
        if let anchor = scrollToAnchor {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let safeAnchor = anchor
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                webView.evaluateJavaScript(
                    "document.getElementById('\(safeAnchor)')?.scrollIntoView({behavior: 'smooth'});"
                )
                DispatchQueue.main.async {
                    self.scrollToAnchor = nil
                }
            }
        }
    }

    private func loadContent(in webView: WKWebView, coordinator: Coordinator) {
        guard let resourceURL = Bundle.main.resourceURL else { return }

        let escaped = markdown
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")

        guard let htmlURL = Bundle.main.url(forResource: "render", withExtension: "html") else { return }
        guard let htmlTemplate = try? String(contentsOf: htmlURL, encoding: .utf8) else { return }

        let scrollRestore = coordinator.lastScrollY > 0
            ? "window.scrollTo(0, \(coordinator.lastScrollY));"
            : ""

        let html = htmlTemplate
            .replacingOccurrences(of: "{{MARKDOWN_CONTENT}}", with: escaped)
            .replacingOccurrences(of: "{{SCROLL_RESTORE}}", with: scrollRestore)

        webView.loadHTMLString(html, baseURL: resourceURL)
    }
}
