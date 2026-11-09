import AVFoundation
import SwiftUI
import WebRTC

/// A meeting call: a tile for each person, and the camera, microphone and leave controls.
struct CallScreen: View {
    let call: Call

    @Environment(Workspace.self) private var workspace
    @State private var isSpeakerOn = true

    var body: some View {
        VStack(spacing: 12) {
            topBar
            content
            if !call.isOver { controls }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(Color(.systemGroupedBackground))
        .alert("Something went wrong", isPresented: Binding { call.error != nil } set: { _ in call.error = nil }) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(call.error ?? "")
        }
    }

    // MARK: Parts

    private var topBar: some View {
        HStack(spacing: 8) {
            square(call.isOver ? "Close" : "Minimize", systemImage: call.isOver ? "xmark" : "chevron.down") {
                if call.isOver { workspace.closeCall() } else { workspace.isShowingCall = false }
            }
            Text(call.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer()
            if call.phase == .live {
                square(isSpeakerOn ? "Speaker on" : "Speaker off", systemImage: isSpeakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill") {
                    isSpeakerOn.toggle()
                    route(toSpeaker: isSpeakerOn)
                }
            }
            ShareLink(item: link) {
                Image(systemName: "person.badge.plus")
                    .frame(width: 36, height: 36)
                    .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))
            }
            .accessibilityLabel("Invite")
        }
        .tint(.primary)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch call.phase {
        case .connecting:
            tiles.overlay { ProgressView("Joining…").padding().background(.thinMaterial, in: .rect(cornerRadius: 14)) }
        case .live:
            tiles
        case .waiting:
            message("Waiting to be let in", systemImage: "person.badge.clock",
                    detail: "A host of this meeting will let you in.")
        case .encrypted:
            message("Encrypted meeting", systemImage: "lock.fill",
                    detail: "This meeting is end-to-end encrypted, which the app cannot join yet. Join it in the browser.") {
                Button("Join in Browser") {
                    workspace.closeCall()
                    workspace.page = .meeting(call.route.code, title: call.title)
                }
                .buttonStyle(.pill)
            }
        case .ended(let reason):
            message("Call ended", systemImage: "phone.down.fill", detail: reason ?? "")
        }
    }

    private var tiles: some View {
        let count = call.people.count + 1
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: count > 1 ? 2 : 1)
        return GeometryReader { proxy in
            // Up to three rows fill the screen. More people scroll.
            let rows = CGFloat(min(3, (count + columns.count - 1) / columns.count))
            let height = max(140, (proxy.size.height - 10 * (rows - 1)) / rows)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    Tile(name: call.myName, label: "You", isMuted: call.isMuted, isSpeaking: false,
                         video: call.camera, isMirrored: call.isFrontCamera)
                        .frame(height: height)
                    ForEach(call.people) { person in
                        Tile(name: person.name, label: person.name, isMuted: person.isMuted, isSpeaking: person.isSpeaking,
                             video: person.video, isMirrored: false)
                            .frame(height: height)
                    }
                }
            }
            .scrollDisabled(rows * height <= proxy.size.height)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            control(call.isCameraOn ? "Turn camera off" : "Turn camera on",
                    systemImage: call.isCameraOn ? "video.fill" : "video.slash.fill", isOff: !call.isCameraOn) {
                Task { await call.setCamera(!call.isCameraOn) }
            }
            control(call.isMuted ? "Unmute" : "Mute", systemImage: call.isMuted ? "mic.slash.fill" : "mic.fill", isOff: call.isMuted) {
                call.setMuted(!call.isMuted)
            }
            control("Switch camera", systemImage: "arrow.triangle.2.circlepath.camera", isOff: false) {
                Task { await call.switchCamera() }
            }
            .disabled(!call.isCameraOn)
            Button { workspace.closeCall() } label: {
                Image(systemName: "phone.down.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.red, in: .rect(cornerRadius: 14))
            }
            .accessibilityLabel("Leave call")
        }
        .buttonStyle(.plain)
        .disabled(call.phase != .live)
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }

    // MARK: Helpers

    private func message(
        _ title: String, systemImage: String, detail: String, @ViewBuilder actions: () -> some View = { EmptyView() }
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        } actions: {
            actions()
        }
        .frame(maxHeight: .infinity)
    }

    private func control(_ label: String, systemImage: String, isOff: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                // An off control reads as pressed in, so its state shows without color.
                .foregroundStyle(isOff ? Color(.systemBackground) : .primary)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(isOff ? Color.primary : Color(.tertiarySystemFill), in: .rect(cornerRadius: 14))
        }
        .accessibilityLabel(label)
    }

    private func square(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))
        }
        .accessibilityLabel(label)
    }

    private func route(toSpeaker speaker: Bool) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.overrideOutputAudioPort(speaker ? .speaker : .none)
        session.unlockForConfiguration()
    }

    private var link: URL {
        workspace.account.site.appending(path: "meet/\(call.route.code)")
    }
}

/// One person in the call: their video, or their initial while the camera is off, and their name.
private struct Tile: View {
    let name: String
    let label: String
    let isMuted: Bool
    let isSpeaking: Bool
    let video: RTCVideoTrack?
    let isMirrored: Bool

    /// The avatar shows until the video's first frame arrives, so a tile is never blank.
    @State private var hasFrame = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground))
            if video == nil || !hasFrame {
                Avatar(name: name, size: 72)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let video {
                VideoView(track: video, isMirrored: isMirrored) { hasFrame = true }
                    .clipShape(.rect(cornerRadius: 18))
                    .opacity(hasFrame ? 1 : 0)
                    .onChange(of: ObjectIdentifier(video)) { hasFrame = false }
            }
            HStack(spacing: 4) {
                if isMuted { Image(systemName: "mic.slash.fill") }
                Text(label).lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(.thinMaterial, in: .capsule)
            .padding(10)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18).strokeBorder(Color.accentColor, lineWidth: isSpeaking ? 3 : 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Draws a WebRTC video track.
private struct VideoView: UIViewRepresentable {
    let track: RTCVideoTrack
    let isMirrored: Bool
    let onFirstFrame: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        context.coordinator.onFirstFrame = onFirstFrame
        if context.coordinator.track !== track {
            context.coordinator.track?.remove(view)
            track.add(view)
            context.coordinator.track = track
        }
        view.transform = isMirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(view)
    }

    final class Coordinator: NSObject, RTCVideoViewDelegate {
        var track: RTCVideoTrack?
        var onFirstFrame: (@MainActor () -> Void)?

        /// The view learns the video's size from its first frame.
        func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            let onFirstFrame = onFirstFrame
            Task { @MainActor in onFirstFrame?() }
        }
    }
}

/// Shown over the app while a call is minimized. Tapping it brings the call back.
struct CallBar: View {
    let call: Call
    let statusBarHeight: CGFloat

    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button { workspace.isShowingCall = true } label: {
            HStack(spacing: 8) {
                Image(systemName: call.isMuted ? "mic.slash.fill" : "waveform")
                Text(call.title).lineLimit(1)
                Spacer()
                Text("Return to call")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .contentShape(.rect)
            .padding(.top, statusBarHeight)
            .background(Color.green)
        }
        .buttonStyle(.plain)
    }
}
