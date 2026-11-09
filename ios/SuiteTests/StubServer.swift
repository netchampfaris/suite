import Foundation
@testable import Suite

/// A fake site for tests. Each test sets `handler` to answer requests the client sends.
final class StubServer: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var body: Data
        /// Fails the request without a reply, as when the device is offline.
        var failure: URLError?

        static let offline = Reply(body: Data(), failure: URLError(.notConnectedToInternet))

        static func json(_ text: String, status: Int = 200) -> Reply {
            Reply(status: status, body: Data(text.utf8))
        }
    }

    nonisolated(unsafe) static var handler: (URLRequest, Data) -> Reply = { _, _ in .json("{}", status: 500) }
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func client(site: URL = URL(string: "https://suite.example.com/")!) -> APIClient {
        requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return APIClient(site: site, session: URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        Self.requests.append(request)
        let reply = Self.handler(request, body)
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

func node(_ name: String, title: String, kind: String = "file") -> String {
    """
    {"name":"\(name)","title":"\(title)","kind":"\(kind)","parent_node":"root1","root":"root1",
     "state":"Active","trash_root":null,"size":12,"mime":"text/plain","url":null,
     "content_doctype":null,"content_docname":null,"is_template":0,
     "owner":{"id":"a@example.com","full_name":"A","user_image":null},
     "creation":"2026-11-06T22:06:13Z","modified":"2026-11-06T22:06:13Z","content_modified":null,
     "favourite":false}
    """
}
