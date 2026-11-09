import Foundation
import Testing
@testable import Suite

/// What event changes send to the site, as Maya.
@Suite(.serialized)
struct CalendarWriterTests {
    private final class Log: @unchecked Sendable { var bodies: [(method: String, body: [String: Any])] = [] }

    private func writer(_ log: Log, reply: String = #"{"message":"e1"}"#) -> CalendarWriter {
        StubServer.handler = { request, body in
            log.bodies.append((request.url?.lastPathComponent ?? "", (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]))
            return .json(reply)
        }
        return CalendarWriter(api: StubServer.client(), account: "acc1", me: "maya@example.com")
    }

    private func event(recurring: Bool = false) -> CalendarEvent {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let stored: [JSONValue] = [
            .object(["email": .string("maya@example.com"), "participation_status": .string("ACCEPTED")]),
            .object(["email": .string("lee@example.com"), "participation_status": .string("DECLINED"), "uid": .string("p2")]),
        ]
        return CalendarEvent(
            id: "occ1", title: "Sync", start: start, end: start.addingTimeInterval(1800), isAllDay: false, location: nil,
            calendar: "Work", color: .blue,
            people: [.init(name: "Maya", email: "maya@example.com", reply: "ACCEPTED"), .init(name: "Lee", email: "lee@example.com", reply: "DECLINED")],
            notes: "", meetingCode: nil,
            record: .init(account: "acc1", id: recurring ? "series1" : "occ1", recurrenceID: recurring ? "2027-01-15T10:00:00" : nil,
                          organizer: "maya@example.com", participants: stored)
        )
    }

    @Test func addingAGuestKeepsTheOthersReplies() async throws {
        let log = Log()
        var change = EventChange(event(), me: "maya@example.com")
        change.guests += ", ana@example.com"

        try await writer(log).update(event(), to: change)

        let sent = try #require(log.bodies.last?.body["participants"] as? [[String: Any]])
        let replies = Dictionary(uniqueKeysWithValues: sent.map { ($0["email"] as! String, $0["participation_status"] as! String) })
        #expect(replies == ["maya@example.com": "ACCEPTED", "lee@example.com": "DECLINED", "ana@example.com": "NEEDS-ACTION"])
        #expect(log.bodies.last?.body["send_scheduling_messages"] as? Bool == true)
    }

    @Test func renamingOnlySendsTheTitle() async throws {
        let log = Log()
        var change = EventChange(event(), me: "maya@example.com")
        change.title = "Weekly sync"

        try await writer(log).update(event(), to: change)

        let sent = try #require(log.bodies.last?.body)
        #expect(sent["title"] as? String == "Weekly sync")
        #expect(sent["start"] == nil && sent["participants"] == nil)
    }

    @Test func aSeriesKeepsItsTimesWhenEdited() async throws {
        let log = Log()
        var change = EventChange(event(recurring: true), me: "maya@example.com")
        change.title = "Renamed"
        change.start = change.start.addingTimeInterval(3600)

        try await writer(log).update(event(recurring: true), to: change)

        let sent = try #require(log.bodies.last?.body)
        #expect(sent["id"] as? String == "series1")
        #expect(sent["start"] == nil)
    }

    @Test func anAllDayEventLastsWholeDays() async throws {
        let log = Log()
        var change = EventChange(day: Date(timeIntervalSince1970: 1_800_000_000))
        change.title = "Offsite"
        change.isAllDay = true
        change.end = Calendar.current.date(byAdding: .day, value: 2, to: change.start)!

        try await writer(log).create(change)

        let sent = try #require(log.bodies.last?.body)
        #expect(sent["duration"] as? String == "P3D")
        #expect((sent["start"] as? String)?.hasSuffix("T00:00:00") == true)
        #expect(sent["show_without_time"] as? Bool == true)
    }

    @Test func deletingOneOccurrenceLeavesTheSeries() async throws {
        let log = Log()

        try await writer(log).delete(event(recurring: true), wholeSeries: false)

        let call = try #require(log.bodies.last)
        #expect(call.method.hasSuffix("delete_calendar_event_instance"))
        #expect(call.body["master_id"] as? String == "series1")
        #expect(call.body["recurrence_id"] as? String == "2027-01-15T10:00:00")
    }

    @Test func answeringAnOccurrenceNamesIt() async throws {
        let log = Log()

        // The site answers a method that returns nothing with an empty object.
        try await writer(log, reply: "{}").respond(to: event(recurring: true), .tentative)

        let sent = try #require(log.bodies.last?.body)
        #expect(sent["id"] as? String == "series1")
        #expect(sent["recurrence_id"] as? String == "2027-01-15T10:00:00")
        #expect(sent["response"] as? String == "tentative")
    }

    @Test func aDayIncludesItsLateEvening() async throws {
        let zone = TimeZone.current.identifier
        var asked: URL?
        StubServer.handler = { request, _ in
            asked = request.url
            return .json(#"{"data":[{"id":"late","title":"Late call","start":"2026-11-09T22:00:00","duration":"PT1H","time_zone":"\#(zone)"},"#
                + #"{"id":"next","title":"Tomorrow","start":"2026-11-10T09:00:00","duration":"PT1H","time_zone":"\#(zone)"}]}"#)
        }
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 9))!

        let events = try await CalendarSource.live(StubServer.client()).events(DateInterval(start: day, duration: 86_400))

        #expect(events.map(\.title) == ["Late call"])
        let url = try #require(asked)
        let to = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "to" }?.value)
        // The site reads the range in its own zone, so the request must reach past midnight anywhere.
        #expect(try Date(to, strategy: .iso8601) >= day.addingTimeInterval(86_400 + 14 * 3600))
    }
}
