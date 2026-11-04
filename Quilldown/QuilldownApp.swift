import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension Notification.Name {
    static let reloadDocument = Notification.Name("reloadDocument")
}

@main
struct QuilldownApp: App {

    @NSApplicationDelegateAdaptor(DocumentAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") { NSDocumentController.shared.newDocument(nil) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open...") { NSDocumentController.shared.openDocument(nil) }
                    .keyboardShortcut("o", modifiers: .command)
                Menu("Open Recent") {
                    ForEach(NSDocumentController.shared.recentDocumentURLs, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                        }
                    }
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { NSDocumentController.shared.currentDocument?.save(nil) }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save As...") { NSDocumentController.shared.currentDocument?.saveAs(nil) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
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

final class DocumentAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = NSDocumentController.shared
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.newDocument(nil)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { application.presentError(error) }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSDocumentController.shared.newDocument(nil) }
        return true
    }
}
