import SwiftUI
import AppKit

/// Toolbar search field with native macOS styling (same look as Notes.app).
/// Wraps `NSSearchField` so we get the rounded bezel, built-in magnifying
/// glass, clear-X button, and system focus ring for free.
/// Enter -> next match, Shift+Enter -> previous, Esc -> close.
struct PreviewSearchBar: View {
    @Binding var query: String
    @Binding var isVisible: Bool

    var body: some View {
        NativeSearchField(
            text: $query,
            onChange: { _ in
                WebViewStore.shared.clearPreviewFind()
                guard !query.isEmpty else { return }
                Task { await WebViewStore.shared.findInPreview(query, forward: true) }
            },
            onSubmit: { shift in
                Task { await WebViewStore.shared.findInPreview(query, forward: !shift) }
            },
            onCancel: close
        )
        .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
    }

    private func close() {
        WebViewStore.shared.clearPreviewFind()
        query = ""
        isVisible = false
    }
}

struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var onChange: (String) -> Void = { _ in }
    var onSubmit: (_ shiftHeld: Bool) -> Void = { _ in }
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search"
        field.delegate = context.coordinator
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchAction(_:))
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        init(_ parent: NativeSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
            parent.onChange(field.stringValue)
        }

        @objc func searchAction(_ sender: NSSearchField) {
            let shift = NSEvent.modifierFlags.contains(.shift)
            parent.onSubmit(shift)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}
