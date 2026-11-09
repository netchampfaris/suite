import Foundation

/// The Meet routes a call needs, under `/api/suite/meet/`.
struct MeetServer: Sendable {
    let api: APIClient

    enum Admission: Sendable {
        case joined(CallConnection)
        /// The room is restricted and a host has not let the person in yet.
        case waiting
    }

    /// Joins the room, or asks to, when it is restricted.
    func join(_ code: String) async throws -> Admission {
        let reply: JoinReply = try await api.call("POST", "api/suite/meet/rooms/joins", body: ["meeting_id": code])
        if reply.status == "waiting_for_approval" { return .waiting }
        return .joined(try JSONDecoder.api.decode(CallConnection.self, from: reply.raw))
    }

    /// How to reach the media server, once the person is a member of the room.
    func connection(_ code: String) async throws -> CallConnection {
        try await api.call("POST", "api/suite/meet/rooms/connections", body: ["meeting_id": code])
    }

    /// The room's title, for a call opened from a link, which only names the room's code.
    func title(_ code: String) async -> String? {
        let room: RoomTitle? = try? await api.call("GET", "api/v2/document/Meet Room/\(code)", query: ["fields": #"["title"]"#])
        return room?.title.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A new media server token, before the current one runs out.
    func refreshToken(_ code: String) async throws -> String {
        let reply: Token = try await api.call("POST", "api/suite/meet/rooms/tokens", body: ["meeting_id": code])
        return reply.authToken
    }
}

/// How to reach the media server for one room, and who the person is there.
struct CallConnection: Decodable, Sendable {
    struct Person: Decodable, Sendable {
        let name: String
        let avatar: String?
    }

    let sfuUrl: String
    let sfuPort: Int?
    let authToken: String
    let userId: String
    let meetingId: String
    let isHost: Bool?
    let e2eeRequired: Bool?
    let expiresIn: Int?
    let userData: Person

    /// The socket.io server and path, worked out the way the web app does.
    ///
    /// An `https` address is used as given, with its path as the socket.io prefix. A plain `http`
    /// address is a development server, reached on `sfu_port`.
    var socket: (url: URL, path: String)? {
        guard let address = URLComponents(string: sfuUrl), let host = address.host else { return nil }
        var origin = URLComponents()
        origin.scheme = address.scheme
        origin.host = host
        origin.port = address.scheme == "https" ? address.port : sfuPort
        let prefix = address.path.hasSuffix("/") ? String(address.path.dropLast()) : address.path
        return origin.url.map { ($0, prefix + "/socket.io") }
    }
}

/// The join reply, kept whole so a joined reply can be read as a connection.
private struct JoinReply: Decodable, Sendable {
    let status: String?
    let raw: Data

    init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        status = value["status"]?.string
        raw = Data(value.text.utf8)
    }
}

private struct RoomTitle: Decodable, Sendable {
    let title: String?
}

private struct Token: Decodable, Sendable {
    let authToken: String
}
