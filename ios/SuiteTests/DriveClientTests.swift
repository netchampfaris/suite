import Foundation
import Testing
@testable import Suite

@Suite(.serialized)
struct DriveClientTests {
    @Test func listsAFolderPageAndItsCursor() async throws {
        StubServer.handler = { request, _ in
            #expect(request.url?.path == "/api/suite/drive/nodes/root1/children")
            return .json(#"{"data":{"rows":[\#(node("n1", title: "Notes.txt"))],"next_cursor":"c2"}}"#)
        }
        let drive = DriveClient(api: StubServer.client())

        let page = try await drive.children(of: "root1", sort: .contentModified, cursor: nil)

        #expect(page.rows.map(\.title) == ["Notes.txt"])
        #expect(page.nextCursor == "c2")
        let query = URLComponents(url: StubServer.requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "order_by", value: "content_modified")))
        #expect(query.contains(URLQueryItem(name: "ascending", value: "0")))
    }

    @Test func surfacesTheServersRefusal() async throws {
        StubServer.handler = { _, _ in
            .json(#"{"errors":[{"type":"DriveConflict","message":"A file named Notes.txt is already here"}]}"#, status: 409)
        }
        let drive = DriveClient(api: StubServer.client())

        let error = await #expect(throws: APIError.self) {
            try await drive.rename("n1", to: "Notes.txt")
        }

        #expect(error?.type == "DriveConflict")
        #expect(error?.message == "A file named Notes.txt is already here")
        #expect(StubServer.requests[0].httpMethod == "PATCH")
    }

    @Test func uploadsInChunksFromWhereTheServerSaysItIs() async throws {
        let size = Uploader.chunkBytes + 10
        let file = FileManager.default.temporaryDirectory.appending(path: "big-\(UUID()).bin")
        try Data(repeating: 7, count: size).write(to: file)
        var offsets: [String] = []
        StubServer.handler = { request, body in
            let path = request.url!.path
            if path.hasSuffix("/uploads") {
                return .json(#"{"data":{"mode":"chunked","upload_id":"u1"}}"#)
            }
            if path.hasSuffix("/chunk") {
                let offset = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                    .queryItems!.first { $0.name == "offset" }!.value!)!
                offsets.append(String(offset))
                return .json(#"{"data":{"upload_id":"u1","received":\#(offset + body.count)}}"#)
            }
            #expect(path.hasSuffix("/uploads/u1/finish"))
            return .json(#"{"data":\#(node("n9", title: file.lastPathComponent))}"#)
        }
        let uploader = Uploader(drive: DriveClient(api: StubServer.client()))

        let created = try await uploader.upload(file, into: "root1") { _ in }

        #expect(offsets == ["0", String(Uploader.chunkBytes)])
        #expect(created.name == "n9")
    }

    @Test func readsSiteAddressesThePersonTypes() {
        #expect(AppSession.siteURL(from: "suite.frappe.io")?.absoluteString == "https://suite.frappe.io/")
        #expect(AppSession.siteURL(from: " https://suite.frappe.io/app/drive ")?.absoluteString == "https://suite.frappe.io/")
        #expect(AppSession.siteURL(from: "http://127.0.0.1:8002")?.absoluteString == "http://127.0.0.1:8002/")
        #expect(AppSession.siteURL(from: "ftp://example.com") == nil)
        #expect(AppSession.siteURL(from: "") == nil)
    }
}
