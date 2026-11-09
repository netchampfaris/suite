import SwiftUI

@main
struct SuiteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(delegate.notifications)
        }
    }
}

/// Shows sign-in or the app, depending on whether the site still knows us.
struct RootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        // A ZStack, not a Group: a Group passes `.task` to each case, so the session would be restored
        // again every time the screen changed, replacing the signed-in app's client under it.
        ZStack {
            switch session.state {
            case .restoring:
                ProgressView()
            case .signedOut:
                LoginView()
            case .signedIn(let account):
                if let client = session.client {
                    AppShell(account: account, api: client)
                        // A new account starts with fresh screens.
                        .id(account)
                }
            }
        }
        .task { await session.restore() }
    }
}
