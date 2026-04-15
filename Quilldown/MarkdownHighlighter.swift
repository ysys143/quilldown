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
        highlight(textStorage: textStorage)
    }

    /// Re-highlights the entire document. Triggered on every text change.
    func highlight(textStorage: NSTextStorage) {
        let ns = textStorage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0 else { return }

        // 1) Reset base attributes across the whole document
        textStorage.removeAttribute(.backgroundColor, range: full)
        textStorage.removeAttribute(.strikethroughStyle, range: full)
        textStorage.removeAttribute(.underlineStyle, range: full)
        textStorage.addAttribute(.font, value: baseFont, range: full)
        textStorage.addAttribute(.foregroundColor, value: Palette.base, range: full)

        // 2) Compute codeblock regions so inline patterns don't apply inside them
        let codeblocks = computeCodeblockRanges(text: ns)

        // 3) Inline / line-level patterns (outside codeblocks)
        apply(reHeading, in: ns, excluding: codeblocks) { m in
            textStorage.addAttribute(.font, value: headingFont, range: m.range)
            textStorage.addAttribute(.foregroundColor, value: Palette.heading, range: m.range)
        }
        apply(reHorizontal, in: ns, excluding: codeblocks) { m in
            textStorage.addAttribute(.foregroundColor, value: Palette.muted, range: m.range)
        }
        apply(reBold, in: ns, excluding: codeblocks) { m in
            textStorage.addAttribute(.font, value: boldFont, range: m.range)
            textStorage.addAttribute(.foregroundColor, value: Palette.bold, range: m.range)
        }
        apply(reItalicStar, in: ns, excluding: codeblocks) { m in
            textStorage.addAttribute(.font, value: italicFont, range: m.range)
            textStorage.addAttribute(.foregroundColor, value: Palette.italic, range: m.range)
        }
        apply(reItalicUnder, in: ns, excluding: codeblocks) { m in
            textStorage.addAttribute(.font, value: italicFont, range: m.range)
            textStorage.addAttribute(.foregroundColor, value: Palette.italic, range: m.range)
        }
        apply(reStrike, in: ns, excluding: codeblocks) { m in
            textStorage.addAttribute(.foregroundColor, value: Palette.muted, range: m.range)
            textStorage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range)
        }
        apply(reLink, in: ns, excluding: codeblocks) { m in
            textStorage.addAttribute(.foregroundColor, value: Palette.link, range: m.range)
            textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 2))
        }
        apply(reBlockquote, in: ns, excluding: codeblocks) { m in
            textStorage.addAttribute(.foregroundColor, value: Palette.muted, range: m.range)
            textStorage.addAttribute(.font, value: italicFont, range: m.range)
        }
        apply(reListMarker, in: ns, excluding: codeblocks) { m in
            textStorage.addAttribute(.foregroundColor, value: Palette.listMarker, range: m.range(at: 2))
            textStorage.addAttribute(.font, value: boldFont, range: m.range(at: 2))
        }
        apply(reMathBlock, in: ns, excluding: codeblocks) { m in
            textStorage.addAttribute(.foregroundColor, value: Palette.math, range: m.range)
        }
        apply(reMathInline, in: ns, excluding: codeblocks) { m in
            textStorage.addAttribute(.foregroundColor, value: Palette.math, range: m.range)
        }
        apply(reInlineCode, in: ns, excluding: codeblocks) { m in
            textStorage.addAttribute(.foregroundColor, value: Palette.codeFg, range: m.range)
            textStorage.addAttribute(.backgroundColor, value: Palette.codeBg, range: m.range)
        }

        // 4) Codeblock regions last — their styling wins over everything inside
        for range in codeblocks {
            textStorage.addAttribute(.font, value: baseFont, range: range)
            textStorage.addAttribute(.foregroundColor, value: Palette.codeFg, range: range)
            textStorage.addAttribute(.backgroundColor, value: Palette.codeBg, range: range)
        }
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
        excluding: [NSRange],
        handler: (NSTextCheckingResult) -> Void
    ) {
        let range = NSRange(location: 0, length: text.length)
        re.enumerateMatches(in: text as String, range: range) { match, _, _ in
            guard let match = match else { return }
            for ex in excluding where NSIntersectionRange(ex, match.range).length > 0 {
                return
            }
            handler(match)
        }
    }
}
