import SwiftUI

struct ContentView: View {
    @ObservedObject var document: MarkdownDocument
    private var fileURL: URL? { document.fileURL }

    @StateObject private var syncCoordinator = SyncCoordinator()
    @State private var tocItems: [TOCItem] = []
    @State private var showSidebar = false
    @State private var scrollToAnchor: String?
    @State private var viewMode: ViewMode = .preview
    @State private var singleViewWidth: CGFloat = 0
    @State private var tocUpdateWorkItem: DispatchWorkItem?
    @State private var isSearchVisible = false
    @State private var searchQuery = ""
    @State private var keyMonitor: Any?

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
        }
        .onChange(of: document.text) {
            tocUpdateWorkItem?.cancel()
            let work = DispatchWorkItem {
                tocItems = parseTableOfContents(from: document.text)
            }
            tocUpdateWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
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
            if document.windowControllers.contains(where: { $0.window?.isKeyWindow == true }) {
                document.reloadFromDisk()
            }
        }
        .background(DocumentToolbar(
            navigation: AnyView(toolbarNavigation),
            principal: AnyView(toolbarModePicker),
            trailing: AnyView(toolbarSearch)
        ))
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
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: viewMode) { _, newMode in
            if newMode == .editor && isSearchVisible {
                isSearchVisible = false
                searchQuery = ""
                WebViewStore.shared.clearPreviewFind()
            }
        }
    }

    private var toolbarNavigation: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle Sidebar (Cmd+B)")

            Button {
                if let webView = WebViewStore.shared.activeWebView {
                    webView.magnification = min(webView.magnification + 0.1, 3.0)
                }
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom In")
            .keyboardShortcut("=", modifiers: .command)

            Button {
                if let webView = WebViewStore.shared.activeWebView {
                    webView.magnification = max(webView.magnification - 0.1, 0.5)
                }
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom Out")
            .keyboardShortcut("-", modifiers: .command)
        }
        .fixedSize()
    }

    private var toolbarModePicker: some View {
        Picker("View Mode", selection: $viewMode) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Label(mode.rawValue, systemImage: mode.icon).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 200)
    }

    @ViewBuilder
    private var toolbarSearch: some View {
        if isSearchVisible && viewMode != .editor {
            PreviewSearchBar(query: $searchQuery, isVisible: $isSearchVisible)
        } else {
            Button(action: invokeFind) { Image(systemName: "magnifyingglass") }
                .help("Find (Cmd+F)")
        }
    }

    // Intercepts Cmd+F at the window level. SwiftUI apps don't install the
    // default Edit ▸ Find menu, so NSTextView's `usesFindBar = true` has no
    // way to receive `performFindPanelAction:` unless we dispatch it manually.
    // In editor mode we send the show-find-panel action to the first responder
    // (NSTextView picks it up). In preview/split we show our floating bar.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Compare by hardware keyCode so Hangul/CJK input methods still
            // trigger the shortcut (characters would be "ㄹ" instead of "f").
            // kVK_ANSI_F == 3.
            let cmdF = event.modifierFlags.contains(.command)
                && event.keyCode == 3
            guard cmdF, document.windowControllers.contains(where: { $0.window === event.window }) else { return event }
            invokeFind()
            return nil
        }
    }

    /// Routes a Find request to the appropriate handler for the current view
    /// mode. In editor mode, forwards to NSTextView's native Find bar; in
    /// preview/split, surfaces the inline search field in the toolbar.
    private func invokeFind() {
        if viewMode == .editor {
            let item = NSMenuItem()
            item.tag = 1 // NSTextFinder.Action.showFindInterface
            NSApp.sendAction(
                #selector(NSResponder.performTextFinderAction(_:)),
                to: nil,
                from: item
            )
        } else {
            isSearchVisible = true
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        contentForMode
    }

    @ViewBuilder
    private var contentForMode: some View {
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

}

/// NSHostingController does not install SwiftUI scene toolbars. Keep these
/// controls in the native titlebar while NSDocument owns the window lifecycle.
private struct DocumentToolbar: NSViewRepresentable {
    let navigation: AnyView
    let principal: AnyView
    let trailing: AnyView

    final class AnchorView: NSView {
        var attach: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attach?(window) }
        }
    }

    final class Coordinator: NSObject, NSToolbarDelegate {
        let hosts = (0..<3).map { _ in NSHostingView(rootView: AnyView(EmptyView())) }
        let identifiers = ["navigation", "viewMode", "search"].map { NSToolbarItem.Identifier($0) }
        weak var window: NSWindow?

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            let toolbar = NSToolbar(identifier: "MarkdownToolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.centeredItemIdentifiers = [identifiers[1]]
            window.toolbar = toolbar
            window.toolbarStyle = .unified
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [identifiers[0], .flexibleSpace, identifiers[1], .flexibleSpace, identifiers[2]]
        }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            identifiers + [.flexibleSpace]
        }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            guard let index = identifiers.firstIndex(of: itemIdentifier) else { return nil }
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = hosts[index]
            item.isNavigational = index == 0
            return item
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> AnchorView {
        let anchor = AnchorView()
        anchor.attach = { [weak coordinator = context.coordinator] in coordinator?.attach(to: $0) }
        return anchor
    }
    func updateNSView(_ view: AnchorView, context: Context) {
        context.coordinator.hosts[0].rootView = navigation
        context.coordinator.hosts[1].rootView = principal
        context.coordinator.hosts[2].rootView = trailing
        if let window = view.window { context.coordinator.attach(to: window) }
    }
}
