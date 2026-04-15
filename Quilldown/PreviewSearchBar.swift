import SwiftUI

/// Floating find bar shown above the WKWebView preview. Behaves like Safari's
/// Cmd+F bar: typing searches incrementally, Enter advances, Shift+Enter goes
/// back, Esc closes. All navigation goes through `WebViewStore.findInPreview`.
struct PreviewSearchBar: View {
    @Binding var query: String
    @Binding var isVisible: Bool

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .frame(width: 200)
                .focused($isFocused)
                .onSubmit {
                    Task { await find(forward: true) }
                }

            Button {
                Task { await find(forward: false) }
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(query.isEmpty)
            .help("Previous match (Shift+Return)")

            Button {
                Task { await find(forward: true) }
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(query.isEmpty)
            .help("Next match (Return)")

            Divider().frame(height: 14)

            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
        .onAppear { isFocused = true }
        .onChange(of: query) {
            WebViewStore.shared.clearPreviewFind()
            guard !query.isEmpty else { return }
            Task { await find(forward: true) }
        }
        .onChange(of: isVisible) {
            if isVisible { isFocused = true }
        }
    }

    private func find(forward: Bool) async {
        await WebViewStore.shared.findInPreview(query, forward: forward)
    }

    private func close() {
        WebViewStore.shared.clearPreviewFind()
        query = ""
        isVisible = false
    }
}
