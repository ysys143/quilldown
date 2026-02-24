import WebKit

class WebViewStore: ObservableObject {
    static let shared = WebViewStore()
    weak var activeWebView: WKWebView?
}
