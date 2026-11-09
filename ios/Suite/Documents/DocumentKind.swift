import SwiftUI

/// The Suite document types Drive can hold, named the way the web app names them.
enum DocumentKind: String, CaseIterable, Identifiable, Sendable {
    case writer = "Writer Document"
    case sheet = "Sheet"
    case slides = "Presentation"
    case draw = "Drawing"

    var id: String { rawValue }

    /// The server's `content_doctype`.
    var contentDoctype: String { rawValue }

    init?(_ node: DriveNode) {
        guard node.kind == .document, let doctype = node.contentDoctype else { return nil }
        self.init(rawValue: doctype)
    }

    var label: String {
        switch self {
        case .writer: "Document"
        case .sheet: "Spreadsheet"
        case .slides: "Presentation"
        case .draw: "Drawing"
        }
    }

    var untitled: String { "Untitled \(label.lowercased())" }

    var fileType: FileType {
        switch self {
        case .writer: .doc
        case .sheet: .sheet
        case .slides: .slides
        case .draw: .draw
        }
    }

    /// The kind's duotone icon and the web app's color for it.
    var image: Image { fileType.image }
    var color: Color { fileType.color }

    /// The kind's name beside its icon, for menus.
    var menuLabel: some View {
        Label { Text(label) } icon: { image }
    }
}

extension DriveClient {
    /// Creates an empty document. The server adds a number if the title is taken.
    func createDocument(_ kind: DocumentKind, in folder: String) async throws -> DriveNode {
        try await api.call("POST", path("nodes"), body: NewDocument(
            parentNode: folder, title: kind.untitled, contentDoctype: kind.contentDoctype
        ))
    }
}

private struct NewDocument: Encodable, Sendable {
    let kind = "document"
    let parentNode: String
    let title: String
    let contentDoctype: String
    let deduplicateTitle = true
}
