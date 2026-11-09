import Foundation

/// One step in a node's path. A file inside a document has the document as a step, which is not a folder.
struct Breadcrumb: Decodable, Hashable, Sendable {
    let name: String
    let title: String
    let kind: String

    var isFolder: Bool { kind == "folder" || kind == "root" }
}

/// One entry in a Drive tree, as `/api/suite/drive/` answers it.
struct DriveNode: Decodable, Identifiable, Hashable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case root, folder, file, link, document
        case unknown

        init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    struct Preview: Decodable, Hashable, Sendable {
        let url: String
    }

    let name: String
    var title: String
    let kind: Kind
    var parentNode: String?
    let root: String
    var state: String
    let size: Int
    let mime: String?
    let url: String?
    let contentDoctype: String?
    let owner: Person
    let modified: Date?
    let contentModified: Date?
    var favourite: Bool?
    var preview: Preview?
    var openedAt: Date?

    var id: String { name }
    var isContainer: Bool { kind == .folder || kind == .root }
    var isTrashed: Bool { state == "Trashed" }

    /// When the content last changed, which is what a person means by "modified".
    var changed: Date? { contentModified ?? modified }
}

struct Person: Decodable, Hashable, Sendable {
    let id: String
    let fullName: String
    let userImage: String?
}

struct Page<Row: Decodable & Sendable>: Decodable, Sendable {
    let rows: [Row]
    let nextCursor: String?
}

/// The caller's own Drive and, on a business site, the shared one.
struct RootLocations: Decodable, Sendable {
    struct Location: Decodable, Hashable, Sendable {
        let node: String
        let title: String
    }

    let personal: Location
    let organization: Location?
}

/// A sort a folder listing accepts. Folders always come first.
enum DriveSort: String, CaseIterable, Identifiable, Sendable {
    case title, contentModified = "content_modified", size, kind

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: "Name"
        case .contentModified: "Date Modified"
        case .size: "Size"
        case .kind: "Kind"
        }
    }

    /// Dates and sizes read best newest or largest first.
    var ascending: Bool { self == .title || self == .kind }
}
