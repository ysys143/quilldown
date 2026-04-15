import SwiftUI
import AppKit

struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text: String
    var syncCoordinator: SyncCoordinator?

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditorView
        var isUpdating = false
        var isSyncScrolling = false
        weak var scrollView: NSScrollView?
        let highlighter = MarkdownHighlighter()

        init(parent: MarkdownEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            // Highlighting is driven by the NSTextStorageDelegate (see
            // highlighter) so it can run paragraph-scoped using editedRange.
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let selectedRange = textView.selectedRange()
            if selectedRange.length == 0 { return }

            let startLineNum = lineNumber(at: selectedRange.location, in: textView.string)
            let endLineNum = lineNumber(at: selectedRange.location + selectedRange.length, in: textView.string)
            parent.syncCoordinator?.editorSelectedLines(startLineNum, endLineNum + 1)
        }

        func lineNumber(at offset: Int, in text: String) -> Int {
            let safeOffset = min(offset, text.count)
            let prefix = text.prefix(safeOffset)
            return prefix.filter { $0 == "\n" }.count
        }

        @objc func scrollViewDidScroll(_ notification: Notification) {
            guard !isSyncScrolling,
                  let clipView = notification.object as? NSClipView,
                  let sv = clipView.superview as? NSScrollView,
                  let textView = sv.documentView as? NSTextView else { return }

            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            let visibleRect = clipView.bounds
            let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

            let line = lineNumber(at: charRange.location, in: textView.string)
            parent.syncCoordinator?.editorScrolledToLine(line)
        }

        func scrollToLine(_ line: Int, in textView: NSTextView) {
            isSyncScrolling = true
            let text = textView.string
            var currentLine = 0
            var offset = 0
            for (i, char) in text.enumerated() {
                if currentLine >= line {
                    offset = i
                    break
                }
                if char == "\n" { currentLine += 1 }
            }
            if currentLine < line { offset = text.count }

            guard let layoutManager = textView.layoutManager else {
                isSyncScrolling = false
                return
            }
            let safeOffset = min(offset, (textView.string as NSString).length)
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: safeOffset)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)

            if let sv = textView.enclosingScrollView {
                sv.contentView.scroll(to: NSPoint(x: 0, y: lineRect.origin.y))
                sv.reflectScrolledClipView(sv.contentView)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.isSyncScrolling = false
            }
        }

        func scrollToLineFromPreview(_ line: Int) {
            guard let sv = scrollView, let tv = sv.documentView as? NSTextView else { return }
            scrollToLine(line, in: tv)
        }

        func highlightLines(_ startLine: Int, _ endLine: Int, in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager else { return }
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)

            let nsText = textView.string as NSString
            var currentLine = 0
            var i = 0
            var highlightStart = -1
            var highlightEnd = -1

            while i <= nsText.length {
                if currentLine == startLine && highlightStart == -1 { highlightStart = i }
                if currentLine >= endLine { highlightEnd = i; break }
                if i < nsText.length && nsText.character(at: i) == 0x0A { currentLine += 1 }
                i += 1
            }
            if highlightEnd == -1 { highlightEnd = nsText.length }

            if highlightStart >= 0 && highlightStart < highlightEnd {
                let range = NSRange(location: highlightStart, length: highlightEnd - highlightStart)
                let color = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.3)
                layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
            }
        }

        func highlightLinesFromPreview(_ start: Int, _ end: Int) {
            guard let sv = scrollView, let tv = sv.documentView as? NSTextView else { return }
            highlightLines(start, end, in: tv)
        }

        func clearHighlight(in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager else { return }
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        }

        func clearHighlightFromPreview() {
            guard let sv = scrollView, let tv = sv.documentView as? NSTextView else { return }
            clearHighlight(in: tv)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tMake = PerfLog.begin(.editor, "makeNSView")
        defer { PerfLog.end(tMake, "chars=\(text.count)") }
        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        // Rich text is required so our syntax-highlighting attributes are
        // actually rendered. We still suppress user-facing rich-text behaviors
        // (link detection, smart quotes, etc.) so the content stays plain
        // markdown — the attributes exist only as a visual overlay.
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 32, height: 16)
        // Remove the default 5pt glyph-edge padding so the text's left edge
        // lines up with the preview's 32px body padding.
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = context.coordinator

        // Attach the highlighter as the storage delegate BEFORE assigning the
        // initial text, so the first didProcessEditing fires on full range and
        // styles the loaded document in one pass. All subsequent edits flow
        // through the same delegate path with a paragraph-scoped editedRange.
        textView.textStorage?.delegate = context.coordinator.highlighter
        textView.string = text

        // Layout performance: allow idle-time layout and non-contiguous
        // viewport-only layout so large documents don't stall the main thread.
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.layoutManager?.backgroundLayoutEnabled = true

        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView
        scrollView.drawsBackground = true

        context.coordinator.scrollView = scrollView
        syncCoordinator?.editorCoordinator = context.coordinator

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        context.coordinator.scrollView = scrollView
        syncCoordinator?.editorCoordinator = context.coordinator

        if textView.string != text && !context.coordinator.isUpdating {
            context.coordinator.isUpdating = true
            let selectedRanges = textView.selectedRanges
            // Assigning `string` replaces the full text, so the storage
            // delegate fires with an editedRange covering the new content and
            // the highlighter runs once for the whole document.
            textView.string = text
            textView.selectedRanges = selectedRanges
            context.coordinator.isUpdating = false
        }
    }
}
