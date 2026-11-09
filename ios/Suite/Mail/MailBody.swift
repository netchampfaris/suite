import SwiftUI
import WebKit

/// An HTML message, laid out by WebKit at its full height so the thread scrolls as one page.
///
/// The message's own scripts never run. Links open in the browser. Images load from the
/// site with the app's session, which is how the server serves inline images.
struct MailBody: View {
    let html: String
    let site: URL
    @State private var height: CGFloat = 1

    var body: some View {
        MailWebView(html: html, site: site, height: $height)
            .frame(height: height)
    }
}

private struct MailWebView: UIViewRepresentable {
    let html: String
    let site: URL
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.dataDetectorTypes = [.link, .phoneNumber, .address, .calendarEvent]
        // Reports the content's height whenever it changes, such as when an image arrives.
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
            new ResizeObserver(() => webkit.messageHandlers.height.postMessage(document.documentElement.scrollHeight))
              .observe(document.body);
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        configuration.userContentController.add(context.coordinator, name: "height")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.scrollView.isScrollEnabled = false
        view.isOpaque = false
        view.backgroundColor = .clear
        Task {
            for cookie in HTTPCookieStorage.shared.cookies(for: site) ?? [] {
                await view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            }
            view.loadHTMLString(Self.page(html), baseURL: site)
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "height")
    }

    /// Wraps the message so it fits the screen and uses the system font where it sets none.
    private static func page(_ html: String) -> String {
        """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        body { margin: 0; font: -apple-system-body; overflow-wrap: anywhere; }
        img, video, table { max-width: 100% !important; height: auto; }
        pre { white-space: pre-wrap; }
        blockquote { margin-left: 0; padding-left: 12px; border-left: 2px solid #8884; }
        </style></head><body>\(html)</body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var height: CGFloat

        init(height: Binding<CGFloat>) {
            _height = height
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let value = message.body as? Double, value > 0 { height = value }
        }

        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // The first load is the message itself. Anything after that is a tapped link.
            guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
            await UIApplication.shared.open(url)
            return .cancel
        }
    }
}
