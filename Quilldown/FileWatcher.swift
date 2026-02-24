import Foundation
import Combine

class FileWatcher: ObservableObject {
    @Published var lastChangeDate = Date()
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var debounceTimer: Timer?
    private var watchedURL: URL?

    func watch(url: URL) {
        stopWatching()
        watchedURL = url

        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source?.setEventHandler { [weak self] in
            guard let self = self else { return }

            let events = self.source?.data ?? []

            // For rename/delete events, re-establish the watcher
            // (editors like vim/emacs save via rename, which invalidates the old inode)
            if events.contains(.rename) || events.contains(.delete) {
                if let url = self.watchedURL {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.watch(url: url)
                    }
                }
            }

            self.debounceTimer?.invalidate()
            self.debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                self.lastChangeDate = Date()
            }
        }

        source?.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
            }
            self?.fileDescriptor = -1
        }

        source?.resume()
    }

    func stopWatching() {
        source?.cancel()
        source = nil
        debounceTimer?.invalidate()
    }

    deinit {
        stopWatching()
    }
}
