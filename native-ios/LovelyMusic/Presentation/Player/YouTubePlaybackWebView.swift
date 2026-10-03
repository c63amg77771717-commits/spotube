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
                guard !Task.isCancelled else { return }
                await configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            }
            guard !Task.isCancelled else { return }
            if let url = components.url { webView.load(URLRequest(url: url)) }
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(authManager: authManager) }

    @MainActor
    final class Coordinator {
        var loadTask: Task<Void, Never>?
        private let authManager: YouTubeAuthManager
        private let initialSessionRevision: UInt

        init(authManager: YouTubeAuthManager) {
            self.authManager = authManager
            initialSessionRevision = authManager.sessionRevision
        }

        func persistBrowserSession(from store: WKHTTPCookieStore) async {
            // Explicit logout or a newer login takes precedence over this page.
            guard authManager.sessionRevision == initialSessionRevision else { return }
            let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
                store.getAllCookies { continuation.resume(returning: $0) }
            }
            guard authManager.sessionRevision == initialSessionRevision else { return }
            if authManager.storeAuthCookies(cookies) {
                PlaybackDiagnostics.shared.record(.init(phase: .webSessionUpdated, hasAuth: true))
            }
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
        let store = uiView.configuration.websiteDataStore.httpCookieStore
        Task { @MainActor in await coordinator.persistBrowserSession(from: store) }
        uiView.stopLoading()
        uiView.loadHTMLString("", baseURL: nil)
    }
}
