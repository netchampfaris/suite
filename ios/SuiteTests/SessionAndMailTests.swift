import Foundation
import Testing
@testable import Suite

@Suite(.serialized)
@MainActor
struct SessionTests {
    private let account = Account(site: URL(string: "https://suite.example.com/")!, user: "maya@example.com", fullName: "Maya")

    /// A session store that already remembers Maya, as after an earlier sign-in.
    private func session() throws -> AppSession {
        let store = UserDefaults(suiteName: "SessionTests-\(UUID())")!
        store.set(try JSONEncoder().encode(account), forKey: "account")
        return AppSession(store: store) { StubServer.client(site: $0) }
    }

    @Test func staysSignedInWhenOffline() async throws {
        StubServer.handler = { _, _ in .offline }
        let session = try session()

        await session.restore()

        #expect(session.state == .signedIn(account))
    }

    @Test func signsOutWhenTheSiteSaysTheSessionEnded() async throws {
        StubServer.handler = { _, _ in .json(#"{"message":"Guest"}"#) }
        let session = try session()

        await session.restore()

        #expect(session.state == .signedOut)
    }
}

@Suite(.serialized)
struct MailSendTests {
    @Test func sendsTheRecipientListsTheServerRequires() async throws {
        var sent: [String: Any] = [:]
        StubServer.handler = { _, body in
            sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            return .json(#"{"message":{"name":"q1","error":null}}"#)
        }
        let server = MailServer(api: StubServer.client(), account: "acc1", fromEmail: "maya@example.com", categories: [])

        try await server.send(.init(account: "acc1", fromEmail: "maya@example.com", to: [.init(email: "lee@example.com")],
                                    subject: "Hi", htmlBody: "<p>Hi</p>"))

        #expect((sent["to"] as? [[String: String]]) == [["email": "lee@example.com"]])
        #expect((sent["cc"] as? [Any])?.isEmpty == true)
        #expect((sent["bcc"] as? [Any])?.isEmpty == true)
    }

    @Test func showsTheReasonTheServerGave() async throws {
        StubServer.handler = { _, _ in
            .json(#"{"exc_type":"ValidationError","_server_messages":"[\"{\\\"message\\\":\\\"Recipient is blocked\\\"}\"]"}"#, status: 417)
        }
        let server = MailServer(api: StubServer.client(), account: "acc1", fromEmail: "maya@example.com", categories: [])

        await #expect { try await server.send(.init(account: "acc1", fromEmail: "maya@example.com", to: [.init(email: "lee@example.com")],
                                                    subject: "Hi", htmlBody: "<p>Hi</p>")) } throws: {
            ($0 as? APIError)?.message == "Recipient is blocked"
        }
    }
}
