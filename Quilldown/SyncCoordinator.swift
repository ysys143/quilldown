import Foundation
import WebKit
import AppKit

class SyncCoordinator: ObservableObject {
    enum Source { case none, editor, preview }
    var activeSource: Source = .none

    weak var editorCoordinator: MarkdownEditorView.Coordinator?
    weak var previewCoordinator: MarkdownWebView.Coordinator?

    func editorScrolledToLine(_ line: Int) {
        guard activeSource != .preview else { return }
        activeSource = .editor
        previewCoordinator?.scrollToSourceLine(line)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            if self?.activeSource == .editor { self?.activeSource = .none }
        }
    }

    func previewScrolledToLine(_ line: Int) {
        guard activeSource != .editor else { return }
        activeSource = .preview
        editorCoordinator?.scrollToLineFromPreview(line)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            if self?.activeSource == .preview { self?.activeSource = .none }
        }
    }

    func editorSelectedLines(_ start: Int, _ end: Int) {
        if start < 0 {
            previewCoordinator?.clearHighlight()
        } else {
            previewCoordinator?.highlightSourceLines(start, end)
        }
    }

    func previewSelectedLines(_ start: Int, _ end: Int) {
        if start < 0 {
            editorCoordinator?.clearHighlightFromPreview()
        } else {
            editorCoordinator?.highlightLinesFromPreview(start, end)
        }
    }
}
