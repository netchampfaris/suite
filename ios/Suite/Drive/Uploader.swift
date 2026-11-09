import Foundation
import UniformTypeIdentifiers

/// Sends one local file into a Drive folder through an upload session (§8.4).
///
/// The server answers each session with a mode. `chunked` takes the bytes through
/// Drive in pieces; `direct` hands back a storage form to post them to. Either way
/// the session finishes as a new node.
struct Uploader: Sendable {
    let drive: DriveClient

    static let chunkBytes = 4 * 1024 * 1024

    func upload(_ file: URL, into folder: String, progress: @Sendable (Double) -> Void) async throws -> DriveNode {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let filename = file.lastPathComponent
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let session: UploadSession = try await drive.api.call(
            "POST",
            drive.path("uploads"),
            body: StartUpload(parentNode: folder, filename: filename, size: size, mime: mime),
            // Storage form field names must arrive as sent, so no key conversion here.
            decoder: JSONDecoder()
        )
        switch session.mode {
        case .chunked:
            try await sendChunks(file, size: size, session: session.uploadId, progress: progress)
        case .direct:
            try await sendDirect(file, session: session)
            progress(1)
        }
        return try await drive.api.call(
            "POST",
            drive.path("uploads/\(session.uploadId)/finish"),
            body: FinishUpload(parentNode: folder, title: filename)
        )
    }

    private func sendChunks(_ file: URL, size: Int, session: String, progress: @Sendable (Double) -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var offset = 0
        // An empty file still needs one empty chunk so the server holds a blob.
        repeat {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            let bytes = try handle.read(upToCount: Self.chunkBytes) ?? Data()
            let reply: ChunkReply = try await drive.api.put(
                drive.path("uploads/\(session)/chunk"),
                query: ["offset": String(offset)],
                bytes: bytes
            )
            guard reply.received > offset || size == 0 else { throw APIError.unreadable }
            offset = reply.received
            progress(size == 0 ? 1 : Double(offset) / Double(size))
        } while offset < size
    }

    /// Posts the file to storage as a multipart form. The fields go first: S3 ignores any after the file.
    private func sendDirect(_ file: URL, session: UploadSession) async throws {
        guard let target = session.url.flatMap(URL.init(string:)) else { throw APIError.unreadable }
        let boundary = "suite-\(UUID().uuidString)"
        var body = Data()
        for (key, value) in session.fields ?? [:] {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\n\r\n")
        body.append(try Data(contentsOf: file))
        body.append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // Storage is another origin, so it gets no cookies.
        request.httpShouldHandleCookies = false
        let (_, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw APIError(type: "DriveDirectUploadFailed", message: "Storage refused the file.", status: 0)
        }
    }
}

private struct StartUpload: Encodable, Sendable {
    let parentNode: String
    let filename: String
    let size: Int
    let mime: String
}

private struct UploadSession: Decodable, Sendable {
    enum Mode: String, Decodable, Sendable { case chunked, direct }
    enum CodingKeys: String, CodingKey {
        case mode, url, fields
        case uploadId = "upload_id"
    }

    let uploadId: String
    let mode: Mode
    let url: String?
    let fields: [String: String]?
}

private struct ChunkReply: Decodable, Sendable {
    let received: Int
}

private struct FinishUpload: Encodable, Sendable {
    let parentNode: String
    let title: String
}

private extension Data {
    mutating func append(_ text: String) {
        append(Data(text.utf8))
    }
}
