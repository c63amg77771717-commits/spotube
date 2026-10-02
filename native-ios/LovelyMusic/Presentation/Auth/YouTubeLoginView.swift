import SwiftUI
import WebKit

struct YouTubeLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DIContainer.self) private var container
    let authManager: YouTubeAuthManager
    let onLoginComplete: () -> Void

    var body: some View {
        NavigationStack {
            YouTubeLoginWebView(authManager: authManager) {
                Task {
                    await container.innerTubeAPI.setCookie(authManager.cookieHeaderString())
                    onLoginComplete()
                    dismiss()
                }
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CustomCloseButton()
                }
            }
        }
    }
}

struct YouTubeLoginWebView: UIViewRepresentable {
    let authManager: YouTubeAuthManager
    let onComplete: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        let loginURLString = "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26hl%3Den%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F&hl=en"
        if let url = URL(string: loginURLString) {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(authManager: authManager, onComplete: onComplete)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let authManager: YouTubeAuthManager
        let onComplete: () -> Void
        // Must have navigated through Google accounts page before completing login
        private var hasSeenGoogleAccountsPage = false
        private var didComplete = false

        init(authManager: YouTubeAuthManager, onComplete: @escaping () -> Void) {
            self.authManager = authManager
            self.onComplete = onComplete
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !didComplete, let host = webView.url?.host?.lowercased() else { return }

            // Track when we've visited Google accounts (so we know auth started)
            if host == "accounts.google.com" {
                hasSeenGoogleAccountsPage = true
                return
            }

            // Only complete if user went through Google accounts AND landed on YouTube
            guard hasSeenGoogleAccountsPage else { return }
            guard YouTubeAuthManager.isYouTubeDomain(host) else { return }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }

                let ytCookies = cookies.filter {
                    YouTubeAuthManager.isYouTubeDomain($0.domain)
                }
                guard YouTubeAuthManager.hasActiveAuthCookies(ytCookies) else {
                    // Key auth cookies not yet set — wait for final music.youtube.com navigation
                    return
                }

                guard self.authManager.storeAuthCookies(ytCookies) else { return }
                self.didComplete = true
                DispatchQueue.main.async { self.onComplete() }
            }
        }
    }
}
