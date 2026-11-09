import AVFoundation
import Observation
import os
import WebRTC

/// A meeting to join.
struct CallRoute: Hashable {
    /// The title of a meeting known only by its code.
    static let untitled = "Meeting"

    let code: String
    let title: String
}

/// One meeting call: joins the room, sends the microphone and camera, and keeps everyone's tiles current.
///
/// The steps follow the web app's client: join the room over the media server's socket, load its codecs,
/// open a send and a receive transport, then receive what everyone already sends and send the microphone.
@MainActor
@Observable
final class Call {
    enum Phase: Equatable {
        case connecting
        /// The room is restricted and a host has not let the person in yet.
        case waiting
        case live
        /// The room is end-to-end encrypted, which only the web app can join.
        case encrypted
        /// Over. `reason` says why when the person did not leave themselves.
        case ended(reason: String?)
    }

    struct Person: Identifiable {
        let id: String
        var name: String
        var isMuted = true
        var isCameraOn = false
        var isSpeaking = false
        var camera: RTCVideoTrack?
        var screen: RTCVideoTrack?

        /// A shared screen shows over the camera, as it is what the person wants seen.
        var video: RTCVideoTrack? { screen ?? (isCameraOn ? camera : nil) }
    }

    let route: CallRoute
    /// The route's title, or the room's own when the route came from a link.
    private(set) var title: String
    let myName: String
    private(set) var phase = Phase.connecting
    /// Everyone else, in the order they joined.
    private(set) var people: [Person] = []
    private(set) var isMuted = false
    /// The person's own camera, for their tile.
    private(set) var camera: RTCVideoTrack?
    private(set) var isFrontCamera = true
    var error: String?
    /// Told when the call ends, with the reason when the person did not leave themselves.
    var onEnd: ((String?) -> Void)?

    private let server: MeetServer
    private let audio = CallAudio()
    private let connectionID = UUID().uuidString
    private var signal: CallSignal?
    private var media: CallMedia?
    private var me = ""
    private var capabilities = JSONValue.null
    private var receiveTransport = ""
    /// What is received from each producer, so a closed one clears the right tile.
    private var received: [String: Received] = [:]
    private var refresh: Task<Void, Never>?

    private static let log = Logger(subsystem: "io.frappe.suite", category: "call")

    private struct Received {
        var consumer = ""
        let person: String
        let isVideo: Bool
        let isScreen: Bool
    }

    init(route: CallRoute, server: MeetServer, myName: String) {
        self.route = route
        self.title = route.title
        self.server = server
        self.myName = myName
        audio.onMute = { [weak self] muted in Task { await self?.applyMute(muted) } }
        audio.onEnd = { [weak self] in self?.finish(reason: nil) }
    }

    var isOver: Bool {
        if case .ended = phase { true } else { phase == .encrypted }
    }

    var isCameraOn: Bool { camera != nil }

    // MARK: Joining

    func start() async {
        if route.title == CallRoute.untitled, let title = await server.title(route.code) { self.title = title }
        do {
            guard let connection = try await admit() else { return }
            if connection.e2eeRequired == true {
                phase = .encrypted
                return
            }
            try await connect(connection)
            if !isOver {
                phase = .live
                audio.connected()
            }
        } catch {
            finish(reason: error.localizedDescription)
        }
    }

    /// Joins, or waits in the lobby until a host lets the person in.
    private func admit() async throws -> CallConnection? {
        switch try await server.join(route.code) {
        case .joined(let connection):
            return connection
        case .waiting:
            phase = .waiting
            while phase == .waiting {
                try await Task.sleep(for: .seconds(3))
                // The answer arrives on the site's own socket. Asking again is simpler, and only works once admitted.
                if let connection = try? await server.connection(route.code) {
                    phase = .connecting
                    return connection
                }
            }
            return nil
        }
    }

    private func connect(_ connection: CallConnection) async throws {
        guard let socket = connection.socket else { throw CallError.unreachable("The meeting has no media server.") }
        me = connection.userId
        let signal = CallSignal(url: socket.url, path: socket.path, token: connection.authToken)
        let media = CallMedia(signal: signal)
        media.onFailure = { Task { @MainActor [weak self] in self?.finish(reason: "The connection to the meeting was lost.") } }
        self.signal = signal
        self.media = media
        listen(to: signal)
        await audio.start(title: title)

        try await signal.connect()
        try await joinRoom(connection)
        let router = try await signal.request("get_router_rtp_capabilities")
        capabilities = try await media.load(router["rtpCapabilities"] ?? .null)
        async let sending = signal.request("create_webrtc_transport", ["direction": "send", "encryptionEnabled": false])
        async let receiving = signal.request("create_webrtc_transport", ["direction": "recv", "encryptionEnabled": false])
        try await media.open(send: sending, receive: receiving)
        receiveTransport = await media.receiveTransportID

        let participants = try await signal.request("get_room_participants")
        for row in participants["participants"]?.array ?? [] {
            if let id = row["user_id"]?.string ?? row["id"]?.string { add(id, row["info"]) }
        }
        let existing = try await signal.request("get_existing_producers")
        for producer in existing["producers"]?.array ?? [] { await receive(producer, idKey: "id", personKey: "user_id") }
        // Joining a large room muted spares everyone the noise, as the web app does.
        try await startMicrophone(muted: people.count >= 5)
        keepTokenFresh(connection)
    }

    private func joinRoom(_ connection: CallConnection, takingOver conflict: String? = nil) async throws {
        guard let signal else { return }
        var request: [String: JSONValue] = [
            "roomId": .string(connection.meetingId),
            "connectionId": .string(connectionID),
            "userData": [
                "name": .string(connection.userData.name),
                "userId": .string(connection.userId),
                "avatar": connection.userData.avatar.map { .string($0) } ?? .null,
                "is_guest": false,
                "isHost": .bool(connection.isHost ?? false),
            ],
            "mediaState": ["audio_enabled": false, "video_enabled": false],
            "e2ee": ["enabled": false, "capability": ["supported": false, "mode": "none"]],
        ]
        if let conflict { request["conflictId"] = .string(conflict) }
        let reply = try await signal.ask("join_room", .object(request))
        if reply["success"]?.bool == true { return }
        // The person is already in the room on another device. Joining here moves them, as they asked to join.
        if conflict == nil, reply["code"]?.string == "PARTICIPANT_CONNECTION_CONFLICT",
           let id = reply["details"]?["conflictId"]?.string {
            return try await joinRoom(connection, takingOver: id)
        }
        throw CallError.refused("join_room", reply["error"]?.string ?? "Could not join the meeting.")
    }

    private func keepTokenFresh(_ connection: CallConnection) {
        let lifetime = Double(connection.expiresIn ?? 3600)
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(60, lifetime - 60)))
                guard let self, !Task.isCancelled, let token = try? await server.refreshToken(route.code) else { continue }
                _ = try? await signal?.request("auth:update_token", ["token": .string(token)])
            }
        }
    }

    // MARK: The person's controls

    /// Mutes through CallKit, which then calls `applyMute`, so the system's call screen agrees.
    func setMuted(_ muted: Bool) {
        audio.setMuted(muted)
    }

    private func applyMute(_ muted: Bool) async {
        isMuted = muted
        guard let signal, let id = try? await media?.setMicrophone(on: !muted) else { return }
        // Pausing only tells recorders; everyone else learns from `media_control`.
        _ = try? await signal.request(muted ? "pause_producer" : "resume_producer", ["producerId": .string(id)])
        signal.notify("media_control", ["action": muted ? "mute" : "unmute"])
    }

    private func startMicrophone(muted: Bool) async throws {
        guard let media, let signal else { return }
        _ = try await media.startMicrophone()
        if muted {
            await applyMute(true)
        } else {
            signal.notify("media_control", ["action": "unmute"])
        }
    }

    func setCamera(_ on: Bool) async {
        guard let media, let signal else { return }
        do {
            if on {
                guard await AVCaptureDevice.requestAccess(for: .video) else {
                    throw CallError.media("Suite has no access to the camera. You can allow it in Settings.")
                }
                let started = try await media.startCamera()
                camera = started.track.value
                isFrontCamera = true
                signal.notify("media_control", ["action": "video_on"])
            } else {
                camera = nil
                // The camera's producer is closed, not paused, as the web app does.
                if let id = try await media.stopCamera() {
                    _ = try? await signal.request("close_producer", ["producerId": .string(id)])
                }
                signal.notify("media_control", ["action": "video_off"])
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func switchCamera() async {
        do {
            try await media?.switchCamera()
            isFrontCamera.toggle()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func leave() {
        finish(reason: nil)
    }

    private func finish(reason: String?) {
        guard !isOver else { return }
        Self.log.info("Call \(self.route.code, privacy: .public) ended: \(reason ?? "left", privacy: .public)")
        phase = .ended(reason: reason)
        refresh?.cancel()
        // Closing the socket is how the web app leaves. The server tells everyone else.
        signal?.disconnect()
        media?.close()
        audio.end()
        camera = nil
        onEnd?(reason)
    }

    // MARK: The room's events

    private func listen(to signal: CallSignal) {
        signal.on("participant_joined") { [weak self] event in
            if let id = event["participantId"]?.string { self?.add(id, event["userData"]) }
        }
        signal.on("participant_updated") { [weak self] event in
            if let id = event["participantId"]?.string { self?.add(id, event["userData"]) }
        }
        signal.on("participant_left") { [weak self] event in
            self?.people.removeAll { $0.id == event["participantId"]?.string }
        }
        signal.on("producer_created") { [weak self] event in
            Task { await self?.receive(event, idKey: "producerId", personKey: "participantId") }
        }
        signal.on("producer_closed") { [weak self] event in
            if let id = event["producerId"]?.string { self?.drop(producer: id) }
        }
        signal.on("consumer_closed") { [weak self] event in
            guard let self, let id = event["consumerId"]?.string,
                  let producer = received.first(where: { $0.value.consumer == id })?.key else { return }
            drop(producer: producer)
        }
        signal.on("media_control_update") { [weak self] event in
            guard let id = event["participantId"]?.string else { return }
            switch event["action"]?.string {
            case "mute": self?.update(id) { $0.isMuted = true }
            case "unmute": self?.update(id) { $0.isMuted = false }
            case "video_off": self?.update(id) { $0.isCameraOn = false }
            case "video_on": self?.update(id) { $0.isCameraOn = true }
            default: break
            }
        }
        signal.on("active_speaker") { [weak self] event in
            let speaking = Set((event["participantIds"]?.array ?? []).compactMap(\.string))
            guard let self else { return }
            for index in people.indices where people[index].isSpeaking != speaking.contains(people[index].id) {
                people[index].isSpeaking.toggle()
            }
        }
        signal.on("host_control_update") { [weak self] event in
            guard let self, event["targetParticipantId"]?.string == me else { return }
            switch event["action"]?.string {
            case "mute_participant": setMuted(true)
            case "kick_participant", "ban_participant": finish(reason: "A host removed you from the meeting.")
            default: break
            }
        }
        signal.on("participant_connection_replaced") { [weak self] _ in
            self?.finish(reason: "You joined this meeting from another device.")
        }
        signal.on("producer:camera_layers") { [weak self] event in
            guard let id = event["producerId"]?.string, let layer = event["maxSpatialLayer"]?.number else { return }
            Task { await self?.media?.limitCamera(producerID: id, layer: Int(layer)) }
        }
        signal.onDrop { [weak self] in
            if self?.phase == .live { self?.finish(reason: "The connection to the meeting was lost.") }
        }
    }

    /// Adds someone, or updates them, from the server's `userData` or `info`.
    private func add(_ id: String, _ info: JSONValue?) {
        guard id != me else { return }
        let name = info?["name"]?.string ?? id
        let audio = info?["audio_enabled"]?.bool ?? false
        let video = info?["video_enabled"]?.bool ?? false
        if let index = people.firstIndex(where: { $0.id == id }) {
            people[index].name = name
            people[index].isMuted = !audio
            people[index].isCameraOn = video
        } else {
            people.append(Person(id: id, name: name, isMuted: !audio, isCameraOn: video))
        }
    }

    private func update(_ id: String, _ change: (inout Person) -> Void) {
        guard id != me else { return }
        if !people.contains(where: { $0.id == id }) { people.append(Person(id: id, name: id)) }
        if let index = people.firstIndex(where: { $0.id == id }) { change(&people[index]) }
    }

    /// Receives one producer, from `get_existing_producers` or `producer_created`.
    private func receive(_ producer: JSONValue, idKey: String, personKey: String) async {
        guard let signal, let media, let id = producer[idKey]?.string, let person = producer[personKey]?.string,
              person != me, received[id] == nil else { return }
        let isVideo = producer["kind"]?.string == "video"
        let isScreen = producer["isScreen"]?.bool ?? false
        received[id] = Received(person: person, isVideo: isVideo, isScreen: isScreen)
        do {
            let reply = try await signal.request("create_consumer", [
                "transportId": .string(receiveTransport), "producerId": .string(id),
                "rtpCapabilities": capabilities, "startPaused": true,
            ])
            let track = try await media.consume(reply)
            let consumer = reply["id"]?.string ?? ""
            received[id]?.consumer = consumer
            if isVideo, let video = track.value as? RTCVideoTrack {
                update(person) {
                    if isScreen { $0.screen = video } else { $0.camera = video; $0.isCameraOn = true }
                }
                // A tile is small, so the server can send a lower layer.
                _ = try? await signal.request("consumer:update_preferences", [
                    "consumerId": .string(consumer), "visible": true, "width": 640, "height": 360,
                ])
            }
            // The server resumes audio itself. Video waits for the client.
            if reply["paused"]?.bool == true {
                _ = try? await signal.request("resume_consumer", ["consumerId": .string(consumer)])
            }
        } catch {
            received[id] = nil
        }
    }

    private func drop(producer id: String) {
        guard let gone = received.removeValue(forKey: id) else { return }
        media?.closeConsumer(gone.consumer)
        // Someone who already left stays gone.
        guard gone.isVideo, let index = people.firstIndex(where: { $0.id == gone.person }) else { return }
        if gone.isScreen { people[index].screen = nil } else { people[index].camera = nil }
    }
}
