import AVFoundation
import Mediasoup
import WebRTC

/// The call's media: mediasoup's device and transports, the microphone and camera, and the tracks received.
///
/// mediasoup waits inside `createProducer` until the server names the new producer, and that answer comes
/// over the socket. So every call into mediasoup runs on `queue`, away from the main thread and the socket's.
final class CallMedia: @unchecked Sendable {
    /// What the person sends. The server keeps `cameraLayerDemand`, which lets it ask for fewer camera layers.
    enum Source: String {
        case microphone, camera
    }

    private let signal: CallSignal
    private let queue = DispatchQueue(label: "io.frappe.suite.call.media")
    private let factory = RTCPeerConnectionFactory(
        encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory()
    )
    private lazy var device = Device(pcFactory: factory)
    private var sendTransport: SendTransport?
    private var receiveTransport: ReceiveTransport?
    private var producers: [Source: Producer] = [:]
    private var consumers: [String: Consumer] = [:]
    private var capturer: RTCCameraVideoCapturer?
    private var position = AVCaptureDevice.Position.front
    /// Called when a transport fails, such as when the network drops.
    var onFailure: (@Sendable () -> Void)?

    init(signal: CallSignal) {
        self.signal = signal
    }

    // MARK: Setting up

    /// Loads the room's codecs and returns what this device can receive, which every consumer request names.
    func load(_ routerCapabilities: JSONValue) async throws -> JSONValue {
        let text = try await run { [self] in
            try device.load(with: routerCapabilities.text)
            return try device.rtpCapabilities()
        }
        return try JSONValue(text: text)
    }

    /// Opens the two transports from the server's `create_webrtc_transport` replies.
    func open(send: JSONValue, receive: JSONValue) async throws {
        try await run { [self] in
            let sending = try device.createSendTransport(
                id: send["id"]?.string ?? "", iceParameters: send["iceParameters"]?.text ?? "{}",
                iceCandidates: send["iceCandidates"]?.text ?? "[]", dtlsParameters: send["dtlsParameters"]?.text ?? "{}",
                sctpParameters: nil, appData: nil
            )
            sending.delegate = self
            sendTransport = sending
            let receiving = try device.createReceiveTransport(
                id: receive["id"]?.string ?? "", iceParameters: receive["iceParameters"]?.text ?? "{}",
                iceCandidates: receive["iceCandidates"]?.text ?? "[]", dtlsParameters: receive["dtlsParameters"]?.text ?? "{}"
            )
            receiving.delegate = self
            receiveTransport = receiving
        }
    }

    var receiveTransportID: String {
        get async { (try? await run { [self] in receiveTransport?.id ?? "" }) ?? "" }
    }

    // MARK: Sending

    /// Starts sending the microphone and returns its producer id.
    func startMicrophone() async throws -> String {
        try await run { [self] in
            guard let transport = sendTransport else { throw CallError.media("The call is not connected.") }
            let track = factory.audioTrack(with: factory.audioSource(with: nil), trackId: "microphone")
            let producer = try transport.createProducer(
                for: track, encodings: nil,
                codecOptions: #"{"opusStereo":false,"opusDtx":true,"opusFec":true,"opusMaxPlaybackRate":48000}"#,
                codec: nil, appData: #"{"type":"microphone"}"#
            )
            producers[.microphone] = producer
            return producer.id
        }
    }

    /// Pauses or resumes the microphone, and returns its producer id.
    func setMicrophone(on: Bool) async throws -> String? {
        try await run { [self] in
            guard let producer = producers[.microphone] else { return nil }
            producer.track.isEnabled = on
            if on { producer.resume() } else { producer.pause() }
            return producer.id
        }
    }

    /// Starts the camera and returns its producer id and the track for the person's own tile.
    func startCamera() async throws -> (id: String, track: Unchecked<RTCVideoTrack>) {
        try await run { [self] in
            guard let transport = sendTransport else { throw CallError.media("The call is not connected.") }
            let source = factory.videoSource()
            let capturer = RTCCameraVideoCapturer(delegate: source)
            try startCapture(capturer)
            self.capturer = capturer
            let track = factory.videoTrack(with: source, trackId: "camera")
            // Three layers, as the web app sends, so people on slow links get a smaller picture.
            let producer = try transport.createProducer(
                for: track,
                encodings: [Self.layer(120_000, scale: 4), Self.layer(500_000, scale: 2), Self.layer(1_800_000, scale: 1)],
                codecOptions: #"{"videoGoogleStartBitrate":1000}"#,
                codec: nil, appData: #"{"type":"camera","cameraLayerDemand":true}"#
            )
            producers[.camera] = producer
            return (producer.id, Unchecked(track))
        }
    }

    /// Stops the camera and returns the producer id it had.
    func stopCamera() async throws -> String? {
        try await run { [self] in
            capturer?.stopCapture()
            capturer = nil
            let producer = producers.removeValue(forKey: .camera)
            producer?.close()
            return producer?.id
        }
    }

    func switchCamera() async throws {
        try await run { [self] in
            guard let capturer else { return }
            position = position == .front ? .back : .front
            try startCapture(capturer)
        }
    }

    /// The layer the server asked the camera to send at most, for people who only need a small picture.
    func limitCamera(producerID: String, layer: Int) async {
        _ = try? await run { [self] in
            guard let producer = producers[.camera], producer.id == producerID else { return }
            try producer.setMaxSpatialLayer(layer)
        }
    }

    // MARK: Receiving

    /// Receives a producer from the server's `create_consumer` reply, and returns its track.
    func consume(_ reply: JSONValue) async throws -> Unchecked<RTCMediaStreamTrack> {
        try await run { [self] in
            guard let transport = receiveTransport, let id = reply["id"]?.string,
                  let producerID = reply["producerId"]?.string else { throw CallError.media("The call is not connected.") }
            let consumer = try transport.consume(
                consumerId: id, producerId: producerID, kind: reply["kind"]?.string == "audio" ? .audio : .video,
                rtpParameters: reply["rtpParameters"]?.text ?? "{}", appData: nil
            )
            consumers[id] = consumer
            return Unchecked(consumer.track)
        }
    }

    func closeConsumer(_ id: String) {
        queue.async { [self] in consumers.removeValue(forKey: id)?.close() }
    }

    func close() {
        queue.async { [self] in
            capturer?.stopCapture()
            capturer = nil
            producers.values.forEach { $0.close() }
            consumers.values.forEach { $0.close() }
            producers = [:]
            consumers = [:]
            sendTransport?.close()
            receiveTransport?.close()
        }
    }

    // MARK: Helpers

    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private func startCapture(_ capturer: RTCCameraVideoCapturer) throws {
        let cameras = RTCCameraVideoCapturer.captureDevices()
        guard let camera = cameras.first(where: { $0.position == position }) ?? cameras.first else {
            throw CallError.media("This device has no camera.")
        }
        // The format nearest 720p, which is plenty for a tile and kind to the battery.
        let formats = RTCCameraVideoCapturer.supportedFormats(for: camera)
        guard let format = formats.min(by: { Self.distance($0) < Self.distance($1) }) else {
            throw CallError.media("The camera has no format to send.")
        }
        let fastest = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        capturer.startCapture(with: camera, format: format, fps: Int(min(30, fastest)))
    }

    private static func distance(_ format: AVCaptureDevice.Format) -> Int32 {
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return abs(size.width - 1280) + abs(size.height - 720)
    }

    private static func layer(_ bitrate: Int, scale: Double) -> RTCRtpEncodingParameters {
        let layer = RTCRtpEncodingParameters()
        layer.isActive = true
        layer.maxBitrateBps = NSNumber(value: bitrate)
        layer.scaleResolutionDownBy = NSNumber(value: scale)
        return layer
    }
}

extension CallMedia: SendTransportDelegate, ReceiveTransportDelegate {
    func onConnect(transport: any Transport, dtlsParameters: String) {
        let id = (transport as? SendTransport)?.id ?? (transport as? ReceiveTransport)?.id ?? ""
        let dtls = (try? JSONValue(text: dtlsParameters)) ?? .null
        Task { _ = try? await signal.request("connect_webrtc_transport", ["transportId": .string(id), "dtlsParameters": dtls]) }
    }

    func onConnectionStateChange(transport: any Transport, connectionState: TransportConnectionState) {
        if connectionState == .failed { onFailure?() }
    }

    func onProduce(
        transport: any Transport, kind: MediaKind, rtpParameters: String, appData: String,
        callback: @escaping (String?) -> Void
    ) {
        let id = (transport as? SendTransport)?.id ?? ""
        let payload: JSONValue = [
            "transportId": .string(id),
            "kind": kind == .audio ? "audio" : "video",
            "rtpParameters": (try? JSONValue(text: rtpParameters)) ?? .null,
            "appData": (try? JSONValue(text: appData)) ?? [:],
        ]
        let answer = Unchecked(callback)
        Task {
            let reply = try? await signal.request("create_producer", payload)
            answer.value(reply?["id"]?.string)
        }
    }

    func onProduceData(
        transport: any Transport, sctpParameters: String, label: String, protocol dataProtocol: String, appData: String,
        callback: @escaping (String?) -> Void
    ) {
        callback(nil)
    }
}

/// Carries a value that is not `Sendable` across a boundary where only one side uses it at a time.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
