import Cocoa
import Quartz
import UniformTypeIdentifiers

// Data-based QuickLook preview (macOS 12+).
// The extension generates a self-contained HTML string; QuickLook renders it
// in its own process, so no WKWebView or sandbox IPC issues in the extension.
class PreviewViewController: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let data = try Data(contentsOf: url)
        let markdown = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        guard let resourcesDir = Bundle.main.resourceURL else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        let renderURL = resourcesDir.appendingPathComponent("render.html")
        guard var html = try? String(contentsOf: renderURL, encoding: .utf8) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        // Inline all external CSS/JS so the HTML is fully self-contained.
        html = inlineResources(html, resourcesDir: resourcesDir)

        // Embed the markdown and trigger render() on DOMContentLoaded.
        // All scripts are already inlined, so render() is defined by then.
        let baseDir = url.deletingLastPathComponent().path
        guard let markdownJSON = jsonString(markdown),
              let baseDirJSON = jsonString(baseDir) else {
            throw CocoaError(.fileReadUnknown)
        }

        let autoRender = """
        <script>
        document.addEventListener('DOMContentLoaded', function() {
            if (typeof render === 'function') render(\(markdownJSON), \(baseDirJSON));
        });
        </script>
        """
        html = html.replacingOccurrences(of: "</body>", with: autoRender + "</body>")

        guard let htmlData = html.data(using: .utf8) else {
            throw CocoaError(.fileReadUnknown)
        }

        return QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 800, height: 600)
        ) { _ in htmlData }
    }

    // Replaces <link href="X.css"> and <script src="X.js"> with inline content.
    // Disables the mermaid lazy-loader (dynamic script.src won't resolve without
    // a file-system base URL in QuickLook's renderer).
    private func inlineResources(_ html: String, resourcesDir: URL) -> String {
        var result = html

        // <link rel="stylesheet" href="X.css" ...> → <style>...</style>
        if let re = try? NSRegularExpression(pattern: #"<link\b[^>]*\bhref="([^"]+\.css)"[^>]*>"#) {
            let ns = result as NSString
            for match in re.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
                guard let full = Range(match.range, in: result),
                      let name = Range(match.range(at: 1), in: result) else { continue }
                let css = (try? String(contentsOf: resourcesDir.appendingPathComponent(String(result[name])), encoding: .utf8)) ?? ""
                result.replaceSubrange(full, with: "<style>\(css)</style>")
            }
        }

        // <script src="X.js"></script> → <script>...</script>
        if let re = try? NSRegularExpression(pattern: #"<script src="([^"]+\.js)"></script>"#) {
            let ns = result as NSString
            for match in re.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
                guard let full = Range(match.range, in: result),
                      let name = Range(match.range(at: 1), in: result) else { continue }
                let js = (try? String(contentsOf: resourcesDir.appendingPathComponent(String(result[name])), encoding: .utf8)) ?? ""
                result.replaceSubrange(full, with: "<script>\(js)</script>")
            }
        }

        // Disable mermaid dynamic loader — no file-system base URL in QLPreviewReply.
        result = result.replacingOccurrences(
            of: "script.src = 'mermaid.min.js'",
            with: "return; //"
        )

        return result
    }

    private func jsonString(_ value: String) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
