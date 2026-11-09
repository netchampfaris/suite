import Foundation
import Observation

/// The signed-in person and the site they signed in to.
struct Account: Codable, Hashable {
    let site: URL
    let user: String
    let fullName: String
}

/// Owns sign-in state for the whole app.
///
/// The `sid` cookie lives in the shared cookie store. This type only remembers which
/// site and user it belongs to, so a relaunch can check the cookie is still good.
@MainActor
@Observable
final class AppSession {
    enum State: Equatable {
        case restoring
        case signedOut
        case signedIn(Account)
    }

    private(set) var state: State = .restoring
    private(set) var client: APIClient?

    private let store: UserDefaults
    private let makeClient: (URL) -> APIClient
    private static let accountKey = "account"

    init(store: UserDefaults = .standard, makeClient: @escaping (URL) -> APIClient = { APIClient(site: $0) }) {
        self.store = store
        self.makeClient = makeClient
    }

    /// The last site signed in to, written the way a person types it.
    var lastSite: String? {
        guard let site = storedAccount?.site.absoluteString else { return nil }
        let bare = site.hasPrefix("https://") ? String(site.dropFirst("https://".count)) : site
        return bare.hasSuffix("/") ? String(bare.dropLast()) : bare
    }

    func restore() async {
        guard let account = storedAccount else {
            state = .signedOut
            return
        }
        let client = makeClient(account.site)
        do {
            guard try await Self.loggedUser(client) == account.user else {
                state = .signedOut
                return
            }
        } catch let error as APIError where error.endsSession {
            state = .signedOut
            return
        } catch {
            // Offline, or the site is down. The cookie may still be good, so keep the
            // person signed in and let each screen show that it could not load.
        }
        finish(account, client: client)
    }

    func signIn(site input: String, email: String, password: String) async throws {
        guard let site = Self.siteURL(from: input) else {
            throw APIError(type: "InvalidSite", message: "Enter a site address such as suite.frappe.io.", status: 0)
        }
        let client = makeClient(site)
        let data = try await client.postForm("api/method/login", fields: ["usr": email, "pwd": password])
        let reply = try? JSONDecoder.api.decode(LoginReply.self, from: data)
        let user = try await Self.loggedUser(client)
        let account = Account(site: site, user: user, fullName: reply?.fullName ?? user)
        store.set(try JSONEncoder().encode(account), forKey: Self.accountKey)
        finish(account, client: client)
    }

    func signOut() async {
        if let client { _ = try? await client.get("api/method/logout") }
        if let site = client?.site, let cookies = HTTPCookieStorage.shared.cookies(for: site) {
            cookies.forEach(HTTPCookieStorage.shared.deleteCookie)
        }
        client = nil
        state = .signedOut
    }

    /// Accepts "suite.frappe.io", "https://suite.frappe.io/app" or "http://127.0.0.1:8002".
    nonisolated static func siteURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              let host = components.host, !host.isEmpty,
              ["http", "https"].contains(components.scheme?.lowercased())
        else { return nil }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private var storedAccount: Account? {
        store.data(forKey: Self.accountKey).flatMap { try? JSONDecoder().decode(Account.self, from: $0) }
    }

    private func finish(_ account: Account, client: APIClient) {
        self.client = client
        state = .signedIn(account)
    }

    /// Asks the site who the cookie belongs to. A Guest answer means it has expired.
    private static func loggedUser(_ client: APIClient) async throws -> String {
        let data = try await client.get("api/method/frappe.auth.get_logged_user")
        let user = try JSONDecoder.api.decode(MessageReply.self, from: data).message
        guard user != "Guest" else {
            throw APIError(type: "AuthenticationError", message: "Your session has ended. Sign in again.", status: 401)
        }
        return user
    }
}

private struct LoginReply: Decodable {
    let fullName: String?
}

private struct MessageReply: Decodable {
    let message: String
}
