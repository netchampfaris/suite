import Foundation
import Observation

/// The person's mail. On a site with a mail server it loads each list from the server and sends changes
/// back; without one it holds sample threads and changes them in memory.
@MainActor
@Observable
final class MailStore {
    private(set) var isSample = true
    private(set) var isLoading = false
    /// The inbox tabs to show. Empty when the server does not split the inbox.
    private(set) var categories: [MailCategory] = [.primary, .updates, .promotions]
    var error: String?

    private var threads: [String: MailThread]
    /// The person's own folders, after the standard mailboxes.
    private(set) var folders: [Mailbox] = []

    /// Thread ids in the order the server listed them, for each list loaded so far.
    private var lists: [ListKey: [String]] = [:]
    /// Where each list's next page starts. A list with no entry has no more pages.
    private var nextPage: [ListKey: Int] = [:]
    private var server: MailServer?
    private var mailboxIDs: [Mailbox: String] = [:]
    private var inboxUnread = 0
    private var tabUnread: [MailCategory: Int] = [:]

    init() {
        threads = Dictionary(uniqueKeysWithValues: SampleMail.threads().map { ($0.id, $0) })
    }

    /// Switches to the site's mail when the person has a mail account there.
    func connect(_ api: APIClient) async {
        guard let server = try? await MailServer.connect(api) else { return }
        self.server = server
        isSample = false
        threads = [:]
        categories = server.categories
        await refreshCounts()
    }

    // MARK: Reading

    func threads(in mailbox: Mailbox, category: MailCategory?) -> [MailThread] {
        let category = mailbox == .inbox && !categories.isEmpty ? category : nil
        let candidates = isSample ? Array(threads.values) : (lists[ListKey(mailbox, category)] ?? []).compactMap { threads[$0] }
        let matching = candidates.filter { thread in
            let inList = mailbox == .starred ? thread.isStarred && thread.mailbox != .trash : thread.mailbox == mailbox
            return inList && (category == nil || thread.category == category)
        }
        return isSample ? matching.sorted { $0.latest.date > $1.latest.date } : matching
    }

    func thread(_ id: String) -> MailThread? { threads[id] }

    /// Loads a thread no list has loaded, such as one a link names. Returns whether it is now known.
    func fetch(_ id: String) async -> Bool {
        guard threads[id] == nil else { return true }
        guard let server else { return false }
        do {
            if mailboxIDs.isEmpty { try await loadMailboxes() }
            let messages = try await server.thread(id)
            guard let first = messages.first else { return false }
            let row = WireThread(
                id: first.id, threadId: id, subject: first.subject,
                seen: messages.allSatisfy { $0.seen == 1 } ? 1 : 0,
                flagged: messages.contains { $0.flagged == 1 } ? 1 : 0,
                reactionOnly: nil, messages: messages, mailboxes: first.mailboxes
            )
            let place = row.mailboxes?.lazy.compactMap { self.mailbox(withID: $0.mailboxId) }.first
            threads[id] = row.thread(in: place ?? .inbox, category: .primary)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Every mailbox the title menu offers.
    var mailboxes: [Mailbox] { Mailbox.standard + folders }

    func hasMore(_ mailbox: Mailbox, category: MailCategory?) -> Bool {
        nextPage[ListKey(mailbox, listCategory(mailbox, category))] != nil
    }

    var unread: Int {
        isSample ? threads.values.filter { $0.mailbox == .inbox && !$0.isRead }.count : inboxUnread
    }

    func unread(in category: MailCategory) -> Int {
        isSample
            ? threads.values.filter { $0.mailbox == .inbox && $0.category == category && !$0.isRead }.count
            : tabUnread[category] ?? 0
    }

    /// Fetches one list from the server. Sample mail has nothing to fetch.
    func load(_ mailbox: Mailbox, category: MailCategory?) async {
        await fetch(mailbox, category: category, more: false)
    }

    /// Appends the list's next page. Does nothing on the last page or while a page is loading.
    func loadMore(_ mailbox: Mailbox, category: MailCategory?) async {
        guard !isLoading, hasMore(mailbox, category: category) else { return }
        await fetch(mailbox, category: category, more: true)
    }

    private func fetch(_ mailbox: Mailbox, category: MailCategory?, more: Bool) async {
        guard let server else { return }
        let category = listCategory(mailbox, category)
        let key = ListKey(mailbox, category)
        isLoading = true
        defer { isLoading = false }
        do {
            if mailboxIDs.isEmpty { try await loadMailboxes() }
            guard let id = serverID(mailbox) else { return }
            let page = try await server.threads(in: id, category: category, start: more ? nextPage[key] ?? 0 : 0)
            for row in page.rows {
                var thread = row.thread(in: mailbox, category: category ?? .primary)
                // A starred thread keeps the mailbox it was listed in elsewhere.
                if mailbox == .starred { thread.mailbox = threads[thread.id]?.mailbox ?? .inbox }
                threads[thread.id] = thread
            }
            let ids = page.rows.map(\.threadId)
            lists[key] = more ? (lists[key] ?? []) + ids.filter { !(lists[key] ?? []).contains($0) } : ids
            nextPage[key] = page.next
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Only the inbox splits into categories, and only when the server splits it.
    private func listCategory(_ mailbox: Mailbox, _ category: MailCategory?) -> MailCategory? {
        mailbox == .inbox && !categories.isEmpty ? category : nil
    }

    private func serverID(_ mailbox: Mailbox) -> String? {
        switch mailbox {
        case .starred: "starred"
        case .folder(let id, _): id
        default: mailboxIDs[mailbox]
        }
    }

    // MARK: Searching

    /// Thread ids matching the last search, newest match first.
    private var results: [String] = []
    private(set) var isSearching = false

    var searchResults: [MailThread] { results.compactMap { threads[$0] } }

    /// Searches every mailbox. Sample mail is searched in memory.
    func search(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { results = []; return }
        guard let server else {
            results = threads.values
                .filter { thread in
                    [thread.subject, thread.latest.fromName, thread.latest.fromEmail, thread.latest.body]
                        .contains { $0.localizedCaseInsensitiveContains(text) }
                }
                .sorted { $0.latest.date > $1.latest.date }
                .map(\.id)
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            if mailboxIDs.isEmpty { try await loadMailboxes() }
            let rows = try await server.search(text)
            for row in rows {
                let place = row.mailboxes?.lazy.compactMap { self.mailbox(withID: $0.mailboxId) }.first
                threads[row.threadId] = row.thread(in: place ?? threads[row.threadId]?.mailbox ?? .inbox,
                                                   category: threads[row.threadId]?.category ?? .primary)
            }
            results = rows.map(\.threadId)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func mailbox(withID id: String) -> Mailbox? {
        mailboxIDs.first { $0.value == id }?.key ?? folders.first { $0.id == "folder:\(id)" }
    }

    // MARK: Changing

    func markRead(_ id: String, _ read: Bool = true) {
        guard threads[id]?.isRead != read else { return }
        change(id) { $0.isRead = read }
        send(id) { server, ids in try await server.setSeen(ids, read) }
    }

    func markAllRead(_ ids: [String]) {
        for id in ids { markRead(id) }
    }

    func toggleStar(_ id: String) {
        change(id) { $0.isStarred.toggle() }
        let starred = threads[id]?.isStarred ?? false
        send(id) { server, ids in try await server.setFlagged(ids, starred) }
    }

    func move(_ id: String, to mailbox: Mailbox) {
        change(id) { $0.mailbox = mailbox }
        let inbox = mailboxIDs[.inbox]
        send(id) { server, ids in
            switch mailbox {
            case .archive: try await server.file(ids, action: "archive")
            case .trash: try await server.file(ids, action: "trash")
            default: try await server.file(ids, action: "move", mailbox: inbox)
            }
        }
    }

    /// The mail server account, which also holds the person's calendars.
    var account: String? { server?.account }

    /// The address mail is sent from.
    var myEmail: String { server?.fromEmail ?? "you@example.com" }

    /// Sends the message, then adds it to its thread. Throws when the server refuses, so the draft stays open.
    func send(_ draft: Draft) async throws {
        if let server {
            try await server.send(outgoing(draft, from: server))
            if draft.savedID != nil { await fetch(.drafts, category: nil, more: false) }
        }
        let (to, _, _) = draft.recipients
        let message = MailMessage(id: UUID().uuidString, fromName: "You", fromEmail: myEmail, to: to, date: .now, body: draft.body)
        if let id = draft.threadID, threads[id] != nil {
            change(id) { $0.messages.append(message) }
        } else if isSample {
            let thread = MailThread(id: UUID().uuidString, mailbox: .sent, subject: draft.subject,
                                    isRead: true, isStarred: false, messages: [message])
            threads[thread.id] = thread
        }
    }

    /// Keeps the draft on the server, where Drafts lists it. Sample mail has nowhere to keep it.
    func saveDraft(_ draft: Draft) async throws {
        guard let server else { return }
        _ = try await server.saveDraft(outgoing(draft, from: server))
        await fetch(.drafts, category: nil, more: false)
    }

    /// Throws away the draft, and its saved copy if it has one.
    func discard(_ draft: Draft) async throws {
        guard let server, let id = draft.savedID else { return }
        try await server.delete(id)
        await fetch(.drafts, category: nil, more: false)
    }

    func upload(_ file: URL) async throws -> UploadedFile {
        guard let server else { throw APIError(type: "Sample", message: "Sample mail cannot carry attachments.", status: 0) }
        return try await server.upload(file)
    }

    // MARK: Starting a draft

    /// A reply to the thread's latest message. Replying to all copies everyone else on it.
    func reply(to thread: MailThread, all: Bool) -> Draft {
        let latest = thread.latest
        let me = myEmail.lowercased()
        let sentByMe = latest.fromEmail.lowercased() == me
        // A reply to your own message goes to the people you wrote to, not back to you.
        let to = sentByMe ? latest.recipients.filter { $0.kind == .to }.map(\.email) : [latest.fromEmail]
        let others = all ? latest.recipients.filter { $0.kind != .bcc }.map(\.email) : []
        let cc = others.filter { email in
            let lower = email.lowercased()
            return lower != me && !to.contains { $0.lowercased() == lower }
        }
        return Draft(
            to: (to.isEmpty ? [latest.fromEmail] : to).joined(separator: ", "),
            cc: Array(NSOrderedSet(array: cc)).compactMap { $0 as? String }.joined(separator: ", "),
            subject: Self.prefixed("Re:", thread.subject),
            threadID: thread.id,
            replying: latest
        )
    }

    func forward(_ thread: MailThread) -> Draft {
        Draft(subject: Self.prefixed("Fwd:", thread.subject), forwarding: thread.latest,
              kept: thread.attachments.filter { $0.blobID != nil })
    }

    /// Opens a saved draft for more writing.
    func edit(_ thread: MailThread) -> Draft {
        let message = thread.latest
        func addresses(_ kind: MailRecipient.Kind) -> String {
            message.recipients.filter { $0.kind == kind }.map(\.email).joined(separator: ", ")
        }
        return Draft(to: addresses(.to), cc: addresses(.cc), bcc: addresses(.bcc),
                     subject: thread.subject == "(No subject)" ? "" : thread.subject, body: message.body,
                     kept: thread.attachments.filter { $0.blobID != nil }, savedID: message.id)
    }

    private static func prefixed(_ prefix: String, _ subject: String) -> String {
        subject.lowercased().hasPrefix(prefix.lowercased()) ? subject : "\(prefix) \(subject)"
    }

    private func outgoing(_ draft: Draft, from server: MailServer) -> MailServer.Outgoing {
        let (to, cc, bcc) = draft.recipients
        let files = draft.kept.compactMap { file in
            file.blobID.map { MailServer.Outgoing.File(blobId: $0, fileName: file.name, type: file.type ?? "application/octet-stream", size: file.size) }
        } + draft.added.compactMap { file in
            file.uploaded.map { MailServer.Outgoing.File(fileUrl: $0.fileUrl, fileName: $0.fileName, size: $0.fileSize) }
        }
        var html = Self.html(draft.body)
        if let original = draft.forwarding { html += Self.forwarded(original) }
        return MailServer.Outgoing(
            account: server.account, fromEmail: server.fromEmail,
            to: to.map { .init(email: $0) }, cc: cc.map { .init(email: $0) }, bcc: bcc.map { .init(email: $0) },
            subject: draft.subject, htmlBody: html, attachments: files,
            inReplyTo: draft.replying?.headerID, inReplyToId: draft.replying?.id,
            forwardedFromId: draft.forwarding?.id, id: draft.savedID
        )
    }

    /// The forwarded message under a header, as mail apps quote it.
    private static func forwarded(_ message: MailMessage) -> String {
        let header = [
            "---------- Forwarded message ---------",
            "From: \(message.fromName) <\(message.fromEmail)>",
            "Date: \(message.date.formatted(date: .long, time: .shortened))",
            "To: \(message.to.joined(separator: ", "))",
        ].map { escape($0) }.joined(separator: "<br>")
        return "<br><div>\(header)<br><br>\(message.html ?? html(message.body))</div>"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// A local copy of the attachment. Sample attachments have no file.
    func download(_ attachment: MailAttachment) async throws -> URL {
        guard let server else { throw APIError(type: "Sample", message: "Sample attachments cannot be opened.", status: 0) }
        return try await server.download(attachment)
    }

    /// The site, for loading a message's images with the session.
    var site: URL? { server?.api.site }

    // MARK: Helpers

    private func change(_ id: String, _ edit: (inout MailThread) -> Void) {
        guard var thread = threads[id] else { return }
        edit(&thread)
        threads[id] = thread
    }

    /// Sends a change for a thread's messages, then refreshes the unread counts.
    private func send(_ id: String, _ action: @escaping @Sendable (MailServer, [String]) async throws -> Void) {
        guard let server, let ids = threads[id]?.messageIDs, !ids.isEmpty else { return }
        Task {
            do {
                try await action(server, ids)
                await refreshCounts()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func loadMailboxes() async throws {
        guard let server else { return }
        let boxes = try await server.mailboxes()
        let roles = Dictionary(Mailbox.standard.compactMap { box in box.role.map { ($0, box) } }, uniquingKeysWith: { first, _ in first })
        mailboxIDs = Dictionary(boxes.compactMap { box in box.role.flatMap { roles[$0.lowercased()] }.map { ($0, box.id) } },
                                uniquingKeysWith: { first, _ in first })
        // Folders the person unsubscribed from stay hidden, as on the web.
        folders = boxes
            .filter { ($0.role ?? "").isEmpty && $0.subscribed != false }
            .compactMap { box in box.name.map { Mailbox.folder(id: box.id, name: $0) } }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        inboxUnread = boxes.first { $0.role == "inbox" }?.unreadThreads ?? 0
    }

    private func refreshCounts() async {
        guard let server else { return }
        try? await loadMailboxes()
        if let inbox = mailboxIDs[.inbox], !categories.isEmpty {
            tabUnread = (try? await server.tabCounts(inbox: inbox)) ?? tabUnread
        }
    }

    private static func html(_ text: String) -> String {
        escape(text)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "<p>\($0.isEmpty ? "<br>" : $0)</p>" }
            .joined()
    }

    private struct ListKey: Hashable {
        let mailbox: Mailbox
        let category: MailCategory?

        init(_ mailbox: Mailbox, _ category: MailCategory?) {
            self.mailbox = mailbox
            self.category = category
        }
    }
}
