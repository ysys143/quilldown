import SwiftUI
import WebKit

struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    @Binding var scrollToAnchor: String?
    var syncCoordinator: SyncCoordinator?
    var fileURL: URL?

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastScrollY: CGFloat = 0
        var parent: MarkdownWebView?
        var currentMarkdown: String = ""
        var pendingAnchor: String?
        var pageLoaded = false
        weak var webView: WKWebView?
        var isSyncScrolling = false
        var baseDirectory: String = ""
        private var renderWorkItem: DispatchWorkItem?
        var htmlLoadToken: PerfLog.Token?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !isSyncScrolling,
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            switch type {
            case "scroll":
                if let line = body["line"] as? Int {
                    parent?.syncCoordinator?.previewScrolledToLine(line)
                }
            case "selection":
                if let startLine = body["startLine"] as? Int,
                   let endLine = body["endLine"] as? Int {
                    parent?.syncCoordinator?.previewSelectedLines(startLine, endLine)
                }
            case "selectionClear":
                parent?.syncCoordinator?.previewSelectedLines(-1, -1)
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let t = htmlLoadToken {
                PerfLog.end(t, "didFinish")
                htmlLoadToken = nil
            }
            self.webView = webView
            pageLoaded = true
            injectContent(into: webView)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                if url.scheme == "about" || url.scheme == "file" || navigationAction.navigationType == .other {
                    decisionHandler(.allow)
                    return
                }
                if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        private func encodeJSONString(_ value: String) -> String? {
            guard let jsonData = try? JSONEncoder().encode(value),
                  let jsonString = String(data: jsonData, encoding: .utf8) else { return nil }
            return jsonString
        }

        func injectContent(into webView: WKWebView) {
            guard let markdownJSON = encodeJSONString(currentMarkdown),
                  let baseDirJSON = encodeJSONString(baseDirectory) else { return }

            let scrollRestore = lastScrollY > 0
                ? "setTimeout(() => window.scrollTo(0, \(lastScrollY)), 50);"
                : ""

            let js = "render(\(markdownJSON), \(baseDirJSON)); \(scrollRestore)"
            let tRender = PerfLog.begin(.preview, "render.initial")
            webView.evaluateJavaScript(js) { [weak self, weak webView] _, error in
                PerfLog.end(tRender, "chars=\(self?.currentMarkdown.count ?? 0)\(error.map { " err=\($0.localizedDescription)" } ?? "")")
                // Warm WKWebView's find engine with a nonsense query so the
                // user's first real Cmd+F doesn't pay the internal indexing
                // cost (~300ms on a 100KB doc). Fires after first render so
                // the DOM is populated.
                guard let webView else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    let cfg = WKFindConfiguration()
                    cfg.caseSensitive = false
                    let t = PerfLog.begin(.search, "find.warmup")
                    _ = try? await webView.find("__quilldown_prewarm_sentinel__", configuration: cfg)
                    PerfLog.end(t)
                }
            }

            if let anchor = pendingAnchor {
                let safeAnchor = anchor
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    webView.evaluateJavaScript(
                        "document.getElementById('\(safeAnchor)')?.scrollIntoView({behavior: 'smooth'});"
                    )
                }
                pendingAnchor = nil
            }
        }

        func renderContent(_ markdown: String) {
            currentMarkdown = markdown
            guard pageLoaded, let webView = webView else { return }

            renderWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak webView] in
                guard let webView = webView else { return }
                guard let self,
                      let markdownJSON = self.encodeJSONString(markdown),
                      let baseDirJSON = self.encodeJSONString(self.baseDirectory) else { return }
                let t = PerfLog.begin(.preview, "render.edit")
                webView.evaluateJavaScript("render(\(markdownJSON), \(baseDirJSON))") { _, error in
                    PerfLog.end(t, "chars=\(markdown.count)\(error.map { " err=\($0.localizedDescription)" } ?? "")")
                }
                self.renderWorkItem = nil
            }
            renderWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
        }

        func scrollToSourceLine(_ line: Int) {
            guard pageLoaded, let webView = webView else { return }
            isSyncScrolling = true
            webView.evaluateJavaScript("scrollToSourceLine(\(line))") { _, _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.isSyncScrolling = false
            }
        }

        func highlightSourceLines(_ startLine: Int, _ endLine: Int) {
            guard pageLoaded, let webView = webView else { return }
            webView.evaluateJavaScript("highlightLines(\(startLine), \(endLine))") { _, _ in }
        }

        func clearHighlight() {
            guard pageLoaded, let webView = webView else { return }
            webView.evaluateJavaScript("clearHighlight()") { _, _ in }
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.parent = self
        coordinator.baseDirectory = fileURL?.deletingLastPathComponent().path ?? ""
        return coordinator
    }

    func makeNSView(context: Context) -> WKWebView {
        let tMake = PerfLog.begin(.preview, "makeNSView")
        defer { PerfLog.end(tMake) }

        let coordinator = context.coordinator
        coordinator.currentMarkdown = markdown
        coordinator.baseDirectory = fileURL?.deletingLastPathComponent().path ?? ""
        syncCoordinator?.previewCoordinator = coordinator

        // Try to claim a warmed WKWebView from the pool first. If the pool is
        // empty (second window, or warmup hasn't run yet), fall back to
        // creating a fresh instance.
        let webView: WKWebView
        let fromPool: Bool
        if let pooled = WebViewStore.shared.acquireWebView() {
            webView = pooled
            fromPool = true
        } else {
            webView = WebViewStore.shared.makeConfiguredWebView()
            fromPool = false
        }

        webView.navigationDelegate = coordinator
        webView.configuration.userContentController.add(coordinator, name: "scrollSync")
        WebViewStore.shared.activeWebView = webView
        coordinator.webView = webView

        if fromPool {
            if webView.isLoading == false {
                // render.html already fully loaded during warmup. Skip
                // loadFileURL entirely and render user content now.
                coordinator.pageLoaded = true
                coordinator.injectContent(into: webView)
            } else {
                // Pool hit but warmup hasn't finished the load yet. The new
                // navigationDelegate (coordinator) will receive didFinish
                // when the in-flight load completes — mark it so the render
                // happens once. Don't call loadPage again: that would cancel
                // the warmup's in-flight navigation and cost more than it
                // saves.
                coordinator.htmlLoadToken = PerfLog.begin(.preview, "htmlLoad.pool")
            }
        } else {
            // Fresh cold-start path.
            loadPage(in: webView, coordinator: coordinator)
        }

        return webView
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // Return the WKWebView to the pool so the next document can reuse it
        // without paying cold-start costs again.
        WebViewStore.shared.releaseWebView(webView)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        WebViewStore.shared.activeWebView = webView
        context.coordinator.webView = webView
        context.coordinator.parent = self
        syncCoordinator?.previewCoordinator = context.coordinator

        // Update base directory if file URL changed
        let newBaseDir = fileURL?.deletingLastPathComponent().path ?? ""
        let baseDirChanged = context.coordinator.baseDirectory != newBaseDir
        if baseDirChanged {
            context.coordinator.baseDirectory = newBaseDir
        }

        let markdownChanged = context.coordinator.currentMarkdown != markdown

        if context.coordinator.pageLoaded {
            if markdownChanged || baseDirChanged {
                context.coordinator.renderContent(markdown)
            }
        } else if markdownChanged {
            context.coordinator.currentMarkdown = markdown
        }

        if let anchor = scrollToAnchor {
            let safeAnchor = anchor
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let delay: Double = markdownChanged ? 0.3 : 0.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak webView] in
                webView?.evaluateJavaScript(
                    "document.getElementById('\(safeAnchor)')?.scrollIntoView({behavior: 'smooth'});"
                )
            }
            DispatchQueue.main.async {
                self.scrollToAnchor = nil
            }
        }
    }

    private func loadPage(in webView: WKWebView, coordinator: Coordinator) {
        guard let htmlURL = Bundle.main.url(forResource: "render", withExtension: "html") else { return }
        coordinator.htmlLoadToken = PerfLog.begin(.preview, "htmlLoad")
        // Allow read access to root so images from the markdown file's directory are accessible
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
    }
}
