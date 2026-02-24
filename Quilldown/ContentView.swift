import SwiftUI

struct ContentView: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?

    @StateObject private var fileWatcher = FileWatcher()
    @StateObject private var syncCoordinator = SyncCoordinator()
    @State private var tocItems: [TOCItem] = []
    @State private var showSidebar = false
    @State private var scrollToAnchor: String?
    @State private var viewMode: ViewMode = .preview
    @State private var singleViewWidth: CGFloat = 0
    @State private var tocUpdateWorkItem: DispatchWorkItem?

    var body: some View {
        HStack(spacing: 0) {
            // Custom sidebar with animated width
            VStack(spacing: 0) {
                if tocItems.isEmpty {
                    Text("No headings")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TOCSidebarView(items: tocItems) { item in
                        scrollToAnchor = item.anchor
                    }
                }
            }
            .frame(width: showSidebar ? 280 : 0)
            .clipped()

            if showSidebar {
                Divider()
            }

            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(.background)
        .onAppear {
            tocItems = parseTableOfContents(from: document.text)
            if let url = fileURL {
                fileWatcher.watch(url: url)
            }
        }
        .onChange(of: document.text) {
            tocUpdateWorkItem?.cancel()
            let work = DispatchWorkItem {
                tocItems = parseTableOfContents(from: document.text)
            }
            tocUpdateWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        .onChange(of: fileWatcher.lastChangeDate) {
            reloadFile()
        }
        .onChange(of: viewMode) { oldMode, newMode in
            DispatchQueue.main.async {
                guard let window = NSApp.keyWindow else { return }
                let frame = window.frame
                guard let screen = window.screen ?? NSScreen.main else { return }
                let screenFrame = screen.visibleFrame

                if newMode == .split && oldMode != .split {
                    singleViewWidth = frame.width
                    let sidebarWidth: CGFloat = showSidebar ? 280 : 0
                    let contentWidth = frame.width - sidebarWidth
                    let expandBy = contentWidth
                    let newWidth = min(frame.width + expandBy, screenFrame.width)
                    let newX = max(screenFrame.origin.x, frame.origin.x - (newWidth - frame.width) / 2)
                    let clampedX = min(newX, screenFrame.maxX - newWidth)
                    let newFrame = NSRect(x: clampedX, y: frame.origin.y, width: newWidth, height: frame.height)
                    window.setFrame(newFrame, display: true, animate: true)
                } else if oldMode == .split && newMode != .split {
                    let targetWidth = singleViewWidth > 0 ? singleViewWidth : 1100
                    let newWidth = max(targetWidth, 900)
                    let newX = frame.origin.x + (frame.width - newWidth) / 2
                    let clampedX = max(screenFrame.origin.x, min(newX, screenFrame.maxX - newWidth))
                    let newFrame = NSRect(x: clampedX, y: frame.origin.y, width: newWidth, height: frame.height)
                    window.setFrame(newFrame, display: true, animate: true)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .reloadDocument)) { _ in
            reloadFile()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSidebar.toggle()
                    }
                }) {
                    Image(systemName: "sidebar.left")
                }
                .help("Toggle Sidebar (Cmd+B)")
            }

            ToolbarItem(placement: .principal) {
                Picker("View Mode", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Label(mode.rawValue, systemImage: mode.icon)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            ToolbarItem(placement: .navigation) {
                Button(action: {
                    if let wv = WebViewStore.shared.activeWebView {
                        wv.magnification = min(wv.magnification + 0.1, 3.0)
                    }
                }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("Zoom In")
                .keyboardShortcut("=", modifiers: .command)
            }
            ToolbarItem(placement: .navigation) {
                Button(action: {
                    if let wv = WebViewStore.shared.activeWebView {
                        wv.magnification = max(wv.magnification - 0.1, 0.5)
                    }
                }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Zoom Out")
                .keyboardShortcut("-", modifiers: .command)
            }
        }
        // Hidden buttons for keyboard shortcuts
        .background {
            Group {
                Button("") { viewMode = .editor }
                    .keyboardShortcut("1", modifiers: .command)
                Button("") { viewMode = .split }
                    .keyboardShortcut("2", modifiers: .command)
                Button("") { viewMode = .preview }
                    .keyboardShortcut("3", modifiers: .command)
                Button("") {
                    withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() }
                }
                .keyboardShortcut("b", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch viewMode {
        case .editor:
            MarkdownEditorView(text: $document.text)
        case .preview:
            MarkdownWebView(
                markdown: document.text,
                scrollToAnchor: $scrollToAnchor,
                fileURL: fileURL
            )
        case .split:
            HSplitView {
                MarkdownEditorView(
                    text: $document.text,
                    syncCoordinator: syncCoordinator
                )
                .frame(minWidth: 300)

                MarkdownWebView(
                    markdown: document.text,
                    scrollToAnchor: $scrollToAnchor,
                    syncCoordinator: syncCoordinator,
                    fileURL: fileURL
                )
                .frame(minWidth: 300)
            }
        }
    }

    private func reloadFile() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        document.text = text
        tocItems = parseTableOfContents(from: text)
    }
}
