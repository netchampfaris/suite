import Foundation

/// The one ordered right a grant gives, lowest first. A higher role contains every lower one.
enum DriveRole: Int, CaseIterable, Identifiable, Sendable {
    case view = 10, comment = 20, upload = 30, edit = 40, manage = 50

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .view: "View"
        case .comment: "Comment"
        case .upload: "Upload"
        case .edit: "Edit"
        case .manage: "Manage"
        }
    }

    /// The roles a person can be given on a node. Upload gives nothing on a file or document.
    static func choices(for node: DriveNode) -> [DriveRole] {
        node.isContainer ? allCases : allCases.filter { $0 != .upload }
    }
}

/// Whoever a grant names: a user, a group, everyone in the workspace, a share link, or anyone at all.
enum Principal: Hashable, Sendable {
    case user(String)
    case group(String)
    case everyone
    case link
    case anyone

    init(_ raw: String) {
        if raw == "$GENERAL" {
            self = .everyone
        } else if raw == "$PUBLIC" {
            self = .anyone
        } else if raw.hasPrefix("$LINK") {
            self = .link
        } else if raw.hasPrefix("$GROUP:") {
            self = .group(String(raw.dropFirst("$GROUP:".count)))
        } else {
            self = .user(raw)
        }
    }
}

/// One row of who has access to a node.
struct Grant: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let principal: String
    let role: Int
    let person: Person?

    var id: String { name }
    var who: Principal { Principal(principal) }
    /// Zero refuses access. On `$GENERAL` it restricts the node, which is not a person to list.
    var isDeny: Bool { role <= 0 }
}

struct Grants: Decodable, Sendable {
    let grants: [Grant]
    /// The person whose own Drive holds the node. None in the shared Drive.
    let owner: Person?
}

/// A user or group the person can share with, from the site's people search.
struct Candidate: Decodable, Identifiable, Hashable, Sendable {
    let kind: String
    let name: String
    let fullName: String?
    let userImage: String?
    let memberCount: Int?

    var id: String { principal }
    var principal: String { kind == "group" ? "$GROUP:\(name)" : name }
    var title: String { fullName ?? name }
}

/// Who a move would give access to that does not have it now.
struct MovePreview: Decodable, Sendable {
    struct Gain: Decodable, Sendable {
        let principal: String
    }

    let gains: [Gain]
}

extension DriveClient {
    func grants(of node: String) async throws -> Grants {
        try await api.call("GET", path("nodes/\(node)/grants"))
    }

    /// Gives a principal a role, replacing the one it had. A user added for the first time is told by email.
    func share(_ node: String, with principal: String, as role: DriveRole) async throws {
        let body = GrantWrite(role: role.rawValue, notify: Principal(principal).isUser ? true : nil)
        let _: Grant = try await api.call("PUT", path("nodes/\(node)/grants/\(principal)"), body: body)
    }

    func unshare(_ node: String, from principal: String) async throws {
        let _: Count = try await api.call("DELETE", path("nodes/\(node)/grants/\(principal)"))
    }

    func people(matching term: String) async throws -> [Candidate] {
        let page: Page<Candidate> = try await api.call("GET", "api/suite/people", query: term.isEmpty ? [:] : ["q": term])
        return page.rows
    }

    func previewMove(_ node: String, to folder: String) async throws -> MovePreview {
        try await api.call("GET", path("nodes/\(node)/move-preview"), query: ["parent_node": folder])
    }

    /// Moves a node, refused if it is no longer in `from`, where the person last saw it.
    func move(_ node: String, to folder: String, from: String?) async throws -> DriveNode {
        try await api.call("PATCH", path("nodes/\(node)"), body: Move(parentNode: folder, expectParentNode: from))
    }
}

private extension Principal {
    var isUser: Bool { if case .user = self { true } else { false } }
}

private struct GrantWrite: Encodable, Sendable {
    let role: Int
    let notify: Bool?
}

private struct Move: Encodable, Sendable {
    let parentNode: String
    let expectParentNode: String?
}

private struct Count: Decodable, Sendable {
    let count: Int
}
