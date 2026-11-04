import Foundation
import Combine

final class FileWatcher: ObservableObject {
    @Published var lastChangeDate = Date()
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var debounceWork: DispatchWorkItem?
    private var watchedURL: URL?

    func watch(url: URL) {
        stopWatching()
        watchedURL = url
        // The parent survives atomic saves and delayed delete/recreate cycles.
        // The file source also catches in-place writes, which need not emit a
        // directory event. Each source owns its descriptor until cancellation.
        directorySource = makeSource(url: url.deletingLastPathComponent())
        fileSource = makeSource(url: url)
    }

    private func makeSource(url: URL) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleChange() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    func scheduleChange() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let url = self.watchedURL else { return }
            self.fileSource?.cancel()
            self.fileSource = self.makeSource(url: url)
            self.lastChangeDate = Date()
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func stopWatching() {
        debounceWork?.cancel()
        debounceWork = nil
        watchedURL = nil
        fileSource?.cancel()
        fileSource = nil
        directorySource?.cancel()
        directorySource = nil
    }

    deinit { stopWatching() }
}
