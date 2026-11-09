import Foundation
import Testing
@testable import Suite

/// Replies, forwards, and drafts, as Maya on a site with a mail server.
@Suite(.serialized)
@MainActor
struct MailComposeTests {
    /// Requests the store made, by method name, with their JSON bodies.
    private final class Log: @unchecked Sendable { var calls: [(method: String, body: [String: Any])] = [] }

    private func connectedStore(log: Log = Log()) async -> MailStore {
        StubServer.handler = { request, body in
            let method = request.url?.lastPathComponent ?? ""
            log.calls.append((method, (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]))
            if method.hasSuffix("get_user_info") {
                return .json(#"""
                {"message":{"email":"maya@example.com","is_jmap_configured":true,
                 "accounts":[{"account":"acc1","is_personal":true,"in_mail":true,"default_outgoing_email":"maya@example.com"}]}}
                """#)
            }
            if method.hasSuffix("create_mail") || method.hasSuffix("update_draft_mail") {
                return .json(#"{"message":{"id":"draft9","error":null}}"#)
            }
            if method.hasSuffix("get_threads") { return .json(#"{"message":{"rows":[],"has_more":false}}"#) }
            return .json(#"{"message":[]}"#)
        }
        let store = MailStore()
        await store.connect(StubServer.client())
        return store
    }

    private func thread(from sender: String, to: [String], cc: [String] = [], bcc: [String] = []) -> MailThread {
        let recipients = to.map { MailRecipient(email: $0, kind: .to) } + cc.map { MailRecipient(email: $0, kind: .cc) }
            + bcc.map { MailRecipient(email: $0, kind: .bcc) }
        let message = MailMessage(id: "m1", fromName: sender, fromEmail: sender, to: to, date: .now, body: "Hello",
                                  recipients: recipients, headerID: "<m1@example.com>")
        return MailThread(id: "t1", mailbox: .inbox, subject: "Plans", isRead: true, isStarred: false, messages: [message])
    }

    @Test func replyAllAnswersTheSenderAndCopiesEveryoneElseButMe() async {
        let store = await connectedStore()
        let draft = store.reply(to: thread(from: "lee@example.com", to: ["maya@example.com", "sam@example.com"],
                                           cc: ["ana@example.com"], bcc: ["hidden@example.com"]), all: true)

        #expect(draft.recipients.to == ["lee@example.com"])
        #expect(draft.recipients.cc == ["sam@example.com", "ana@example.com"])
        #expect(draft.subject == "Re: Plans")
    }

    @Test func replyingToMyOwnMessageGoesToWhoIWroteTo() async {
        let store = await connectedStore()
        let draft = store.reply(to: thread(from: "maya@example.com", to: ["lee@example.com"]), all: false)

        #expect(draft.recipients.to == ["lee@example.com"])
        #expect(draft.recipients.cc.isEmpty)
    }

    @Test func aReplyQuotesTheMessageItAnswers() async throws {
        let log = Log()
        let store = await connectedStore(log: log)
        var draft = store.reply(to: thread(from: "lee@example.com", to: ["maya@example.com"]), all: false)
        draft.body = "Sounds good"

        try await store.send(draft)

        let sent = try #require(log.calls.last { $0.method.hasSuffix("create_mail") }?.body)
        #expect(sent["in_reply_to"] as? String == "<m1@example.com>")
        #expect(sent["subject"] as? String == "Re: Plans")
    }

    @Test func forwardKeepsTheOriginalBelowTheNewText() async throws {
        let log = Log()
        let store = await connectedStore(log: log)
        var draft = store.forward(thread(from: "lee@example.com", to: ["maya@example.com"]))
        draft.to = "ana@example.com"
        draft.body = "FYI"

        try await store.send(draft)

        let sent = try #require(log.calls.last { $0.method.hasSuffix("create_mail") }?.body)
        let html = try #require(sent["html_body"] as? String)
        #expect(draft.subject == "Fwd: Plans")
        #expect(sent["forwarded_from_id"] as? String == "m1")
        #expect(html.contains("FYI") && html.contains("Forwarded message") && html.contains("Hello"))
        #expect(html.range(of: "FYI")!.lowerBound < html.range(of: "Hello")!.lowerBound)
    }

    @Test func aSavedDraftIsSentInPlace() async throws {
        let log = Log()
        let store = await connectedStore(log: log)
        var draft = Draft(to: "lee@example.com", subject: "Later", body: "Draft text")

        try await store.saveDraft(draft)
        draft.savedID = "draft9"
        try await store.send(draft)

        let saved = try #require(log.calls.first { $0.method.hasSuffix("create_mail") }?.body)
        #expect(saved["save_as_draft"] as? Bool == true)
        let sent = try #require(log.calls.last { $0.method.hasSuffix("update_draft_mail") }?.body)
        #expect(sent["id"] as? String == "draft9")
        #expect(sent["submit"] as? Bool == true)
    }
}
