import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension Notification.Name {
    static let reloadDocument = Notification.Name("reloadDocument")
}

@main
struct QuilldownApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { config in
            ContentView(document: config.$document, fileURL: config.fileURL)
        }
        .defaultSize(width: 1100, height: 750)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Zoom In") {
                    if let wv = WebViewStore.shared.activeWebView {
                        wv.magnification = min(wv.magnification + 0.1, 3.0)
                    }
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    if let wv = WebViewStore.shared.activeWebView {
                        wv.magnification = max(wv.magnification - 0.1, 0.5)
                    }
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    WebViewStore.shared.activeWebView?.magnification = 1.0
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()

                Button("Reload") {
                    NotificationCenter.default.post(name: .reloadDocument, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            CommandGroup(after: .printItem) {
                Button("Export as PDF...") {
                    exportPDF()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
    }

    private func exportPDF() {
        guard let webView = WebViewStore.shared.activeWebView else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Exported.pdf"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            let pdfConfig = WKPDFConfiguration()
            webView.createPDF(configuration: pdfConfig) { result in
                switch result {
                case .success(let data):
                    try? data.write(to: url)
                case .failure(let error):
                    print("PDF export failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
