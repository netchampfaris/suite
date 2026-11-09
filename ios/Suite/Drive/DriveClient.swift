import Foundation

/// The Drive routes the app uses, typed. Every path sits under `/api/suite/drive/`.
struct DriveClient: Sendable {
    /// The discovery views the server offers, besides a folder's own children.
    enum View: String, Sendable {
        case recents, favourites, shared, trash, search
    }

    let api: APIClient

    func roots() async throws -> RootLocations {
        try await api.call("GET", path("roots"))
    }

    func children(of folder: String, sort: DriveSort, cursor: String?) async throws -> Page<DriveNode> {
        var query = ["expand": "preview", "order_by": sort.rawValue, "ascending": sort.ascending ? "1" : "0"]
        query["cursor"] = cursor
        return try await api.call("GET", path("nodes/\(folder)/children"), query: query)
    }

    func view(_ view: View, root: String? = nil, term: String? = nil, cursor: String?) async throws -> Page<DriveNode> {
        var query = ["expand": "preview"]
        query["root"] = root
        query["term"] = term
        query["cursor"] = cursor
        return try await api.call("GET", path("views/\(view.rawValue)"), query: query)
    }

    func createFolder(in parent: String, title: String) async throws -> DriveNode {
        try await api.call("POST", path("nodes"), body: CreateFolder(parentNode: parent, title: title))
    }

    func rename(_ node: String, to title: String) async throws -> DriveNode {
        try await api.call("PATCH", path("nodes/\(node)"), body: ["title": title])
    }

    func trash(_ node: String) async throws -> DriveNode {
        try await api.call("PATCH", path("nodes/\(node)"), body: ["state": "Trashed"])
    }

    func restore(_ node: String) async throws -> DriveNode {
        try await api.call("PATCH", path("nodes/\(node)"), body: ["state": "Active"])
    }

    func purge(_ node: String) async throws {
        let _: Count = try await api.call("DELETE", path("nodes/\(node)"))
    }

    func setFavourite(_ node: String, _ on: Bool) async throws {
        let _: Count = try await api.call(on ? "PUT" : "DELETE", path("nodes/\(node)/favourite"))
    }

    /// A file's bytes, or a document's default export, saved under its own title.
    func download(_ node: DriveNode) async throws -> URL {
        let (temporary, response) = try await api.download(path("nodes/\(node.name)/content"))
        let filename = response.suggestedFilename.flatMap { $0 == "Unknown" ? nil : $0 } ?? node.title
        let folder = FileManager.default.temporaryDirectory.appending(path: node.name, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: filename)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// The folders above a node, from the highest one the person can read down to its parent.
    func breadcrumbs(of node: String) async throws -> [Breadcrumb] {
        let answer: WithBreadcrumbs = try await api.call("GET", path("nodes/\(node)"), query: ["expand": "breadcrumbs"])
        return answer.breadcrumbs ?? []
    }

    /// A node and the folders above it, for opening a node that a link names.
    func locate(_ node: String) async throws -> (node: DriveNode, trail: [Breadcrumb]) {
        let answer: Located = try await api.call("GET", path("nodes/\(node)"), query: ["expand": "breadcrumbs"])
        return (answer.node, answer.trail)
    }

    func path(_ route: String) -> String {
        "api/suite/drive/\(route)"
    }
}

private struct WithBreadcrumbs: Decodable, Sendable {
    let breadcrumbs: [Breadcrumb]?
}

private struct Located: Decodable, Sendable {
    let node: DriveNode
    let trail: [Breadcrumb]

    init(from decoder: any Decoder) throws {
        node = try DriveNode(from: decoder)
        trail = try WithBreadcrumbs(from: decoder).breadcrumbs ?? []
    }
}

private struct CreateFolder: Encodable, Sendable {
    let kind = "folder"
    let parentNode: String
    let title: String
}

private struct Count: Decodable, Sendable {
    let count: Int
}
