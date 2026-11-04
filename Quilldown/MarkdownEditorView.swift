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
        var pendingExternalText: String?

        init(parent: MarkdownEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            if let pendingExternalText {
                if !textView.hasMarkedText() {
                    self.pendingExternalText = nil
                    replaceText(pendingExternalText, in: textView)
                }
                return
            }
            parent.text = textView.string
            // Highlighting is driven by the NSTextStorageDelegate (see
            // highlighter) so it can run paragraph-scoped using editedRange.
        }

        /// Replace only the changed span. Preserve the viewport's text anchor,
        /// rather than assigning `string` and resetting the entire layout.
        func replaceText(_ text: String, in textView: NSTextView) {
            guard textView.string != text else { return }
            if textView.hasMarkedText() {
                pendingExternalText = text
                return
            }
            pendingExternalText = nil
            let old = textView.string
            let prefix = zip(old, text).prefix { $0 == $1 }.map(\.0)
            let prefixLength = String(prefix).utf16.count
            let oldRest = old.dropFirst(prefix.count)
            let newRest = text.dropFirst(prefix.count)
            let suffix = zip(oldRest.reversed(), newRest.reversed()).prefix { $0 == $1 }.map(\.0)
            let suffixLength = String(suffix).utf16.count
            let replaced = NSRange(location: prefixLength, length: old.utf16.count - prefixLength - suffixLength)
            let insertedLength = text.utf16.count - prefixLength - suffixLength
            let inserted = (text as NSString).substring(with: NSRange(location: prefixLength, length: insertedLength))
            func mapped(_ offset: Int) -> Int {
                if offset <= replaced.location { return offset }
                if offset >= NSMaxRange(replaced) { return offset + insertedLength - replaced.length }
                return replaced.location + min(offset - replaced.location, insertedLength)
            }

            let selections = textView.selectedRanges.map { value -> NSValue in
                let range = value.rangeValue
                let start = mapped(range.location)
                return NSValue(range: NSRange(location: start, length: max(0, mapped(NSMaxRange(range)) - start)))
            }
            let clip = textView.enclosingScrollView?.contentView
            let origin = clip?.bounds.origin ?? .zero
            let layout = textView.layoutManager
            var anchor: Int?
            var anchorOffset: CGFloat = 0
            if let layout, let container = textView.textContainer, !old.isEmpty {
                let rect = (clip?.bounds ?? .zero).offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
                let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
                if glyphs.length > 0 {
                    anchor = mapped(layout.characterIndexForGlyph(at: glyphs.location))
                    anchorOffset = origin.y - layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil).minY
                }
            }

            isUpdating = true
            let wasSyncScrolling = isSyncScrolling
            isSyncScrolling = true
            defer { isUpdating = false; isSyncScrolling = wasSyncScrolling }
            textView.breakUndoCoalescing()
            textView.undoManager?.removeAllActions()
            textView.textStorage?.replaceCharacters(in: replaced, with: inserted)
            textView.selectedRanges = selections
            var restored = origin
            if let anchor, let layout, anchor < text.utf16.count {
                layout.ensureLayout(forCharacterRange: NSRange(location: anchor, length: 1))
                let glyph = layout.glyphIndexForCharacter(at: anchor)
                restored.y = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + anchorOffset
            }
            if let clip {
                clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: restored, size: clip.bounds.size)).origin)
                textView.enclosingScrollView?.reflectScrolledClipView(clip)
            }
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
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 32, height: 16)
        // Remove the default 5pt glyph-edge padding so the text's left edge
        // lines up with the preview's 32px body padding.
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = context.coordinator

        // Attach the highlighter as the storage delegate BEFORE assigning the
        // initial text, so the first character edit queues a full highlight.
        // Subsequent edits use the same deferred attribute-only transaction
        // with a paragraph-scoped editedRange.
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

        if context.coordinator.pendingExternalText != nil {
            context.coordinator.pendingExternalText = text
        }

        if textView.string != text && !context.coordinator.isUpdating {
            context.coordinator.replaceText(text, in: textView)
        }
    }
}
