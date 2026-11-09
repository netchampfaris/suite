import SwiftUI

/// What Drive draws a node as, matching the web app's `FileType`: each type has one duotone icon,
/// copied from the web by `scripts/import-icons.py`, and one ink color.
enum FileType: String, Sendable {
    case folder, doc, sheet, slides, draw, pdf, image, video, audio, text, csv, code, archive, file, link

    init(_ node: DriveNode) {
        switch node.kind {
        case .folder, .root: self = .folder
        case .link: self = .link
        case .document: self = (DocumentKind(node) ?? .writer).fileType
        case .file, .unknown: self = Self.stored(title: node.title, mime: node.mime ?? "")
        }
    }

    var image: Image { Image("file-\(rawValue)") }

    /// Suite's own documents, PDFs and media have a color, as on the web; everything else is gray.
    var color: Color {
        switch self {
        case .doc: .blue
        case .sheet: .green
        case .slides: .orange
        case .draw, .video: .pink
        case .pdf: .red
        case .image: .purple
        case .audio: .cyan
        case .folder, .text, .csv, .code, .archive, .file, .link: .secondary
        }
    }

    /// Text formats rarely have a telling MIME type, so the extension decides, as it does on the web.
    private static func stored(title: String, mime: String) -> FileType {
        let mime = mime.lowercased()
        let ext = title.split(separator: ".").count > 1 ? title.split(separator: ".").last.map { $0.lowercased() } : nil
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("video/") { return .video }
        if mime.hasPrefix("audio/") { return .audio }
        if mime == "application/pdf" || ext == "pdf" { return .pdf }
        if ext == "csv" || ext == "tsv" || mime == "text/csv" { return .csv }
        if let ext, ["html", "js", "ts", "json", "css", "scss", "py", "sql", "xml", "yaml", "yml"].contains(ext) { return .code }
        if mime.hasPrefix("text/") || ext == "md" || ext == "txt" { return .text }
        if mime.contains("zip") || mime.contains("compressed") { return .archive }
        return .file
    }
}
