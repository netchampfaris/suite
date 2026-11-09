import Foundation

/// The site's Mail API for one account. Every call is a POST to `suite.mail.api`, even reads.
struct MailServer: Sendable {
    let api: APIClient
    let account: String
    let fromEmail: String
    /// The inbox tabs the server splits mail into, in the web app's order. Empty when the inbox is not split.
    let categories: [MailCategory]

    /// Connects to the person's own account, or returns nil when the site has no mail account for them.
    static func connect(_ api: APIClient) async throws -> MailServer? {
        let info: WireUserInfo? = try await api.method("suite.mail.api.account.get_user_info", body: [String: String]())
        guard let info, info.isJmapConfigured == true,
              let account = info.accounts?.first(where: { $0.isPersonal == true && $0.inMail == true })
                ?? info.accounts?.first(where: { $0.inMail == true })
        else { return nil }
        let isSplit = info.emailClassification == true && info.splitInbox == 1
        return MailServer(
            api: api,
            account: account.account,
            fromEmail: account.defaultOutgoingEmail ?? info.email ?? "",
            categories: isSplit ? (info.inboxTabs ?? []).compactMap(MailCategory.init(rawValue:)) : []
        )
    }

    func mailboxes() async throws -> [WireMailbox] {
        try await call("get_mailboxes", ["account": account])
    }

    /// One page of a mailbox. `next` is where the following page starts, or nil on the last page.
    func threads(in mailbox: String, category: MailCategory?, start: Int = 0) async throws -> (rows: [WireThread], next: Int?) {
        let page: WireThreadPage = try await call("get_threads", Threads(
            account: account, mailbox: mailbox, limit: 50, start: start, category: category?.rawValue
        ))
        // Rows that only carry a reaction are left out, but they count toward where the next page starts.
        let next = page.hasMore == true ? start + page.rows.count : nil
        return (page.rows.filter { $0.reactionOnly != 1 }, next)
    }

    /// Threads with mail matching the text, in every mailbox, newest match first.
    func search(_ text: String) async throws -> [WireThread] {
        let page: WireSearchPage = try await call("search_mails", Search(account: account, filter: ["text": text], limit: 50))
        return page.rows
    }

    /// Every message in a thread, oldest first, for a thread no loaded list has.
    func thread(_ id: String) async throws -> [WireMessage] {
        try await call("get_thread", ["account": account, "thread_id": id])
    }

    func tabCounts(inbox: String) async throws -> [MailCategory: Int] {
        let rows: [WireTabCount] = try await call("get_tab_counts", ["account": account, "mailbox": inbox])
        return Dictionary(rows.compactMap { row in MailCategory(rawValue: row.category).map { ($0, row.unreadThreads) } },
                          uniquingKeysWith: +)
    }

    func setSeen(_ ids: [String], _ seen: Bool) async throws {
        let _: [String]? = try await call("set_mails_seen", Flag(account: account, ids: ids, seen: seen))
    }

    func setFlagged(_ ids: [String], _ flagged: Bool) async throws {
        let _: Ignored? = try await call("set_flagged", Flag(account: account, ids: ids, flagged: flagged))
    }

    /// Files mail the way the web app does: `archive`, `trash`, or `move` with a mailbox id.
    func file(_ ids: [String], action: String, mailbox: String? = nil) async throws {
        let _: Ignored? = try await call("file_mails", Filing(account: account, ids: ids, action: action, mailbox: mailbox))
    }

    /// Sends a message. A saved draft is sent in place, so it leaves Drafts.
    func send(_ mail: Outgoing) async throws {
        var mail = mail
        mail.submit = mail.id == nil ? nil : true
        mail.saveAsDraft = nil
        try await write(mail)
    }

    /// Saves a draft, or updates one saved before. Returns the draft's id.
    func saveDraft(_ mail: Outgoing) async throws -> String? {
        var mail = mail
        if mail.id == nil { mail.saveAsDraft = true } else { mail.submit = false }
        return try await write(mail)
    }

    func delete(_ id: String) async throws {
        let _: Ignored? = try await call("delete_mail", ["account": account, "id": id])
    }

    /// Uploads a file to attach. The message names it by the returned URL.
    func upload(_ file: URL) async throws -> UploadedFile {
        try await api.upload("suite.mail.api.mail.upload_file", file: file, fields: ["is_private": "1"])
    }

    @discardableResult
    private func write(_ mail: Outgoing) async throws -> String? {
        let result: WireDraftResult = try await call(mail.id == nil ? "create_mail" : "update_draft_mail", mail)
        if let error = result.error, !error.isEmpty { throw APIError(type: "MailError", message: error, status: 0) }
        return result.id
    }

    /// Downloads an attachment under its own name, for Quick Look.
    func download(_ attachment: MailAttachment) async throws -> URL {
        guard let reference = attachment.url, let url = api.resolve(reference) else { throw APIError.unreadable }
        let (temporary, _) = try await api.download(from: url)
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: attachment.name)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private func call<Output: Decodable & Sendable>(_ name: String, _ body: some Encodable & Sendable) async throws -> Output {
        try await api.method("suite.mail.api.mail." + name, body: body)
    }

    // MARK: Request bodies

    private struct Threads: Encodable, Sendable {
        let account: String, mailbox: String, limit: Int, start: Int, category: String?
    }

    private struct Search: Encodable, Sendable {
        let account: String, filter: [String: String], limit: Int
    }

    private struct Flag: Encodable, Sendable {
        let account: String, ids: [String]
        var seen: Bool?
        var flagged: Bool?
    }

    private struct Filing: Encodable, Sendable {
        let account: String, ids: [String], action: String, mailbox: String?
    }

    struct Outgoing: Encodable, Sendable {
        struct Address: Encodable, Sendable { let email: String }

        /// A file already on the mail server (`blobId`) or just uploaded to the site (`fileUrl`).
        struct File: Encodable, Sendable {
            var fileUrl: String?
            var blobId: String?
            let fileName: String
            var type: String?
            var size: Int?
        }

        let account: String
        let fromEmail: String
        let to: [Address]
        /// The server requires both lists, even when they are empty.
        var cc: [Address] = []
        var bcc: [Address] = []
        let subject: String
        let htmlBody: String
        var attachments: [File] = []
        var inReplyTo: String?
        var inReplyToId: String?
        var forwardedFromId: String?
        /// A saved draft's id. With one, the message updates that draft instead of starting anew.
        var id: String?
        var saveAsDraft: Bool?
        var submit: Bool?
    }

    private struct Ignored: Decodable, Sendable {}
}

// MARK: Wire format

private struct WireUserInfo: Decodable, Sendable {
    struct Account: Decodable, Sendable {
        let account: String
        let isPersonal: Bool?
        let inMail: Bool?
        let defaultOutgoingEmail: String?
    }

    let email: String?
    let isJmapConfigured: Bool?
    let emailClassification: Bool?
    let splitInbox: Int?
    let inboxTabs: [String]?
    let accounts: [Account]?
}

struct WireMailbox: Decodable, Sendable {
    let id: String
    let name: String?
    let role: String?
    let unreadThreads: Int?
    let subscribed: Bool?

    private enum CodingKeys: String, CodingKey {
        // The server keeps the folder's own name under `_name`; `name` is its document id.
        case id, name = "_name", role, unreadThreads, subscribed
    }
}

private struct WireThreadPage: Decodable, Sendable {
    let rows: [WireThread]
    let hasMore: Bool?
}

private struct WireSearchPage: Decodable, Sendable {
    let rows: [WireThread]
}

private struct WireTabCount: Decodable, Sendable {
    let category: String
    let unreadThreads: Int
}

private struct WireDraftResult: Decodable, Sendable {
    let id: String?
    let error: String?
}

struct WireMessage: Decodable, Sendable {
    struct Recipient: Decodable, Sendable { let email: String; let displayName: String?; let type: String? }
    struct Attachment: Decodable, Sendable {
        let filename: String?
        let size: Int?
        let url: String?
        let disposition: String?
        let blobId: String?
        let type: String?
    }
    struct Copy: Decodable, Sendable { let id: String }

    let id: String
    let messageId: String?
    let fromName: String?
    let fromEmail: String?
    let subject: String?
    let htmlBody: String?
    let textBody: String?
    let preview: String?
    let receivedAt: Date
    let seen: Int?
    let flagged: Int?
    let recipients: [Recipient]?
    let attachments: [Attachment]?
    let duplicates: [Copy]?
    let threadId: String?
    let mailboxes: [WireThread.Place]?
}

struct WireThread: Decodable, Sendable {
    let id: String
    let threadId: String
    let subject: String?
    let seen: Int?
    let flagged: Int?
    let reactionOnly: Int?
    let messages: [WireMessage]?
    /// Where the thread is filed. Only search results say, since a list's rows are all in that list.
    let mailboxes: [Place]?

    struct Place: Decodable, Sendable { let mailboxId: String }

    /// The thread as the app shows it. `mailbox` and `category` are the list it was fetched for.
    func thread(in mailbox: Mailbox, category: MailCategory) -> MailThread {
        let wire = messages ?? []
        let shown = wire.map { message in
            MailMessage(
                id: message.id,
                fromName: message.fromName.flatMap { $0.isEmpty ? nil : $0 } ?? message.fromEmail ?? "Unknown",
                fromEmail: message.fromEmail ?? "",
                to: (message.recipients ?? []).map { $0.displayName ?? $0.email },
                date: message.receivedAt,
                body: message.textBody.flatMap { $0.isEmpty ? nil : $0 }
                    ?? message.htmlBody.map(PlainText.init(html:))?.text ?? message.preview ?? "",
                html: message.htmlBody.flatMap { $0.isEmpty ? nil : $0 },
                recipients: (message.recipients ?? []).map {
                    MailRecipient(email: $0.email, name: $0.displayName, kind: MailRecipient.Kind(rawValue: $0.type ?? "") ?? .to)
                },
                headerID: message.messageId
            )
        }
        // The server sends actions to every copy of every message, so the app does too.
        let ids = wire.flatMap { [$0.id] + ($0.duplicates ?? []).map(\.id) }
        return MailThread(
            id: threadId,
            mailbox: mailbox,
            category: category,
            subject: subject.flatMap { $0.isEmpty ? nil : $0 } ?? "(No subject)",
            isRead: seen == 1,
            isStarred: flagged == 1,
            messages: shown.isEmpty ? [MailMessage(id: id, fromName: "", fromEmail: "", to: [], date: .now, body: "")] : shown,
            // Inline images show in the message itself, so only the rest are listed.
            attachments: wire.flatMap { message in
                (message.attachments ?? []).compactMap { file in
                    guard let name = file.filename, file.disposition != "inline" else { return nil }
                    return MailAttachment(name: name, size: file.size, url: file.url, blobID: file.blobId, type: file.type)
                }
            },
            messageIDs: ids.isEmpty ? [id] : ids
        )
    }
}

/// HTML mail as plain text: block tags become line breaks, the rest is dropped.
struct PlainText {
    let text: String

    init(html: String) {
        var text = html
        for (pattern, replacement) in [
            ("(?is)<(style|script|head)[^>]*>.*?</\\1>", ""),
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</(p|div|tr|li|h[1-6]|blockquote)>", "\n"),
            ("<[^>]+>", ""),
            ("[ \\t]+", " "),
            ("\\n\\s*\\n\\s*\\n+", "\n\n"),
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
