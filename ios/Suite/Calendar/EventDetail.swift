import SwiftUI

/// One event's time, people, place, and meeting link, in a sheet like Joi's.
struct EventDetail: View {
    let event: CalendarEvent

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    /// The change count when editing began. Saving an edit closes this sheet too, since its copy is old.
    @State private var changesBeforeEdit = 0
    @State private var isDeleting = false
    @State private var isBusy = false
    @State private var reply: String?
    @State private var failure: String?

    private var me: String { workspace.mail.myEmail }
    private var canChange: Bool { workspace.calendarWriter != nil && event.isOrganized(by: me) }

    var body: some View {
        ScrollView {
            // Space, not rules, separates the groups.
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(when).font(.subheadline).foregroundStyle(.secondary)
                    Text(event.title).font(.title2.bold())
                    TimelineView(.everyMinute) { context in
                        Text(countdown(from: context.date)).font(.subheadline.weight(.medium))
                    }
                }
                if canChange {
                    HStack(spacing: 12) {
                        Button("Edit", systemImage: "pencil") {
                            changesBeforeEdit = workspace.calendarChanges
                            isEditing = true
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { isDeleting = true }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                } else if workspace.calendarWriter != nil, let current = reply ?? event.reply(of: me) {
                    RSVPPicker(reply: current, isBusy: isBusy) { respond($0) }
                }
                if let code = event.meetingCode {
                    Button {
                        dismiss()
                        workspace.join(code, title: event.title)
                    } label: {
                        Label("Join meeting", systemImage: "video.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color(.systemBackground))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Color.accentColor, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
                if !event.people.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("\(event.people.count) people").font(.subheadline).foregroundStyle(.secondary)
                        ForEach(event.people, id: \.email) { person in
                            HStack(spacing: 12) {
                                Avatar(name: person.name, size: 36)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(person.name)
                                    // Someone with no stored name is already named by their address.
                                    if person.name != person.email {
                                        Text(person.email).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                if let reply = Self.replyLabel(person.reply) {
                                    Text(reply).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                VStack(spacing: 14) {
                    detail("Calendar") {
                        HStack(spacing: 6) {
                            Circle().fill(event.color).frame(width: 8, height: 8)
                            Text(event.calendar)
                        }
                    }
                    if let location = event.location {
                        detail("Location") { Text(location).multilineTextAlignment(.trailing) }
                    }
                }
                if !event.notes.isEmpty {
                    Text(event.notes).foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $isEditing, onDismiss: { if workspace.calendarChanges != changesBeforeEdit { dismiss() } }) {
            EventForm(editing: event, me: me)
        }
        .confirmationDialog("Delete this event?", isPresented: $isDeleting, titleVisibility: .visible) {
            if event.record?.isRecurring == true {
                Button("Delete This Event", role: .destructive) { delete(wholeSeries: false) }
                Button("Delete All Events", role: .destructive) { delete(wholeSeries: true) }
            } else {
                Button("Delete Event", role: .destructive) { delete(wholeSeries: true) }
            }
        } message: {
            if event.people.count > 1 { Text("Guests get an email saying it is cancelled.") }
        }
        .alert("Could not change the event", isPresented: Binding { failure != nil } set: { _ in failure = nil }) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func delete(wholeSeries: Bool) {
        run {
            try await workspace.changeCalendar { try await $0.delete(event, wholeSeries: wholeSeries) }
            dismiss()
        }
    }

    private func respond(_ answer: CalendarWriter.Reply) {
        let before = reply
        reply = answer.rawValue
        run {
            do {
                try await workspace.changeCalendar { try await $0.respond(to: event, answer) }
            } catch {
                reply = before
                throw error
            }
        }
    }

    private func run(_ step: @escaping () async throws -> Void) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do { try await step() } catch { failure = error.localizedDescription }
        }
    }

    private func detail(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            value()
        }
    }

    private static func replyLabel(_ reply: String?) -> String? {
        switch reply?.lowercased() {
        case "accepted": "Going"
        case "tentative": "Maybe"
        case "declined": "Not going"
        case "needs-action": "No reply"
        default: nil
        }
    }

    private var when: String {
        let day = event.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        if event.isAllDay { return "\(day) · All day" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "\(day) · \(start) → \(end)"
    }

    private func countdown(from now: Date) -> String {
        if event.end <= now { return "Ended" }
        if event.start <= now { return "Happening now" }
        let parts = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: event.start)
        let text = [(parts.day, "day"), (parts.hour, "hour"), (parts.minute, "minute")]
            .compactMap { value, unit in value.flatMap { $0 > 0 ? "\($0) \(unit)\($0 == 1 ? "" : "s")" : nil } }
            .prefix(2)
            .joined(separator: " and ")
        return text.isEmpty ? "Starting now" : "In \(text)"
    }
}

/// Going, Maybe, or No, with the current answer filled in.
private struct RSVPPicker: View {
    let reply: String
    let isBusy: Bool
    let choose: (CalendarWriter.Reply) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Going?").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                option("Yes", .accepted)
                option("Maybe", .tentative)
                option("No", .declined)
            }
        }
    }

    private func option(_ title: String, _ answer: CalendarWriter.Reply) -> some View {
        let isChosen = reply == answer.rawValue
        return Button { choose(answer) } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(isChosen ? Color(.systemBackground) : .primary)
                .background(isChosen ? Color.accentColor : Color(.secondarySystemFill), in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}
