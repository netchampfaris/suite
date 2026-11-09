import Foundation

/// What the event form holds.
struct EventChange: Equatable {
    var title = ""
    var start = Date.now
    var end = Date.now.addingTimeInterval(3600)
    var isAllDay = false
    var location = ""
    var notes = ""
    /// Guests' addresses, as the person typed them.
    var guests = ""
    /// Adds a Meet room. Only a new event offers it.
    var addsMeeting = false

    init(day: Date) {
        let calendar = Calendar.current
        // The next whole hour on the chosen day.
        let hour = calendar.component(.hour, from: .now) + 1
        start = calendar.date(bySettingHour: min(hour, 23), minute: 0, second: 0, of: day) ?? day
        end = start.addingTimeInterval(3600)
    }

    init(_ event: CalendarEvent, me: String) {
        title = event.title
        start = event.start
        // An all-day event ends at the start of the day after; the form shows its last day.
        end = event.isAllDay ? event.end.addingTimeInterval(-1) : event.end
        isAllDay = event.isAllDay
        location = event.location ?? ""
        notes = event.notes
        guests = event.people.map(\.email).filter { $0.caseInsensitiveCompare(me) != .orderedSame }.joined(separator: ", ")
    }

    var guestList: [String] { Draft.addresses(guests) }
}

/// Sends event changes to the site.
struct CalendarWriter: Sendable {
    let api: APIClient
    /// The calendar account new events go into.
    let account: String
    let me: String

    enum Reply: String { case accepted, tentative, declined }

    /// Creates the event, with a Meet room when asked. Guests get an invitation.
    func create(_ change: EventChange) async throws {
        var fields = timing(change)
        fields["account"] = .string(account)
        fields["title"] = .string(change.title)
        fields["description"] = .string(change.notes)
        fields["locations"] = locations(change)
        fields["use_default_alerts"] = .bool(true)
        let guests = change.guestList
        if !guests.isEmpty {
            // The organizer is a participant too, already going.
            fields["participants"] = .array([participant(me, reply: "ACCEPTED")] + guests.map { participant($0, reply: "NEEDS-ACTION") })
            fields["send_scheduling_messages"] = .bool(true)
        }
        let method = change.addsMeeting
            ? "suite.meet.api.schedule.create_scheduled_meeting"
            : "suite.calendar.doctype.calendar_event.calendar_event.add_calendar_event"
        let _: JSONValue = try await api.method(method, body: fields)
    }

    /// Saves what changed. A series keeps its times: moving one occurrence would move them all.
    func update(_ event: CalendarEvent, to change: EventChange) async throws {
        guard let record = event.record else { return }
        let before = EventChange(event, me: me)
        var fields: [String: JSONValue] = ["account": .string(record.account), "id": .string(record.id)]
        if change.title != before.title { fields["title"] = .string(change.title) }
        if change.notes != before.notes { fields["description"] = .string(change.notes) }
        if change.location != before.location { fields["locations"] = locations(change) }
        if !record.isRecurring, [change.start, change.end] != [before.start, before.end] || change.isAllDay != before.isAllDay {
            fields.merge(timing(change)) { $1 }
        }
        if Set(change.guestList.map { $0.lowercased() }) != Set(before.guestList.map { $0.lowercased() }) {
            fields["participants"] = .array(participants(keeping: record.participants, guests: change.guestList))
        }
        // Guests hear about any change that reaches them.
        fields["send_scheduling_messages"] = .bool(!change.guestList.isEmpty || !before.guestList.isEmpty)
        let _: JSONValue? = try await api.method("suite.calendar.api.edit_calendar_event", body: fields)
    }

    /// Deletes the event, or for a series either this occurrence or all of them.
    func delete(_ event: CalendarEvent, wholeSeries: Bool) async throws {
        guard let record = event.record else { return }
        let notifies = JSONValue.bool(event.people.count > 1)
        if let occurrence = record.recurrenceID, !wholeSeries {
            let _: JSONValue? = try await api.method(
                "suite.calendar.doctype.calendar_event.calendar_event.delete_calendar_event_instance",
                body: ["account": .string(record.account), "master_id": .string(record.id),
                       "recurrence_id": .string(occurrence), "send_scheduling_messages": notifies] as [String: JSONValue]
            )
        } else {
            let _: JSONValue? = try await api.method(
                "suite.calendar.doctype.calendar_event.calendar_event.delete_calendar_events",
                body: ["account": .string(record.account), "ids": .array([.string(record.id)]),
                       "send_scheduling_messages": notifies] as [String: JSONValue]
            )
        }
    }

    /// Answers an invitation. For a series, the answer is for this occurrence only.
    func respond(to event: CalendarEvent, _ reply: Reply) async throws {
        guard let record = event.record else { return }
        var fields: [String: JSONValue] = ["account": .string(record.account), "id": .string(record.id), "response": .string(reply.rawValue)]
        if let occurrence = record.recurrenceID { fields["recurrence_id"] = .string(occurrence) }
        let _: JSONValue? = try await api.method("suite.calendar.api.rsvp_calendar_event", body: fields)
    }

    // MARK: Fields

    /// Start as a wall clock in the device's zone, and a length, the way JSCalendar keeps them.
    private func timing(_ change: EventChange) -> [String: JSONValue] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let start = change.isAllDay ? calendar.startOfDay(for: change.start) : change.start
        let duration: String
        if change.isAllDay {
            let days = (calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: change.end)).day ?? 0) + 1
            duration = "P\(max(days, 1))D"
        } else {
            let minutes = max(Int(change.end.timeIntervalSince(start) / 60), 0)
            duration = "PT\(minutes / 60)H\(minutes % 60)M"
        }
        return [
            "start": .string(formatter.string(from: start)),
            "duration": .string(duration),
            "time_zone": .string(TimeZone.current.identifier),
            "show_without_time": .bool(change.isAllDay),
        ]
    }

    private func locations(_ change: EventChange) -> JSONValue {
        let place = change.location.trimmingCharacters(in: .whitespaces)
        return .array(place.isEmpty ? [] : [.object(["name": .string(place)])])
    }

    private func participant(_ email: String, reply: String) -> JSONValue {
        .object(["email": .string(email), "participation_status": .string(reply), "expect_reply": .bool(reply != "ACCEPTED")])
    }

    /// The guest list as typed, keeping the stored entry, and so the reply, of everyone who stays.
    private func participants(keeping stored: [JSONValue], guests: [String]) -> [JSONValue] {
        func email(_ entry: JSONValue) -> String { entry["email"]?.string?.lowercased() ?? "" }
        let wanted = Set(guests.map { $0.lowercased() } + [me.lowercased()])
        let kept = stored.filter { wanted.contains(email($0)) }
        let known = Set(kept.map(email))
        let mine = known.contains(me.lowercased()) ? [] : [participant(me, reply: "ACCEPTED")]
        return mine + kept + guests.filter { !known.contains($0.lowercased()) }.map { participant($0, reply: "NEEDS-ACTION") }
    }
}
