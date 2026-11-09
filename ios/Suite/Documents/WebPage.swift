import SwiftUI
import WebKit

/// A document or meeting to open in the web app.
struct WebRoute: Hashable, Identifiable {
    let title: String
    let path: String

    var id: String { path }

    static func document(_ node: DriveNode) -> WebRoute {
        WebRoute(title: node.title, path: "d/\(node.name)")
    }

    static func meeting(_ code: String, title: String = "Meeting") -> WebRoute {
        WebRoute(title: title, path: "meet/\(code)")
    }
}

/// Shows a page of the web app, signed in with the app's own session.
///
/// The editors for documents, spreadsheets, presentations, and drawings, and the
/// meeting room, are large web apps. Until there are native ones, they open here.
struct WebPageScreen: View {
    let route: WebRoute
    let api: APIClient

    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            WebPage(url: api.url(route.path), isLoading: $isLoading)
                .ignoresSafeArea(edges: .bottom)
                .overlay { if isLoading { ProgressView() } }
                .navigationTitle(route.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: api.url(route.path))
                    }
                }
        }
    }
}

private struct WebPage: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(isLoading: $isLoading) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Meetings play audio and video inline instead of in the fullscreen player.
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(Self.embedding)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isInspectable = true
        Task { @MainActor in
            await Self.shareCookies(for: url, with: configuration.websiteDataStore.httpCookieStore)
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    /// Strips the web app's own navigation, which the native app already gives.
    ///
    /// Telling the page it runs as an installed app turns off its install banner,
    /// and the CSS hides its phone bottom bar. This leans on the web app's markup;
    /// an embedded mode in the web app would be the lasting fix.
    private static let embedding = WKUserScript(
        source: """
        Object.defineProperty(navigator, 'standalone', { get: () => true });
        document.addEventListener('DOMContentLoaded', () => {
          const style = document.createElement('style');
          style.textContent = 'nav.grid-flow-col.border-t { display: none !important; }';
          document.head.appendChild(style);
        });
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    /// Copies the site's cookies, `sid` among them, from the app's store to WebKit's.
    @MainActor
    private static func shareCookies(for url: URL, with store: WKHTTPCookieStore) async {
        for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] {
            await store.setCookie(cookie)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool

        init(isLoading: Binding<Bool>) {
            _isLoading = isLoading
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            isLoading = false
        }
    }
}
