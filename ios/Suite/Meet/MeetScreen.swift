import SwiftUI

/// Start or join a meeting, and see the meetings coming up on the calendar.
struct MeetScreen: View {
    @Environment(Workspace.self) private var workspace
    @State private var upcoming: [CalendarEvent] = []
    @State private var created: Room?
    @State private var isStarting = false
    @State private var isJoining = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(spacing: 12) {
                    MeetAction(title: "New meeting", systemImage: "video.badge.plus", isBusy: isStarting) {
                        Task { await start() }
                    }
                    MeetAction(title: "Join with code", systemImage: "keyboard") { isJoining = true }
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader("Upcoming meetings")
                    VStack(alignment: .leading, spacing: 4) {
                        if upcoming.isEmpty {
                            Text("No meetings scheduled").foregroundStyle(.secondary).padding(.vertical, 10)
                        }
                        ForEach(upcoming) { event in
                            UpcomingMeeting(event: event) {
                                join(event.meetingCode!, title: event.title)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .card(cornerRadius: 16)
                    if workspace.calendar.isSample { SampleNotice() }
                }
            }
            .padding(16)
        }
        .navigationTitle("Meet")
        .toolbar { SidebarButton() }
        .task(id: workspace.calendar.isSample) { await loadUpcoming() }
        .refreshable { await loadUpcoming() }
        .sheet(item: $created) { RoomSheet(room: $0) { join($0.code) } }
        .sheet(isPresented: $isJoining) { JoinSheet { join($0) } }
    }

    private func start() async {
        isStarting = true
        defer { isStarting = false }
        do {
            created = try await workspace.api.call("POST", "api/suite/meet/rooms", body: ["type": "open"])
        } catch {
            workspace.error = error.localizedDescription
        }
    }

    private func join(_ code: String, title: String = "Meeting") {
        created = nil
        isJoining = false
        workspace.join(code, title: title)
    }

    private func loadUpcoming() async {
        let range = DateInterval(start: .now, duration: 14 * 86_400)
        let events = (try? await workspace.calendar.events(range)) ?? []
        upcoming = Array(events.filter { $0.meetingCode != nil }.prefix(10))
    }
}

/// A new meeting room's code and link.
struct Room: Decodable, Identifiable, Sendable {
    let code: String
    let url: String

    var id: String { code }
}

private struct MeetAction: View {
    let title: String
    let systemImage: String
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                if isBusy {
                    ProgressView().frame(height: 28)
                } else {
                    Image(systemName: systemImage).font(.title3).frame(height: 28)
                }
                Text(title).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .foregroundStyle(.primary)
            .card(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }
}

/// A meeting on the calendar: its color as a bar, title and time, and Join.
private struct UpcomingMeeting: View {
    let event: CalendarEvent
    let join: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5).fill(event.color).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.start, format: .dateTime.weekday(.wide).hour().minute())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(event.title).lineLimit(1)
            }
            Spacer()
            Button("Join", action: join).font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 10)
    }
}

private struct RoomSheet: View {
    let room: Room
    let join: (Room) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "video").font(.largeTitle).foregroundStyle(.secondary)
            Text("Your meeting is ready").font(.title2.bold())
            Text(room.code)
                .font(.title3.monospaced())
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: .capsule)
            Text("Share this code or link with the people you want in the meeting.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                if let url = URL(string: room.url) {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Color(.tertiarySystemFill), in: .capsule)
                    }
                }
                Button { join(room) } label: {
                    Text("Join now")
                        .foregroundStyle(Color(.systemBackground))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.accentColor, in: .capsule)
                }
            }
            .font(.body.weight(.semibold))
            .buttonStyle(.plain)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}

/// Asks for a meeting code in the web app's `xxxx-xxxx-xxxx` form.
struct JoinSheet: View {
    let join: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("abcd-efgh-ijkl", text: $code)
                    .font(.title3.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isFocused)
                    .onSubmit { if isValid { join(normalized) } }
            }
            .navigationTitle("Join with code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join") { join(normalized) }.disabled(!isValid)
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.height(220)])
    }

    private var normalized: String { code.trimmingCharacters(in: .whitespaces).lowercased() }

    private var isValid: Bool {
        normalized.wholeMatch(of: /[a-z]{4}-[a-z]{4}-[a-z]{4}/) != nil
    }
}
