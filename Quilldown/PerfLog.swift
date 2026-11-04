import Foundation
import os.signpost

/// Lightweight performance instrumentation. Writes durations to
/// `/tmp/quilldown-perf.log` and emits `os_signpost` intervals so the same
/// spans show up in Instruments (Points of Interest / custom categories).
///
/// Usage:
/// ```
/// let id = PerfLog.begin(.editor, "highlight")
/// ...work...
/// PerfLog.end(.editor, "highlight", id, "bytes=\(len)")
/// ```
/// or
/// ```
/// PerfLog.measure(.preview, "render") { doRender() }
/// ```
enum PerfLog {
    enum Category: String {
        case editor  = "Editor"
        case preview = "Preview"
        case search  = "Search"

        var log: OSLog {
            switch self {
            case .editor:  return OSLog(subsystem: subsystem, category: rawValue)
            case .preview: return OSLog(subsystem: subsystem, category: rawValue)
            case .search:  return OSLog(subsystem: subsystem, category: rawValue)
            }
        }
    }

    private static let subsystem = "com.quilldown.perf"
    private static let fileURL = URL(fileURLWithPath: "/tmp/quilldown-perf.log")

    struct Token {
        let id: OSSignpostID
        let log: OSLog
        let name: StaticString
        let start: CFAbsoluteTime
    }

    @discardableResult
    static func begin(_ cat: Category, _ name: StaticString) -> Token {
        let log = cat.log
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return Token(id: id, log: log, name: name, start: CFAbsoluteTimeGetCurrent())
    }

    static func end(_ token: Token, _ note: String = "") {
        let ms = (CFAbsoluteTimeGetCurrent() - token.start) * 1000
        os_signpost(.end, log: token.log, name: token.name, signpostID: token.id,
                    "%{public}.2fms %{public}s", ms, note)
        writeLine("[\(token.name)] \(String(format: "%7.2f", ms))ms \(note)")
    }

    @discardableResult
    static func measure<T>(_ cat: Category, _ name: StaticString, note: String = "", _ body: () throws -> T) rethrows -> T {
        let t = begin(cat, name)
        defer { end(t, note) }
        return try body()
    }

    private static func writeLine(_ s: String) {
        let line = "[\(Self.timestamp())] \(s)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: fileURL) {
            defer { try? h.close() }
            try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static func timestamp() -> String { formatter.string(from: Date()) }
}
