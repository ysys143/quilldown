import Foundation

enum ViewMode: String, CaseIterable {
    case editor = "Editor"
    case preview = "Preview"
    case split = "Split"

    var icon: String {
        switch self {
        case .editor: return "doc.plaintext"
        case .preview: return "eye"
        case .split: return "rectangle.split.2x1"
        }
    }
}
