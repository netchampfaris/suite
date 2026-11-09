import Foundation

enum Mailbox: Hashable, Identifiable, Sendable {
    case inbox, starred, sent, drafts, archive, spam, trash
    /// A folder the person made, by its id on the mail server.
    case folder(id: String, name: String)

    /// Every account has these, in the web app's order.
    static let standard: [Mailbox] = [.inbox, .starred, .sent, .drafts, .archive, .spam, .trash]

    var id: String {
        if case .folder(let id, _) = self { "folder:\(id)" } else { title }
    }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .starred: "Starred"
        case .sent: "Sent"
        case .drafts: "Drafts"
        case .archive: "Archive"
        case .spam: "Spam"
        case .trash: "Trash"
        case .folder(_, let name): name
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .starred: "star"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .archive: "archivebox"
        case .spam: "xmark.bin"
        case .trash: "trash"
        case .folder: "folder"
        }
    }

    /// The server's role for a standard mailbox. Starred is a search, and folders have no role.
    var role: String? {
        switch self {
        case .inbox: "inbox"
        case .sent: "sent"
        case .drafts: "drafts"
        case .archive: "archive"
        case .spam: "junk"
        case .trash: "trash"
        case .starred, .folder: nil
        }
    }
}

/// The tabs that split the inbox by kind of sender, named as the server names them.
enum MailCategory: String, CaseIterable, Identifiable, Sendable {
    case primary, updates, forums, promotions, social

    var id: String { rawValue }

    var title: String {
        switch self {
        case .primary: "Primary"
        case .updates: "Updates"
        case .forums: "Forums"
        case .promotions: "Promotions"
        case .social: "Social"
        }
    }

    var systemImage: String {
        switch self {
        case .primary: "tray"
        case .updates: "bell"
        case .forums: "bubble.left.and.bubble.right"
        case .promotions: "tag"
        case .social: "person.2"
        }
    }
}

struct MailMessage: Identifiable, Hashable, Sendable {
    let id: String
    let fromName: String
    let fromEmail: String
    let to: [String]
    let date: Date
    /// Plain text, for previews and for sample mail.
    let body: String
    /// The message as the sender wrote it, when it has HTML.
    var html: String?
    /// Who it went to, for replying to all. Sample mail has none.
    var recipients: [MailRecipient] = []
    /// The `Message-ID` header, which a reply quotes. Sample mail has none.
    var headerID: String?
}

struct MailAttachment: Identifiable, Hashable, Sendable {
    var id: String { url ?? name }
    let name: String
    var size: Int?
    /// Where the site serves the file. Sample attachments have none and cannot be opened.
    var url: String?
    /// The file on the mail server, which a forward or a saved draft reuses.
    var blobID: String?
    /// The MIME type, which the server needs to reuse the file.
    var type: String?
}

struct MailRecipient: Hashable, Sendable {
    enum Kind: String, Sendable { case to = "To", cc = "Cc", bcc = "Bcc" }

    let email: String
    var name: String?
    var kind = Kind.to
}

struct MailThread: Identifiable, Hashable, Sendable {
    let id: String
    var mailbox: Mailbox
    var category = MailCategory.primary
    let subject: String
    var isRead: Bool
    var isStarred: Bool
    var messages: [MailMessage]
    var attachments: [MailAttachment] = []
    /// The server's ids for every message in the thread. Read, star, and move act on all of them.
    var messageIDs: [String] = []

    var latest: MailMessage { messages[messages.count - 1] }
}
