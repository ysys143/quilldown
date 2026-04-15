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

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        PerfLog.measure(.editor, "highlight.delegate", note: "edited=\(editedRange.length) doc=\(textStorage.length)") {
            highlight(textStorage: textStorage, editedRange: editedRange)
        }
    }

    /// Applies syntax highlighting. When `editedRange` is non-nil the scan
    /// is limited to the surrounding paragraphs (extended across fenced code
    /// blocks), so typing in a 100KB document stays O(paragraph) instead of
    /// O(full-document).
    func highlight(textStorage: NSTextStorage, editedRange: NSRange? = nil) {
        let ns = textStorage.string as NSString
        let fullLen = ns.length
        guard fullLen > 0 else { return }

        // Compute fences once — needed both to decide which inline patterns
        // apply and to widen the target range if the edit touches a fence.
        let codeblocks = computeCodeblockRanges(text: ns)

        let target: NSRange
        if let edited = editedRange {
            target = expandRange(edited, in: ns, codeblocks: codeblocks)
        } else {
            target = NSRange(location: 0, length: fullLen)
        }
        guard target.length > 0 else { return }

        textStorage.beginEditing()
        defer { textStorage.endEditing() }

        // 1) Reset base attributes within target only
        textStorage.removeAttribute(.backgroundColor, range: target)
        textStorage.removeAttribute(.strikethroughStyle, range: target)
        textStorage.removeAttribute(.underlineStyle, range: target)
        textStorage.addAttribute(.font, value: baseFont, range: target)
        textStorage.addAttribute(.foregroundColor, value: Palette.base, range: target)

        // 2) Inline / line-level patterns (outside codeblocks)
        apply(reHeading, in: ns, range: target, excluding: codeblocks) { m in
            textStorage.addAttribute(.font, value: headingFont, range: m.range)
            textStorage.addAttribute(.foregroundColor, value: Palette.heading, range: m.range)
        }
        apply(reHorizontal, in: ns, range: target, excluding: codeblocks) { m in
            textStorage.addAttribute(.foregroundColor, value: Palette.muted, range: m.range)
        }
        apply(reBold, in: ns, range: target, excluding: codeblocks) { m in
            textStorage.addAttribute(.font, value: boldFont, range: m.range)
            textStorage.addAttribute(.foregroundColor, value: Palette.bold, range: m.range)
        }
        apply(reItalicStar, in: ns, range: target, excluding: codeblocks) { m in
            textStorage.addAttribute(.font, value: italicFont, range: m.range)
            textStorage.addAttribute(.foregroundColor, value: Palette.italic, range: m.range)
        }
        apply(reItalicUnder, in: ns, range: target, excluding: codeblocks) { m in
            textStorage.addAttribute(.font, value: italicFont, range: m.range)
            textStorage.addAttribute(.foregroundColor, value: Palette.italic, range: m.range)
        }
        apply(reStrike, in: ns, range: target, excluding: codeblocks) { m in
            textStorage.addAttribute(.foregroundColor, value: Palette.muted, range: m.range)
            textStorage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range)
        }
        apply(reLink, in: ns, range: target, excluding: codeblocks) { m in
            textStorage.addAttribute(.foregroundColor, value: Palette.link, range: m.range)
            textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 2))
        }
        apply(reBlockquote, in: ns, range: target, excluding: codeblocks) { m in
            textStorage.addAttribute(.foregroundColor, value: Palette.muted, range: m.range)
            textStorage.addAttribute(.font, value: italicFont, range: m.range)
        }
        apply(reListMarker, in: ns, range: target, excluding: codeblocks) { m in
            textStorage.addAttribute(.foregroundColor, value: Palette.listMarker, range: m.range(at: 2))
            textStorage.addAttribute(.font, value: boldFont, range: m.range(at: 2))
        }
        apply(reMathBlock, in: ns, range: target, excluding: codeblocks) { m in
            textStorage.addAttribute(.foregroundColor, value: Palette.math, range: m.range)
        }
        apply(reMathInline, in: ns, range: target, excluding: codeblocks) { m in
            textStorage.addAttribute(.foregroundColor, value: Palette.math, range: m.range)
        }
        apply(reInlineCode, in: ns, range: target, excluding: codeblocks) { m in
            textStorage.addAttribute(.foregroundColor, value: Palette.codeFg, range: m.range)
            textStorage.addAttribute(.backgroundColor, value: Palette.codeBg, range: m.range)
        }

        // 3) Codeblock regions — only those intersecting our target
        for cb in codeblocks where NSIntersectionRange(cb, target).length > 0 {
            textStorage.addAttribute(.font, value: baseFont, range: cb)
            textStorage.addAttribute(.foregroundColor, value: Palette.codeFg, range: cb)
            textStorage.addAttribute(.backgroundColor, value: Palette.codeBg, range: cb)
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

    private func apply(
        _ re: NSRegularExpression,
        in text: NSString,
        range: NSRange,
        excluding: [NSRange],
        handler: (NSTextCheckingResult) -> Void
    ) {
        re.enumerateMatches(in: text as String, range: range) { match, _, _ in
            guard let match = match else { return }
            for ex in excluding where NSIntersectionRange(ex, match.range).length > 0 {
                return
            }
            handler(match)
        }
    }
}
