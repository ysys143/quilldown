import SwiftUI
import Combine

/// Own the file-presenter policy rather than racing SwiftUI's DocumentGroup
/// against a second file watcher. Disk changes are always accepted silently.
@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument, ObservableObject {
    static let markdownType = "net.daringfireball.markdown"

    // NSTextView's undo manager drives NSDocument's change count. Counting
    // again in didSet would leave the document dirty after undoing all edits.
    @Published var text = ""
    private var lastDiskData: Data?
    private let fileWatcher = FileWatcher()
    private var changeSubscription: AnyCancellable?
    private var isClosed = false

    override init() {
        super.init()
        hasUndoManager = true
        changeSubscription = fileWatcher.$lastChangeDate.dropFirst().sink { [weak self] _ in
            self?.reloadFromDisk()
        }
    }

    override class var autosavesInPlace: Bool { true }

    override var fileURL: URL? {
        didSet {
            guard fileURL != oldValue else { return }
            objectWillChange.send()
            if let fileURL { fileWatcher.watch(url: fileURL) }
            else { fileWatcher.stopWatching() }
        }
    }

    override func makeWindowControllers() {
        let host = NSHostingController(rootView: ContentView(document: self))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 1100, height: 750))
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
        window.center()
        window.setFrameAutosaveName("MarkdownDocument")
        addWindowController(NSWindowController(window: window))
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let contents = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
        guard let decoded = String(data: contents, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        text = decoded
        lastDiskData = data
    }

    override func data(ofType typeName: String) throws -> Data { Data(text.utf8) }

    override func presentedItemDidChange() {
        // NSDocument's default implementation may ask whether to retain local
        // edits. Use the same debounced reload for coordinated and vnode writes.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.fileWatcher.scheduleChange()
        }
    }

    func reloadFromDisk() {
        do {
            try refreshFromDisk()
        } catch {
            // An editor may briefly remove the path while saving atomically.
            // Keep the current contents; the directory watcher catches recreation.
            NSLog("Quilldown: could not reload %@: %@", fileURL?.path ?? "", error.localizedDescription)
        }
    }

    private func refreshFromDisk() throws {
        guard !isClosed, let url = fileURL else { return }
        let data = try Data(contentsOf: url)
        let contents = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
        if data == lastDiskData || String(data: contents, encoding: .utf8) == text {
            // Our own save or a metadata-only update must not clear undo.
            lastDiskData = data
            fileModificationDate = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return
        }
        // Revert also updates the modification date, edited state, and undo.
        try revert(toContentsOf: url, ofType: fileType ?? Self.markdownType)
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        // Cmd+S can arrive before the watcher debounce. Accept the disk change
        // first so NSDocument never reaches its external-modification dialog.
        if url == fileURL && (saveOperation == .saveOperation || saveOperation == .autosaveInPlaceOperation) {
            do { try refreshFromDisk() }
            catch { completionHandler(error); return }
        }
        // This document uses NSDocument's synchronous writing. Keep the exact
        // snapshot sent to disk, even if the user types before the vnode event.
        let savedData = Data(text.utf8)
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if error == nil, let self, self.fileURL == url { self.lastDiskData = savedData }
            completionHandler(error)
        }
    }

    override func close() {
        isClosed = true
        fileWatcher.stopWatching()
        super.close()
    }
}
