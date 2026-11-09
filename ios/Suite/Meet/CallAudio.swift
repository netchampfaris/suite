import AVFoundation
import CallKit
import os
import WebRTC

/// Reports the call to iOS through CallKit, so its audio keeps going in the background and it can be muted
/// or ended from the lock screen and the status bar.
///
/// Where CallKit is not available, such as in the simulator, WebRTC runs the audio session itself.
@MainActor
final class CallAudio: NSObject {
    /// The person muted or unmuted from the system's call screen, or the app asked CallKit to.
    var onMute: ((Bool) -> Void)?
    /// iOS ended the call, such as from the lock screen or for a phone call.
    var onEnd: (() -> Void)?

    private let provider: CXProvider
    private let controller = CXCallController()
    private let uuid = UUID()
    private var usesCallKit = false
    private var isEnding = false

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func start(title: String) async {
        let session = RTCAudioSession.sharedInstance()
        // CallKit activates the audio session, so WebRTC waits for it.
        session.useManualAudio = true
        session.isAudioEnabled = false
        Self.configure(session)
        let start = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: title))
        start.isVideo = true
        do {
            try await controller.request(CXTransaction(action: start))
            usesCallKit = true
            provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
        } catch {
            Logger(subsystem: "io.frappe.suite", category: "call").info("CallKit unavailable: \(error.localizedDescription, privacy: .public)")
            session.useManualAudio = false
            session.isAudioEnabled = true
        }
    }

    func connected() {
        if usesCallKit { provider.reportOutgoingCall(with: uuid, connectedAt: nil) }
    }

    /// Mutes through CallKit, so the system's call screen agrees. Without it, mutes directly.
    func setMuted(_ muted: Bool) {
        guard usesCallKit else { return onMute?(muted) ?? () }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: muted))) { [weak self] error in
            if error != nil { Task { @MainActor in self?.onMute?(muted) } }
        }
    }

    func end() {
        isEnding = true
        if usesCallKit {
            controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
        }
        let session = RTCAudioSession.sharedInstance()
        session.isAudioEnabled = false
        session.useManualAudio = false
    }

    /// iOS ended the call. A provider that never took the call, as in the simulator, resets on its own.
    private func endedBySystem() {
        if usesCallKit && !isEnding { onEnd?() }
    }

    /// Voice chat with the speaker on, as for a video call.
    private static func configure(_ session: RTCAudioSession) {
        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.mode = AVAudioSession.Mode.videoChat.rawValue
        configuration.categoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
        RTCAudioSessionConfiguration.setWebRTC(configuration)
        session.lockForConfiguration()
        try? session.setConfiguration(configuration)
        session.unlockForConfiguration()
    }
}

extension CallAudio: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated { endedBySystem() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        MainActor.assumeIsolated { endedBySystem() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let muted = action.isMuted
        action.fulfill()
        MainActor.assumeIsolated { onMute?(muted) }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        let session = RTCAudioSession.sharedInstance()
        session.audioSessionDidActivate(audioSession)
        session.isAudioEnabled = true
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        let session = RTCAudioSession.sharedInstance()
        session.audioSessionDidDeactivate(audioSession)
        session.isAudioEnabled = false
    }
}
