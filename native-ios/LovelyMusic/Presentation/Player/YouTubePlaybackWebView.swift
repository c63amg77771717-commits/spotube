import SwiftUI
import WebKit

/// A visible YouTube watch page. YouTube owns playback and any required verification.
struct YouTubePlaybackWebView: UIViewRepresentable {
    let videoID: String
    let authManager: YouTubeAuthManager

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        var components = URLComponents(string: "https://www.youtube.com/watch")!
        components.queryItems = [
            URLQueryItem(name: "v", value: videoID),
            URLQueryItem(name: "hl", value: "zh-TW"),
        ]
        let cookies = authManager.getAuthCookies()
        context.coordinator.loadTask = Task { @MainActor in
            for cookie in cookies {
                await configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            }
            guard !Task.isCancelled else { return }
            if let url = components.url { webView.load(URLRequest(url: url)) }
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loadTask: Task<Void, Never>?
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
        uiView.stopLoading()
        uiView.loadHTMLString("", baseURL: nil)
    }
}
