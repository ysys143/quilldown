import AppKit

final class MarkdownHighlighter: NSObject, NSTextStorageDelegate {

    private enum Palette {
        static let base = dynamic(dark: .init(white: 0.87, alpha: 1), light: .init(white: 0.12, alpha: 1))
        static let heading = dynamic(
            dark: .init(red: 0.47, green: 0.73, blue: 0.93, alpha: 1),
            light: .init(red: 0.04, green: 0.36, blue: 0.71, alpha: 1)
        )
        static let bold = dynamic(
            dark: .init(red: 0.95, green: 0.77, blue: 0.37, alpha: 1),
            light: .init(red: 0.68, green: 0.42, blue: 0.00, alpha: 1)
        )
        static let italic = dynamic(
            dark: .init(red: 0.78, green: 0.85, blue: 0.60, alpha: 1),
            light: .init(red: 0.35, green: 0.55, blue: 0.12, alpha: 1)
        )
        static let link = dynamic(
            dark: .init(red: 0.35, green: 0.66, blue: 0.94, alpha: 1),
            light: .init(red: 0.00, green: 0.47, blue: 0.85, alpha: 1)
        )
        static let listMarker = dynamic(
            dark: .init(red: 0.96, green: 0.47, blue: 0.42, alpha: 1),
            light: .init(red: 0.85, green: 0.25, blue: 0.00, alpha: 1)
        )
        static let codeFg = dynamic(
            dark: .init(red: 0.93, green: 0.70, blue: 0.57, alpha: 1),
            light: .init(red: 0.55, green: 0.28, blue: 0.00, alpha: 1)
        )
        static let codeBg = dynamic(
            dark: .init(white: 1.0, alpha: 0.06),
            light: .init(white: 0.0, alpha: 0.04)
        )
        static let math = dynamic(
            dark: .init(red: 0.80, green: 0.70, blue: 0.96, alpha: 1),
            light: .init(red: 0.45, green: 0.26, blue: 0.63, alpha: 1)
        )
        static let muted: NSColor = .secondaryLabelColor

        private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
                    ? dark : light
            }
        }
    }

    private let baseSize: CGFloat = 13
    private lazy var baseFont = NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
    private lazy var boldFont = NSFont.monospacedSystemFont(ofSize: baseSize, weight: .bold)
    private lazy var italicFont: NSFont = {
        let desc = baseFont.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: desc, size: baseSize) ?? baseFont
    }()
    private lazy var headingFont = NSFont.monospacedSystemFont(ofSize: baseSize, weight: .bold)

    private let reHeading     = try! NSRegularExpression(pattern: #"^(#{1,6})(\s+).*$"#, options: .anchorsMatchLines)
    private let reBold        = try! NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*"#)
    private let reItalicStar  = try! NSRegularExpression(pattern: #"(?<![\*\w])\*([^*\n]+)\*(?![\*\w])"#)
    private let reItalicUnder = try! NSRegularExpression(pattern: #"(?<![_\w])_([^_\n]+)_(?![_\w])"#)
    private let reStrike      = try! NSRegularExpression(pattern: #"~~([^~\n]+)~~"#)
    private let reInlineCode  = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)
    private let reLink        = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^)\n]+)\)"#)
    private let reBlockquote  = try! NSRegularExpression(pattern: #"^>\s+.*$"#, options: .anchorsMatchLines)
    private let reListMarker  = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|\d+\.)(\s+)"#, options: .anchorsMatchLines)
    private let reMathInline  = try! NSRegularExpression(pattern: #"(?<!\$)\$(?!\$)[^$\n]+\$(?!\$)"#)
    private let reMathBlock   = try! NSRegularExpression(pattern: #"\$\$[\s\S]+?\$\$"#)
    private let reCodeFence   = try! NSRegularExpression(pattern: #"^```[^\n]*$"#, options: .anchorsMatchLines)
    private let reHorizontal  = try! NSRegularExpression(pattern: #"^(-{3,}|_{3,}|\*{3,})\s*$"#, options: .anchorsMatchLines)

    private var queuedRange: NSRange?
    private var queuedDelta = 0
    private var highlightQueued = false

    // Give character editing its own transaction. Changing a paragraph's fonts
    // inside the character-edit callback expands TextKit's character-edit range,
    // moves the caret, and (after attribute fixing) breaks Hangul fallback.
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        pendingTailGeneration += 1
        if let previous = queuedRange {
            let oldEnd = editedRange.location + max(0, editedRange.length - delta)
            func mapped(_ offset: Int) -> Int {
                if offset <= editedRange.location { return offset }
                if offset >= oldEnd { return offset + delta }
                return NSMaxRange(editedRange)
            }
            let start = min(textStorage.length, max(0, mapped(previous.location)))
            let end = min(textStorage.length, max(start, mapped(NSMaxRange(previous))))
            queuedRange = NSUnionRange(NSRange(location: start, length: end - start), editedRange)
        } else {
            queuedRange = editedRange
        }
        queuedDelta += delta
        guard !highlightQueued else { return }
        highlightQueued = true
        DispatchQueue.main.async { [weak self, weak textStorage] in
            guard let self, let textStorage, let range = self.queuedRange else { return }
            let delta = self.queuedDelta
            self.queuedRange = nil
            self.queuedDelta = 0
            self.highlightQueued = false
            PerfLog.measure(.editor, "highlight.delegate", note: "edited=\(range.length) doc=\(textStorage.length)") {
                self.highlight(textStorage: textStorage, editedRange: range, changeInLength: delta)
            }
        }
    }

    /// Threshold above which a range is considered "bulk" (initial load or
    /// large paste). Bulk changes get a viewport-first + deferred tail pass
    /// so the visible area paints immediately without freezing the main thread
    /// on the rest of a 100KB document.
    private let bulkThreshold = 10_000
    private var pendingTailGeneration: Int = 0

    /// One attribute batch produced by the background pattern scanner. Keeping
    /// the plan as plain value types lets us compute on a background queue
    /// (NSRegularExpression is thread-safe; NSTextStorage is not) and only
    /// apply on the main thread.
    private struct HighlightOp {
        let range: NSRange
        let attributes: [NSAttributedString.Key: Any]
    }

    private var previousLength = 0
    private var previousCodeblocks: [NSRange] = []
    private var previousMathBlocks: [NSRange] = []
    private var pendingRange: NSRange?

    /// Invalidate every old plan, including for same-length edits. Carry any
    /// unfinished tail forward so typing during initial load cannot leave it blank.
    func highlight(textStorage: NSTextStorage, editedRange: NSRange? = nil, changeInLength: Int? = nil) {
        pendingTailGeneration += 1
        let generation = pendingTailGeneration
        let ns = (textStorage.string as NSString).copy() as! NSString
        let full = NSRange(location: 0, length: ns.length)
        let codeblocks = computeCodeblockRanges(text: ns)
        let mathBlocks = reMathBlock.matches(in: ns as String, range: full).map(\.range)
        var target = full

        if let edited = editedRange {
            let delta = changeInLength ?? (ns.length - previousLength)
            let oldEdit = NSRange(location: edited.location, length: max(0, edited.length - delta))
            func mapped(_ range: NSRange) -> NSRange {
                func offset(_ position: Int) -> Int {
                    if position <= oldEdit.location { return position }
                    if position >= NSMaxRange(oldEdit) { return position + delta }
                    return NSMaxRange(edited)
                }
                let start = min(ns.length, max(0, offset(range.location)))
                let end = min(ns.length, max(start, offset(NSMaxRange(range))))
                return NSRange(location: start, length: end - start)
            }
            let location = min(ns.length, max(0, edited.location))
            target = ns.paragraphRange(for: NSRange(location: location, length: min(edited.length, ns.length - location)))
            // Old regions matter as much as new ones: deleting a fence or $$
            // delimiter can change syntax all the way to the end of the document.
            for (old, new) in [(previousCodeblocks, codeblocks), (previousMathBlocks, mathBlocks)] {
                let before = Set(old.map(mapped))
                let after = Set(new)
                for range in before.symmetricDifference(after) {
                    target = NSUnionRange(target, range)
                }
            }
            if let pendingRange { target = NSUnionRange(target, mapped(pendingRange)) }
            target = expandRange(target, in: ns, codeblocks: codeblocks + mathBlocks)
        }
        previousLength = ns.length
        previousCodeblocks = codeblocks
        previousMathBlocks = mathBlocks
        pendingRange = nil
        guard ns.length > 0 else { return }

        // Split only at paragraph boundaries so inline syntax cannot straddle
        // the initial and deferred passes. Multi-line regions are clipped below.
        let headEnd = min(NSMaxRange(target), NSMaxRange(ns.paragraphRange(for:
            NSRange(location: target.location, length: min(bulkThreshold, target.length)))))
        let head = NSRange(location: target.location, length: headEnd - target.location)
        let ops = computeOps(ns: ns, target: head, codeblocks: codeblocks, mathBlocks: mathBlocks)
        applyOps(textStorage: textStorage, ops: ops, clearRange: head)
        guard headEnd < NSMaxRange(target) else { return }

        let tail = NSRange(location: headEnd, length: NSMaxRange(target) - headEnd)
        pendingRange = tail
        // Initialize AppKit font objects on the main thread before scanning.
        _ = [baseFont, boldFont, italicFont, headingFont]
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak textStorage] in
            guard let self else { return }
            let token = PerfLog.begin(.editor, "highlight.tail.compute")
            let ops = self.computeOps(ns: ns, target: tail, codeblocks: codeblocks, mathBlocks: mathBlocks)
            PerfLog.end(token, "ops=\(ops.count) range=\(tail.length)")
            DispatchQueue.main.async { [weak self, weak textStorage] in
                guard let self, let textStorage,
                      generation == self.pendingTailGeneration else { return }
                self.pendingRange = nil
                PerfLog.measure(.editor, "highlight.tail.apply", note: "ops=\(ops.count)") {
                    self.applyOps(textStorage: textStorage, ops: ops, clearRange: tail)
                }
            }
        }
    }

    /// Runs every regex pattern over `target` and produces a plain value-type
    /// plan that can be handed back to the main thread for application. No
    /// NSTextStorage access — thread-safe.
    private func computeOps(ns: NSString, target: NSRange, codeblocks: [NSRange], mathBlocks: [NSRange]) -> [HighlightOp] {
        var ops: [HighlightOp] = []
        ops.reserveCapacity(128)
        ops.append(HighlightOp(range: target, attributes: [
            .font: baseFont,
            .foregroundColor: Palette.base,
        ]))
        applyToOps(reHeading, in: ns, range: target, excluding: codeblocks, ops: &ops) { m in
            [HighlightOp(range: m.range, attributes: [
                .font: headingFont,
                .foregroundColor: Palette.heading,
            ])]
        }
        applyToOps(reHorizontal, in: ns, range: target, excluding: codeblocks, ops: &ops) { m in
            [HighlightOp(range: m.range, attributes: [.foregroundColor: Palette.muted])]
        }
        applyToOps(reBold, in: ns, range: target, excluding: codeblocks, ops: &ops) { m in
            [HighlightOp(range: m.range, attributes: [
                .font: boldFont,
                .foregroundColor: Palette.bold,
            ])]
        }
        applyToOps(reItalicStar, in: ns, range: target, excluding: codeblocks, ops: &ops) { m in
            [HighlightOp(range: m.range, attributes: [
                .font: italicFont,
                .foregroundColor: Palette.italic,
            ])]
        }
        applyToOps(reItalicUnder, in: ns, range: target, excluding: codeblocks, ops: &ops) { m in
            [HighlightOp(range: m.range, attributes: [
                .font: italicFont,
                .foregroundColor: Palette.italic,
            ])]
        }
        applyToOps(reStrike, in: ns, range: target, excluding: codeblocks, ops: &ops) { m in
            [HighlightOp(range: m.range, attributes: [
                .foregroundColor: Palette.muted,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ])]
        }
        applyToOps(reLink, in: ns, range: target, excluding: codeblocks, ops: &ops) { m in
            [
                HighlightOp(range: m.range, attributes: [.foregroundColor: Palette.link]),
                HighlightOp(range: m.range(at: 2), attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]),
            ]
        }
        applyToOps(reBlockquote, in: ns, range: target, excluding: codeblocks, ops: &ops) { m in
            [HighlightOp(range: m.range, attributes: [
                .foregroundColor: Palette.muted,
                .font: italicFont,
            ])]
        }
        applyToOps(reListMarker, in: ns, range: target, excluding: codeblocks, ops: &ops) { m in
            [HighlightOp(range: m.range(at: 2), attributes: [
                .foregroundColor: Palette.listMarker,
                .font: boldFont,
            ])]
        }
        for block in mathBlocks where !codeblocks.contains(where: { NSIntersectionRange($0, block).length > 0 }) {
            let clipped = NSIntersectionRange(block, target)
            if clipped.length > 0 {
                ops.append(HighlightOp(range: clipped, attributes: [.foregroundColor: Palette.math]))
            }
        }
        applyToOps(reMathInline, in: ns, range: target, excluding: codeblocks, ops: &ops) { m in
            [HighlightOp(range: m.range, attributes: [.foregroundColor: Palette.math])]
        }
        applyToOps(reInlineCode, in: ns, range: target, excluding: codeblocks, ops: &ops) { m in
            [HighlightOp(range: m.range, attributes: [
                .foregroundColor: Palette.codeFg,
                .backgroundColor: Palette.codeBg,
            ])]
        }
        for cb in codeblocks where NSIntersectionRange(cb, target).length > 0 {
            ops.append(HighlightOp(range: NSIntersectionRange(cb, target), attributes: [
                .font: baseFont,
                .foregroundColor: Palette.codeFg,
                .backgroundColor: Palette.codeBg,
            ]))
        }
        return ops
    }

    private func applyToOps(
        _ re: NSRegularExpression,
        in text: NSString,
        range: NSRange,
        excluding: [NSRange],
        ops: inout [HighlightOp],
        handler: (NSTextCheckingResult) -> [HighlightOp]
    ) {
        re.enumerateMatches(in: text as String, options: [.withoutAnchoringBounds, .withTransparentBounds], range: range) { match, _, _ in
            guard let match = match else { return }
            for ex in excluding where NSIntersectionRange(ex, match.range).length > 0 {
                return
            }
            ops.append(contentsOf: handler(match))
        }
    }

    /// Applies a pre-computed plan produced by `computeOps`. Must run on the
    /// main thread since it mutates NSTextStorage.
    private func applyOps(textStorage: NSTextStorage, ops: [HighlightOp], clearRange: NSRange) {
        guard clearRange.length > 0 else { return }
        textStorage.beginEditing()
        defer { textStorage.endEditing() }
        textStorage.removeAttribute(.backgroundColor, range: clearRange)
        textStorage.removeAttribute(.strikethroughStyle, range: clearRange)
        textStorage.removeAttribute(.underlineStyle, range: clearRange)
        for op in ops {
            for (key, value) in op.attributes {
                textStorage.addAttribute(key, value: value, range: op.range)
            }
        }
    }

    /// Widens `edited` to paragraph boundaries; if the widened range overlaps
    /// a fenced code block, the whole block is included so fence styling stays
    /// consistent even when only the opening/closing line was touched.
    private func expandRange(_ edited: NSRange, in text: NSString, codeblocks: [NSRange]) -> NSRange {
        let safeLoc = max(0, min(edited.location, text.length))
        let safeLen = max(0, min(edited.length, text.length - safeLoc))
        var expanded = text.paragraphRange(for: NSRange(location: safeLoc, length: safeLen))
        for cb in codeblocks where NSIntersectionRange(cb, expanded).length > 0 || cb.contains(safeLoc) {
            let start = min(expanded.location, cb.location)
            let end = max(NSMaxRange(expanded), NSMaxRange(cb))
            expanded = NSRange(location: start, length: end - start)
        }
        return expanded
    }

    /// Pairs up ``` fences into closed ranges; an unclosed trailing fence spans
    /// to end of document so typing the opening fence immediately styles below.
    private func computeCodeblockRanges(text: NSString) -> [NSRange] {
        let full = NSRange(location: 0, length: text.length)
        let fences = reCodeFence.matches(in: text as String, range: full)
        var ranges: [NSRange] = []
        var i = 0
        while i + 1 < fences.count {
            let start = fences[i].range.location
            let end = NSMaxRange(fences[i + 1].range)
            ranges.append(NSRange(location: start, length: end - start))
            i += 2
        }
        if i < fences.count {
            let start = fences[i].range.location
            ranges.append(NSRange(location: start, length: text.length - start))
        }
        return ranges
    }

}
