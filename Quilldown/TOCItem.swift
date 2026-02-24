import Foundation

struct TOCItem: Identifiable, Hashable {
    let id: String
    let level: Int
    let title: String
    let anchor: String
}

func parseTableOfContents(from markdown: String) -> [TOCItem] {
    var items: [TOCItem] = []
    var usedAnchors: [String: Int] = [:]
    let lines = markdown.components(separatedBy: .newlines)
    var inCodeBlock = false

    for line in lines {
        if line.hasPrefix("```") {
            inCodeBlock.toggle()
            continue
        }
        if inCodeBlock { continue }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { continue }

        var level = 0
        for char in trimmed {
            if char == "#" { level += 1 } else { break }
        }
        guard level >= 1 && level <= 6 else { continue }

        let title = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { continue }

        var anchor = title
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }

        if let count = usedAnchors[anchor] {
            usedAnchors[anchor] = count + 1
            anchor = "\(anchor)-\(count + 1)"
        } else {
            usedAnchors[anchor] = 1
        }

        items.append(TOCItem(id: "\(items.count)-\(anchor)", level: level, title: title, anchor: anchor))
    }
    return items
}
