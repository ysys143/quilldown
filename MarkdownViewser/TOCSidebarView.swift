import SwiftUI

struct TOCSidebarView: View {
    let items: [TOCItem]
    let onSelect: (TOCItem) -> Void

    var body: some View {
        List(items) { item in
            Button(action: { onSelect(item) }) {
                Text(item.title)
                    .font(fontForLevel(item.level))
                    .foregroundColor(.primary)
                    .lineLimit(2)
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat(item.level - 1) * 12)
        }
        .listStyle(.sidebar)
    }

    private func fontForLevel(_ level: Int) -> Font {
        switch level {
        case 1: return .headline
        case 2: return .subheadline.weight(.medium)
        default: return .subheadline
        }
    }
}
