import Foundation
import SocketIO

/// The media server's socket.io channel: requests that get a reply, notices that do not, and the server's events.
///
/// Every reply is `{success, error?, code?, ...}`. A reply with `success: false` throws `CallError.refused`.
final class CallSignal: @unchecked Sendable {
    private let manager: SocketManager
    private let socket: SocketIOClient
    private let token: String
    /// Socket events run here, never on the main thread, so a reply can arrive while mediasoup waits for it.
    private let queue = DispatchQueue(label: "io.frappe.suite.call.signal")

    init(url: URL, path: String, token: String) {
        self.token = token
        manager = SocketManager(socketURL: url, config: [
            .path(path), .forceWebsockets(true), .reconnects(false), .handleQueue(queue), .log(false),
        ])
        socket = manager.defaultSocket
    }

    func connect(timeout: TimeInterval = 20) async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                socket.once(clientEvent: .connect) { _, _ in
                    once.run { continuation.resume() }
                }
                socket.once(clientEvent: .error) { data, _ in
                    once.run { continuation.resume(throwing: CallError.unreachable("\(data.first ?? "")")) }
                }
                // The server reads the token from the handshake's `auth`, which socket.io calls the payload.
                socket.connect(withPayload: ["token": token], timeoutAfter: timeout) {
                    once.run { continuation.resume(throwing: CallError.unreachable("The media server did not answer.")) }
                }
            }
        }
    }

    func request(_ event: String, _ payload: JSONValue = [:]) async throws -> JSONValue {
        let reply = try await ask(event, payload)
        if reply["success"]?.bool == false {
            throw CallError.refused(event, reply["error"]?.string ?? reply["code"]?.string ?? "Refused")
        }
        return reply
    }

    /// Sends a request and returns the reply, refused or not.
    func ask(_ event: String, _ payload: JSONValue) async throws -> JSONValue {
        let reply: JSONValue = try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                socket.emitWithAck(event, with: [payload.foundation as! SocketData]).timingOut(after: 15) { data in
                    guard let first = data.first, (first as? String) != SocketAckStatus.noAck.rawValue,
                          let reply = try? JSONValue(foundation: first) else {
                        continuation.resume(throwing: CallError.refused(event, "No reply from the media server."))
                        return
                    }
                    continuation.resume(returning: reply)
                }
            }
        }
        return reply
    }

    /// Sends an event the server does not answer.
    func notify(_ event: String, _ payload: JSONValue) {
        queue.async { [self] in socket.emit(event, with: [payload.foundation as! SocketData], completion: nil) }
    }

    /// Calls `handler` on the main actor for each `event` the server sends.
    func on(_ event: String, _ handler: @escaping @MainActor (JSONValue) -> Void) {
        queue.async { [self] in
            socket.on(event) { data, _ in
                let value = data.first.flatMap { try? JSONValue(foundation: $0) } ?? .null
                Task { @MainActor in handler(value) }
            }
        }
    }

    /// Calls `handler` once the socket closes, for any reason but `disconnect()`.
    func onDrop(_ handler: @escaping @MainActor () -> Void) {
        queue.async { [self] in
            socket.on(clientEvent: .disconnect) { _, _ in Task { @MainActor in handler() } }
        }
    }

    func disconnect() {
        queue.async { [self] in
            socket.removeAllHandlers()
            socket.disconnect()
            manager.disconnect()
        }
    }
}

enum CallError: LocalizedError {
    case unreachable(String)
    case refused(String, String)
    case media(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let reason): "Could not reach the meeting. \(reason)"
        case .refused(_, let reason): reason
        case .media(let reason): reason
        }
    }
}

/// Runs its first block and ignores the rest, for continuations several events may resume.
private final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func run(_ block: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { block() }
    }
}
