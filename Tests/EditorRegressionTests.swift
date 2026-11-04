import XCTest
import AppKit
import CoreText
import SwiftUI
@testable import Quilldown

final class EditorRegressionTests: XCTestCase {
    private func pump(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func save(_ document: MarkdownDocument, to url: URL, operation: NSDocument.SaveOperationType) {
        var completed = false
        document.save(to: url, ofType: MarkdownDocument.markdownType, for: operation) { error in
            XCTAssertNil(error)
            completed = true
        }
        let timeout = Date().addingTimeInterval(5)
        while !completed && Date() < timeout { pump(0.02) }
        XCTAssertTrue(completed)
    }

    private func assertMatchesFull(_ storage: NSTextStorage, file: StaticString = #filePath, line: UInt = #line) {
        let oracle = NSTextStorage(string: storage.string)
        let highlighter = MarkdownHighlighter()
        highlighter.highlight(textStorage: oracle)
        pump()
        let keys: [NSAttributedString.Key] = [.font, .foregroundColor, .backgroundColor, .strikethroughStyle, .underlineStyle]
        var mismatches = 0
        for index in 0..<storage.length {
            let actual = storage.attributes(at: index, effectiveRange: nil).filter { keys.contains($0.key) }
            let expected = oracle.attributes(at: index, effectiveRange: nil).filter { keys.contains($0.key) }
            if !NSDictionary(dictionary: actual).isEqual(to: expected) { mismatches += 1 }
        }
        XCTAssertEqual(mismatches, 0, "incremental/full attribute differences", file: file, line: line)
    }

    func testFixtureEditsMatchFullHighlight() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/test_full.md")
        let source = try String(contentsOf: url, encoding: .utf8)
        let storage = NSTextStorage(string: source)
        let highlighter = MarkdownHighlighter()
        highlighter.highlight(textStorage: storage)
        storage.delegate = highlighter
        pump()
        let fence = (storage.string as NSString).range(of: "```swift")
        XCTAssertNotEqual(fence.location, NSNotFound)
        storage.replaceCharacters(in: NSRange(location: fence.location, length: 1), with: "")
        assertMatchesFull(storage)
        storage.replaceCharacters(in: NSRange(location: fence.location, length: 0), with: "`")
        assertMatchesFull(storage)
        let bold = (storage.string as NSString).range(of: "**굵게")
        storage.replaceCharacters(in: NSRange(location: bold.location, length: 1), with: "")
        assertMatchesFull(storage)
        let tail = (storage.string as NSString).range(of: "**텍스트", range: NSRange(location: 10_000, length: storage.length - 10_000))
        XCTAssertNotEqual(tail.location, NSNotFound)
        storage.replaceCharacters(in: NSRange(location: tail.location, length: 1), with: "")
        assertMatchesFull(storage)
        storage.replaceCharacters(in: NSRange(location: 1000, length: 0), with: "x")
        assertMatchesFull(storage)
        XCTAssertEqual(storage.string.utf16.count, source.utf16.count - 1)
    }

    func testPendingTailSurvivesRapidAndSameLengthEdits() {
        let storage = NSTextStorage(string: String(repeating: "plain **bold** 한국어\n", count: 2000))
        let highlighter = MarkdownHighlighter()
        highlighter.highlight(textStorage: storage)
        storage.delegate = highlighter
        storage.replaceCharacters(in: NSRange(location: 20_010, length: 2), with: "~~")
        storage.replaceCharacters(in: NSRange(location: 20, length: 0), with: "새 글자𠀀\n")
        storage.replaceCharacters(in: NSRange(location: storage.length - 30, length: 5), with: "")
        assertMatchesFull(storage)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "")
        pump()
        XCTAssertEqual(storage.length, 0)
    }

    func testBulkBoundaryAndMultilineMathEdits() {
        let source = String(repeating: "plain\n", count: 1665) + "**crossing the ten thousand boundary**\n$$\na + b\n$$\nend\n$$\nc\n$$\n"
        let storage = NSTextStorage(string: source)
        let highlighter = MarkdownHighlighter()
        highlighter.highlight(textStorage: storage)
        storage.delegate = highlighter
        assertMatchesFull(storage)
        let delimiter = (storage.string as NSString).range(of: "$$")
        storage.replaceCharacters(in: NSRange(location: delimiter.location, length: 1), with: "")
        assertMatchesFull(storage)
        storage.replaceCharacters(in: NSRange(location: delimiter.location, length: 0), with: "$")
        assertMatchesFull(storage)
    }

    func testHangulFontsHaveGlyphsAfterEditingExistingParagraph() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let highlighter = MarkdownHighlighter()
        textView.isRichText = true
        textView.textStorage!.delegate = highlighter
        textView.string = "# 개선 조사 종합\n\n사용자 제약: **30B급 모델의 로컬 실행은 추천에서 제외한다.** Nemotron 30B의 공개 구현·양자화·MLX 지원은 조사 기록으로 남긴다.\n"
        pump()
        textView.layoutManager!.ensureLayout(for: textView.textContainer!)
        let edit = (textView.string as NSString).range(of: "30B")
        textView.setSelectedRange(NSRange(location: edit.location + 3, length: 0))
        textView.insertText("x", replacementRange: textView.selectedRange())
        pump()
        XCTAssertEqual(textView.selectedRange(), NSRange(location: edit.location + 4, length: 0))
        textView.layoutManager!.ensureLayout(for: textView.textContainer!)
        let ns = textView.string as NSString
        var missing = 0
        for index in 0..<ns.length {
            var character = ns.character(at: index)
            guard (0xAC00...0xD7A3).contains(character) else { continue }
            let font = textView.textStorage!.attribute(.font, at: index, effectiveRange: nil) as! NSFont
            var glyph: CGGlyph = 0
            if !CTFontGetGlyphsForCharacters(font as CTFont, &character, &glyph, 1) { missing += 1 }
        }
        XCTAssertEqual(missing, 0, "all Hangul characters must have drawable fallback glyphs")
        XCTAssertEqual(textView.string, "# 개선 조사 종합\n\n사용자 제약: **30Bx급 모델의 로컬 실행은 추천에서 제외한다.** Nemotron 30B의 공개 구현·양자화·MLX 지원은 조사 기록으로 남긴다.\n")
    }

    func testExternalReplacementPreservesSelectionAndViewport() {
        let original = (0..<300).map { "line \($0) 한국어𠀀 **bold**\n" }.joined()
        let model = MarkdownDocument()
        model.text = original
        let editor = MarkdownEditorView(text: Binding(get: { model.text }, set: { model.text = $0 }))
        let coordinator = MarkdownEditorView.Coordinator(parent: editor)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        textView.isVerticallyResizable = true
        textView.textContainer!.widthTracksTextView = true
        scroll.documentView = textView
        textView.delegate = coordinator
        textView.textStorage!.delegate = coordinator.highlighter
        textView.string = original
        pump()
        textView.layoutManager!.ensureLayout(for: textView.textContainer!)
        let selection = (original as NSString).range(of: "line 120")
        textView.setSelectedRange(selection)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1000))
        let before = scroll.contentView.bounds.origin.y
        let changed = original.replacingOccurrences(of: "line 1 ", with: "line 1 changed ")
        coordinator.replaceText(changed, in: textView)
        XCTAssertEqual(textView.string, changed)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: selection.location + 8, length: selection.length))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, before, accuracy: 1)
        coordinator.replaceText("短い𠀀", in: textView)
        XCTAssertLessThanOrEqual(NSMaxRange(textView.selectedRange()), textView.string.utf16.count)
        coordinator.replaceText("", in: textView)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
        model.updateChangeCount(.changeCleared)
        model.close()
    }

    func testDocumentReloadsInPlaceAtomicAndRecreatedFilesSilently() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quilldown-tests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("document.md")
        try Data("# Original\n한글𠀀\n".utf8).write(to: url)
        let doc = try MarkdownDocument(contentsOf: url, ofType: MarkdownDocument.markdownType)
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        doc.text += "local unsaved\n"
        doc.updateChangeCount(.changeDone)
        XCTAssertTrue(doc.isDocumentEdited)
        try Data("# External\n바뀐 원본𠀀\n".utf8).write(to: url)
        pump(0.5)
        XCTAssertEqual(doc.text, "# External\n바뀐 원본𠀀\n")
        XCTAssertFalse(doc.isDocumentEdited)
        try Data("# Atomic\n".utf8).write(to: url, options: .atomic)
        pump(0.5)
        XCTAssertEqual(doc.text, "# Atomic\n")
        try FileManager.default.removeItem(at: url)
        pump(0.3)
        try Data("# Recreated\n".utf8).write(to: url)
        pump(0.5)
        XCTAssertEqual(doc.text, "# Recreated\n")
        try Data([0xEF, 0xBB, 0xBF] + Array("# BOM\n한글\n".utf8)).write(to: url, options: .atomic)
        doc.presentedItemDidChange()
        pump(0.5)
        XCTAssertEqual(doc.text, "# BOM\n한글\n")
        XCTAssertEqual(try Data(contentsOf: url), Data([0xEF, 0xBB, 0xBF] + Array("# BOM\n한글\n".utf8)))
        XCTAssertFalse(doc.isDocumentEdited)
    }

    func testOwnSaveDoesNotDiscardUndoAndSaveAsWatchesNewPath() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quilldown-save-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("first.md")
        try Data("initial".utf8).write(to: url)
        let doc = try MarkdownDocument(contentsOf: url, ofType: MarkdownDocument.markdownType)
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        doc.text = "saved edit"
        doc.undoManager!.registerUndo(withTarget: doc) { $0.text = "initial" }
        save(doc, to: url, operation: .saveOperation)
        doc.text = "typed immediately after saving"
        doc.updateChangeCount(.changeDone)
        pump(0.5)
        XCTAssertEqual(doc.text, "typed immediately after saving")
        XCTAssertTrue(doc.undoManager!.canUndo)
        XCTAssertTrue(doc.isDocumentEdited)
        let newURL = folder.appendingPathComponent("second.md")
        save(doc, to: newURL, operation: .saveAsOperation)
        XCTAssertEqual(doc.fileURL, newURL)
        try Data("new path edit".utf8).write(to: newURL, options: .atomic)
        pump(0.5)
        XCTAssertEqual(doc.text, "new path edit")
        try Data("old path edit".utf8).write(to: url)
        pump(0.4)
        XCTAssertEqual(doc.text, "new path edit")
    }

    func testSaveImmediatelyAfterExternalWriteAcceptsDiskWithoutPrompt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quilldown-race-\(UUID()).md")
        try Data("initial".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try MarkdownDocument(contentsOf: url, ofType: MarkdownDocument.markdownType)
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        doc.text = "local unsaved"
        doc.updateChangeCount(.changeDone)
        try Data("external wins".utf8).write(to: url, options: .atomic)
        save(doc, to: url, operation: .saveOperation)
        XCTAssertEqual(doc.text, "external wins")
        XCTAssertEqual(try Data(contentsOf: url), Data("external wins".utf8))
        XCTAssertFalse(doc.isDocumentEdited)
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        return view.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }

    func testNativeWindowToolbarAndDocumentRegistration() throws {
        XCTAssertTrue(NSDocumentController.shared.documentClass(forType: MarkdownDocument.markdownType) == MarkdownDocument.self)
        let document = try NSDocumentController.shared.makeUntitledDocument(ofType: MarkdownDocument.markdownType) as! MarkdownDocument
        defer { document.updateChangeCount(.changeCleared); document.close() }
        document.makeWindowControllers()
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        document.showWindows()
        pump(0.5)
        let toolbar = try XCTUnwrap(window.toolbar)
        XCTAssertEqual(toolbar.items.filter { $0.view != nil }.count, 3)
        XCTAssertEqual(toolbar.centeredItemIdentifiers.map(\.rawValue), ["viewMode"])
        for item in toolbar.items where item.view != nil {
            XCTAssertGreaterThan(item.view!.frame.width, 0)
            XCTAssertGreaterThan(item.view!.frame.height, 0)
        }
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18)!
        XCTAssertTrue(window.performKeyEquivalent(with: key))
        pump()
        XCTAssertNotNil(textView(in: window.contentView!))

    }

    func testNativeEditingUndoRestoresCleanDocument() throws {
        let document = MarkdownDocument()
        document.text = "initial 한국어\n"
        let host = NSHostingController(rootView: MarkdownEditorView(text: Binding(
            get: { document.text }, set: { document.text = $0 })))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 900, height: 600))
        document.addWindowController(NSWindowController(window: window))
        defer { document.updateChangeCount(.changeCleared); document.close() }
        window.makeKeyAndOrderFront(nil)
        pump()
        document.updateChangeCount(.changeCleared)
        let editor = try XCTUnwrap(textView(in: host.view))
        window.makeFirstResponder(editor)
        editor.insertText("x", replacementRange: NSRange(location: 3, length: 0))
        editor.breakUndoCoalescing()
        // XCTest runs this method inside one event. End its undo group as
        // AppKit does when a real keyboard event returns to the event loop.
        while document.undoManager!.groupingLevel > 0 { document.undoManager!.endUndoGrouping() }
        pump()
        XCTAssertTrue(document.isDocumentEdited)
        XCTAssertTrue(document.undoManager!.canUndo)
        document.undoManager!.undo()
        pump()
        XCTAssertEqual(document.text, "initial 한국어\n")
        XCTAssertFalse(document.isDocumentEdited)
    }

    func testOpenedFileUpdatesLiveEditorWithoutSheetOrTextMutation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quilldown-live-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("live.md")
        let source = "# 외부 변경 검사\n\n" + (0..<150).map { "line \($0) 한국어 **굵게**\n" }.joined()
        try Data(source.utf8).write(to: url)
        DocumentAppDelegate().application(NSApp, open: [url])
        pump(0.5)
        let document = try XCTUnwrap(NSDocumentController.shared.document(for: url) as? MarkdownDocument)
        defer { document.updateChangeCount(.changeCleared); document.close() }
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18)!
        XCTAssertTrue(window.performKeyEquivalent(with: key))
        pump()
        let editor = try XCTUnwrap(textView(in: window.contentView!))
        let selection = (source as NSString).range(of: "line 100")
        editor.setSelectedRange(selection)
        editor.enclosingScrollView!.contentView.scroll(to: NSPoint(x: 0, y: 700))
        let top = editor.enclosingScrollView!.contentView.bounds.origin.y
        let changed = source.replacingOccurrences(of: "line 1 ", with: "line 1 changed ")
        try Data(changed.utf8).write(to: url, options: .atomic)
        pump(0.6)
        XCTAssertEqual(document.text, changed)
        XCTAssertEqual(editor.string, changed)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: selection.location + 8, length: selection.length))
        XCTAssertEqual(editor.enclosingScrollView!.contentView.bounds.origin.y, top, accuracy: 1)
        XCTAssertNil(window.attachedSheet)
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertEqual(try Data(contentsOf: url), Data(changed.utf8))
        // Rebuilding the editor must not insert smart spaces or change text.
        let preview = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "3", charactersIgnoringModifiers: "3", isARepeat: false, keyCode: 20)!
        XCTAssertTrue(window.performKeyEquivalent(with: preview))
        pump()
        XCTAssertTrue(window.performKeyEquivalent(with: key))
        pump()
        XCTAssertEqual(textView(in: window.contentView!)?.string, changed)
        XCTAssertEqual(try Data(contentsOf: url), Data(changed.utf8))
    }

    func testExternalChangeDuringIMECompositionUsesDiskTextAfterCommit() {
        let model = MarkdownDocument()
        model.text = "before 한국어"
        let coordinator = MarkdownEditorView.Coordinator(parent: MarkdownEditorView(
            text: Binding(get: { model.text }, set: { model.text = $0 })))
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        editor.delegate = coordinator
        editor.textStorage!.delegate = coordinator.highlighter
        editor.string = model.text
        editor.setMarkedText("가", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        model.text = "external 원본"
        coordinator.replaceText(model.text, in: editor)
        XCTAssertTrue(editor.hasMarkedText())
        editor.insertText("각", replacementRange: editor.markedRange())
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "external 원본")
        XCTAssertEqual(model.text, "external 원본")
        model.updateChangeCount(.changeCleared)
        model.close()
    }
}
