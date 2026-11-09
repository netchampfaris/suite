import SwiftUI

/// One calendar event, already turned from JSCalendar into start and end times.
struct CalendarEvent: Identifiable, Hashable, Sendable {
    struct Person: Hashable, Sendable {
        let name: String
        let email: String
        /// Their reply: `accepted`, `tentative`, `declined`, or `needs-action`.
        var reply: String?
    }

    /// What changing the event needs. Sample events have none.
    struct Record: Hashable, Sendable {
        let account: String
        /// The event's id. For an occurrence of a series, the series' id.
        let id: String
        /// Which occurrence of a series this is, or nil for a one-off event.
        let recurrenceID: String?
        let organizer: String
        /// Participants as stored, so an edit keeps everyone's replies.
        let participants: [JSONValue]

        var isRecurring: Bool { recurrenceID != nil }
    }

    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let calendar: String
    let color: Color
    let people: [Person]
    let notes: String
    /// The Meet code when the event has a meeting link.
    let meetingCode: String?
    var record: Record?

    /// Whether `email` organizes the event. An event with no organizer is the owner's own.
    func isOrganized(by email: String) -> Bool {
        guard let organizer = record?.organizer, !organizer.isEmpty else { return record != nil }
        return organizer.caseInsensitiveCompare(email) == .orderedSame
    }

    /// The reply `email` gave, when they are a guest.
    func reply(of email: String) -> String? {
        people.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }?.reply?.lowercased()
    }
}

extension [CalendarEvent] {
    /// True when the events come from more than one calendar.
    var spansCalendars: Bool { Set(map(\.calendar)).count > 1 }
}

/// Where events come from: the site, or sample data when the site has no mail server.
struct CalendarSource: Sendable {
    let events: @Sendable (DateInterval) async throws -> [CalendarEvent]
    let isSample: Bool

    static func live(_ api: APIClient) -> CalendarSource {
        CalendarSource(isSample: false) { range in
            // The site reads `from` and `to` as wall clocks in its own time zone, which the app does not know.
            // A day either side covers any zone, and the overlap check below trims the extra.
            let day: TimeInterval = 86_400
            let rows: [WireEvent] = try await api.call("GET", "api/suite/calendar/events", query: [
                "from": range.start.addingTimeInterval(-day).ISO8601Format(),
                "to": range.end.addingTimeInterval(day).ISO8601Format(),
            ])
            return rows.compactMap(\.event)
                .filter { $0.end > range.start && $0.start < range.end }
                .sorted { $0.start < $1.start }
        }
    }

    static let sample = CalendarSource(isSample: true) { range in
        SampleCalendar.events.filter { $0.end > range.start && $0.start < range.end }
    }

    private init(isSample: Bool, events: @escaping @Sendable (DateInterval) async throws -> [CalendarEvent]) {
        self.isSample = isSample
        self.events = events
    }
}

extension Workspace {
    var calendar: CalendarSource { hasMailServer ? .live(api) : .sample }
}

// MARK: Wire format

/// The server's JSCalendar event: wall-clock `start` in `time_zone`, plus a duration.
private struct WireEvent: Decodable {
    struct Calendar: Decodable { let calendarName: String?; let color: String? }
    struct Location: Decodable { let name: String? }
    struct Conferencing: Decodable { let meetingId: String? }

    let id: String
    let account: String?
    let masterId: String?
    let recurrenceId: String?
    let organizer: String?
    let title: String?
    let start: String
    let duration: String?
    let timeZone: String?
    let showWithoutTime: Int?
    let description: String?
    let calendars: [Calendar]?
    let locations: [Location]?
    /// Kept whole, since an edit sends them back.
    let participants: [JSONValue]?
    let conferencing: Conferencing?

    var event: CalendarEvent? {
        let zone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        guard let start = Self.wallClock(start, in: zone) else { return nil }
        let first = calendars?.first
        return CalendarEvent(
            id: id,
            title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled event",
            start: start,
            end: start.addingTimeInterval(ISODuration.seconds(duration ?? "PT1H")),
            isAllDay: showWithoutTime == 1,
            location: locations?.compactMap(\.name).first,
            calendar: first?.calendarName ?? "Calendar",
            color: first?.color.flatMap(Color.init(hex:)) ?? .blue,
            people: (participants ?? []).compactMap { person in
                person["email"]?.string.map {
                    CalendarEvent.Person(name: person["_name"]?.string ?? $0, email: $0,
                                         reply: person["participation_status"]?.string)
                }
            },
            notes: description ?? "",
            meetingCode: conferencing?.meetingId,
            record: account.map {
                CalendarEvent.Record(account: $0, id: masterId ?? id, recurrenceID: recurrenceId,
                                     organizer: organizer ?? "", participants: participants ?? [])
            }
        )
    }

    private static func wallClock(_ text: String, in zone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: String(text.prefix(19))) { return date }
        }
        return try? Date(text, strategy: .iso8601)
    }
}

/// Reads ISO 8601 durations such as `PT1H30M` or `P1D`.
enum ISODuration {
    static func seconds(_ text: String) -> TimeInterval {
        var total: TimeInterval = 0
        var number = ""
        var inTime = false
        for character in text {
            switch character {
            case "P": continue
            case "T": inTime = true
            case "0"..."9", ".": number.append(character)
            default:
                let value = Double(number) ?? 0
                number = ""
                switch (character, inTime) {
                case ("W", false): total += value * 604_800
                case ("D", false): total += value * 86_400
                case ("H", true): total += value * 3_600
                case ("M", true): total += value * 60
                case ("S", true): total += value
                default: break
                }
            }
        }
        return total
    }
}

extension Color {
    /// Reads `#rrggbb`, the way calendars store their colors.
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
