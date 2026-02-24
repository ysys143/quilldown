import SwiftUI

struct ContentView: View {
    let document: MarkdownDocument
    let fileURL: URL?

    @StateObject private var fileWatcher = FileWatcher()
    @State private var currentText: String = ""
    @State private var tocItems: [TOCItem] = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var scrollToAnchor: String?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            if tocItems.isEmpty {
                Text("No headings")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TOCSidebarView(items: tocItems) { item in
                    scrollToAnchor = item.anchor
                }
            }
        } detail: {
            MarkdownWebView(
                markdown: currentText,
                scrollToAnchor: $scrollToAnchor
            )
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        .frame(minWidth: 700, minHeight: 400)
        .onAppear {
            currentText = document.text
            tocItems = parseTableOfContents(from: currentText)
            if let url = fileURL {
                fileWatcher.watch(url: url)
            }
        }
        .onChange(of: fileWatcher.lastChangeDate) {
            reloadFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .reloadDocument)) { _ in
            reloadFile()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: {
                    withAnimation {
                        columnVisibility = columnVisibility == .all ? .detailOnly : .all
                    }
                }) {
                    Image(systemName: "sidebar.left")
                }
                .help("Toggle Table of Contents")
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }
    }

    private func reloadFile() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        currentText = text
        tocItems = parseTableOfContents(from: text)
    }
}
