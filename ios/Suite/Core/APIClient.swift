import Foundation

/// A refusal from a Frappe site, carrying the server's error type when it sent one.
struct APIError: LocalizedError, Equatable {
    let type: String
    let message: String
    let status: Int

    var errorDescription: String? { message }

    /// The site says the session is no longer valid, as opposed to failing for another reason.
    var endsSession: Bool { type == "AuthenticationError" || status == 401 || status == 403 }

    static let unreadable = APIError(type: "BadResponse", message: "The server sent a reply Suite could not read.", status: 0)
}

/// Talks to one Frappe site over its session cookie.
///
/// Requests go through `URLSession`'s shared cookie store, so the `sid` cookie that
/// `/api/method/login` sets is sent on every later call and survives relaunch.
///
/// A session that only signed in through the API needs no CSRF token. Once a web
/// view opens a page with the same cookie, the session has one and every unsafe
/// request must send it, so this fetches the token the first time a request is
/// refused for lacking it.
final class APIClient: Sendable {
    let site: URL
    private let session: URLSession
    private let csrf = CSRFToken()

    init(site: URL, session: URLSession = .shared) {
        self.site = site
        self.session = session
    }

    /// Calls a v2 route and unwraps its `{"data": ...}` envelope.
    func call<Output: Decodable & Sendable>(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: (any Encodable & Sendable)? = nil,
        decoder: JSONDecoder = .api
    ) async throws -> Output {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder.api.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await envelope(of: request, decoder: decoder)
    }

    /// Sends raw bytes, for upload chunks.
    func put<Output: Decodable & Sendable>(_ path: String, query: [String: String], bytes: Data) async throws -> Output {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = bytes
        return try await envelope(of: request, decoder: .api)
    }

    /// Sends a v1 form post, which is how Frappe's login method takes credentials.
    func postForm(_ path: String, fields: [String: String]) async throws -> Data {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = form.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)
        return try await send(request)
    }

    func get(_ path: String) async throws -> Data {
        try await send(URLRequest(url: url(path)))
    }

    /// Downloads to a temporary file, following redirects to signed storage URLs.
    func download(_ path: String) async throws -> (URL, URLResponse) {
        try await download(from: url(path))
    }

    /// Downloads an absolute URL on the site, such as one the server built with its query.
    func download(from url: URL) async throws -> (URL, URLResponse) {
        let (file, response) = try await session.download(for: URLRequest(url: url))
        try Self.check(response, body: (try? Data(contentsOf: file)) ?? Data())
        return (file, response)
    }

    /// Resolves a site-relative URL such as a preview's `/f/...` address.
    func resolve(_ reference: String) -> URL? {
        URL(string: reference, relativeTo: site)?.absoluteURL
    }

    func url(_ path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: site.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    private func envelope<Output: Decodable>(of request: URLRequest, decoder: JSONDecoder) async throws -> Output {
        let data = try await send(request)
        do {
            return try decoder.decode(Envelope<Output>.self, from: data).data
        } catch {
            throw APIError.unreadable
        }
    }

    /// Posts one file as a multipart form, the way Frappe's upload methods take it.
    func upload<Output: Decodable & Sendable>(_ dotted: String, file: URL, fields: [String: String] = [:]) async throws -> Output {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        let filename = file.lastPathComponent.replacingOccurrences(of: "\"", with: "")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(try Data(contentsOf: file))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url("api/method/" + dotted))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        let data = try await send(request)
        do {
            return try JSONDecoder.api.decode(Message<Output>.self, from: data).message
        } catch {
            throw APIError.unreadable
        }
    }

    /// Calls a whitelisted v1 method and unwraps its `{"message": ...}` envelope.
    func method<Output: Decodable & Sendable>(_ dotted: String, body: (any Encodable & Sendable)? = nil) async throws -> Output {
        var request = URLRequest(url: url("api/method/" + dotted))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder.api.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data = try await send(request)
        do {
            return try JSONDecoder.api.decode(Message<Output>.self, from: data).message
        } catch {
            throw APIError.unreadable
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            return try await sendOnce(request)
        } catch let error as APIError where error.type == "CSRFTokenError" {
            let boot: Boot = try await method("suite.www.suite.get_boot_data")
            await csrf.set(boot.csrfToken)
            return try await sendOnce(request)
        }
    }

    private func sendOnce(_ request: URLRequest) async throws -> Data {
        var request = request
        if !["GET", "HEAD"].contains(request.httpMethod ?? "GET"), let token = await csrf.value {
            request.setValue(token, forHTTPHeaderField: "X-Frappe-CSRF-Token")
        }
        let (data, response) = try await session.data(for: request)
        try Self.check(response, body: data)
        return data
    }

    private static func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.unreadable }
        guard !(200..<300).contains(http.statusCode) else { return }
        throw refusal(from: body, status: http.statusCode)
    }

    /// Reads either envelope: v2's `errors` list, or v1's `exc_type` and `message`.
    static func refusal(from body: Data, status: Int) -> APIError {
        let reply = try? JSONDecoder().decode(ErrorReply.self, from: body)
        if let first = reply?.errors?.first {
            return APIError(type: first.type ?? "Error", message: first.message ?? fallback(status), status: status)
        }
        return APIError(
            type: reply?.excType ?? "HTTP\(status)",
            message: reply?.message ?? reply?.serverMessage ?? fallback(status),
            status: status
        )
    }

    private static func fallback(_ status: Int) -> String {
        HTTPURLResponse.localizedString(forStatusCode: status).capitalized
    }
}

private struct Envelope<T: Decodable>: Decodable {
    let data: T
}

private struct Message<T: Decodable>: Decodable {
    let message: T

    /// Frappe leaves `message` out when a method returns nothing, which an optional reads as nil.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if !container.contains(.message), let nothing = (T.self as? ExpressibleByNilLiteral.Type)?.init(nilLiteral: ()) as? T {
            message = nothing
        } else {
            message = try container.decode(T.self, forKey: .message)
        }
    }

    private enum CodingKeys: String, CodingKey { case message }
}

private struct Boot: Decodable, Sendable {
    let csrfToken: String
}

private actor CSRFToken {
    private(set) var value: String?
    func set(_ token: String) { value = token }
}

private struct ErrorReply: Decodable {
    struct Entry: Decodable {
        let type: String?
        let message: String?
    }

    let errors: [Entry]?
    let excType: String?
    let message: String?
    let serverMessages: String?

    /// The first message `frappe.throw` raised. v1 sends them as a JSON list of JSON-encoded objects.
    var serverMessage: String? {
        guard let list = serverMessages?.data(using: .utf8),
              let entries = try? JSONDecoder().decode([String].self, from: list),
              let first = entries.first?.data(using: .utf8)
        else { return nil }
        return (try? JSONDecoder().decode(Entry.self, from: first))?.message
    }

    enum CodingKeys: String, CodingKey {
        case errors, message
        case serverMessages = "_server_messages"
        case excType = "exc_type"
    }
}

extension JSONDecoder {
    static let api: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let api: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
}
