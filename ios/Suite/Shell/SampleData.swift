import SwiftUI

// Sample data for Calendar and Mail on sites without a mail server, so the screens
// can be tried before they are wired to the real thing. Dates follow today.

enum SampleCalendar {
    static let events: [CalendarEvent] = {
        let people = [
            CalendarEvent.Person(name: "Asha Rao", email: "asha@example.com"),
            CalendarEvent.Person(name: "Rohan Mehta", email: "rohan@example.com"),
            CalendarEvent.Person(name: "Meera Iyer", email: "meera@example.com"),
            CalendarEvent.Person(name: "Kabir Shah", email: "kabir@example.com"),
        ]
        var events: [CalendarEvent] = []
        for day in -3...10 {
            let weekday = Foundation.Calendar.current.component(.weekday, from: date(day, 0, 0))
            guard weekday != 1, weekday != 7 else { continue }
            events.append(event("standup-\(day)", "Daily standup", day, 10, 0, minutes: 15,
                                calendar: "Work", color: .blue, people: people, meeting: "abcd-efgh-ijkl"))
        }
        events += [
            event("design", "Design review: Drive mobile", 0, 12, 0, minutes: 60, calendar: "Work", color: .blue,
                  people: Array(people.prefix(3)), notes: "Walk through the new sidebar and Home.", meeting: "drve-mobl-revw"),
            event("lunch", "Lunch with Kabir", 0, 13, 30, minutes: 60, calendar: "Personal", color: .green,
                  location: "Third Wave Coffee, Indiranagar", people: [people[3]]),
            event("one-on-one", "1:1 with Asha", 0, 16, 0, minutes: 30, calendar: "Work", color: .blue,
                  people: [people[0]], meeting: "asha-oneo-none"),
            event("planning", "Sprint planning", 1, 11, 0, minutes: 90, calendar: "Work", color: .blue,
                  people: people, notes: "Bring your estimates.", meeting: "sprt-plan-ning"),
            event("dentist", "Dentist", 1, 18, 0, minutes: 45, calendar: "Personal", color: .green,
                  location: "Smile Dental Clinic"),
            event("offsite", "Team offsite", 3, 0, 0, minutes: 24 * 60, calendar: "Work", color: .blue,
                  allDay: true, location: "Nandi Hills", people: people),
            event("demo", "Customer demo", 2, 15, 0, minutes: 45, calendar: "Work", color: .blue,
                  people: [people[1]], meeting: "cust-demo-meet"),
            event("retro", "Retro", -1, 17, 0, minutes: 45, calendar: "Work", color: .blue,
                  people: people, meeting: "retr-ospe-ctiv"),
        ]
        return events.sorted { $0.start < $1.start }
    }()

    private static func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        let today = Foundation.Calendar.current.startOfDay(for: .now)
        let start = Foundation.Calendar.current.date(byAdding: .day, value: day, to: today)!
        return Foundation.Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: start)!
    }

    private static func event(
        _ id: String, _ title: String, _ day: Int, _ hour: Int, _ minute: Int, minutes: Int,
        calendar: String, color: Color, allDay: Bool = false, location: String? = nil,
        people: [CalendarEvent.Person] = [], notes: String = "", meeting: String? = nil
    ) -> CalendarEvent {
        let start = date(day, hour, minute)
        return CalendarEvent(
            id: id, title: title, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)),
            isAllDay: allDay, location: location, calendar: calendar, color: color, people: people,
            notes: notes, meetingCode: meeting
        )
    }
}

enum SampleMail {
    static func threads() -> [MailThread] {
        let now = Date.now
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func message(_ name: String, _ email: String, _ minutes: Double, _ body: String) -> MailMessage {
            MailMessage(id: UUID().uuidString, fromName: name, fromEmail: email, to: ["you@example.com"],
                        date: ago(minutes), body: body)
        }
        return [
            MailThread(id: "1", mailbox: .inbox, subject: "Drive mobile: sidebar feedback", isRead: false, isStarred: true, messages: [
                message("Asha Rao", "asha@example.com", 12, """
                Hi,

                I tried the new sidebar on my phone. Switching between apps feels quick, and the recent \
                documents list is handy. Two things:

                1. The New button should remember the last type I picked.
                2. Can Home show unread mail too?

                Asha
                """),
            ]),
            MailThread(id: "2", mailbox: .inbox, category: .updates, subject: "Invoice #4821 for October", isRead: false, isStarred: false, messages: [
                message("Billing", "billing@example.com", 95, "Your invoice for October is attached. The total is ₹12,400, due on the 15th."),
            ], attachments: [MailAttachment(name: "Invoice-4821.pdf")]),
            MailThread(id: "3", mailbox: .inbox, subject: "Lunch on Friday?", isRead: true, isStarred: false, messages: [
                message("Kabir Shah", "kabir@example.com", 60 * 5, "Are you free for lunch on Friday? I found a new place near the office."),
                message("You", "you@example.com", 60 * 4, "Friday works. 1:30?"),
                message("Kabir Shah", "kabir@example.com", 60 * 3, "Perfect, see you then."),
            ]),
            MailThread(id: "4", mailbox: .inbox, subject: "Release notes for 16.2", isRead: true, isStarred: false, messages: [
                message("Rohan Mehta", "rohan@example.com", 60 * 26, """
                The draft release notes are in Drive under Projects › Releases. Please add anything \
                I missed from your team by Thursday.
                """),
            ]),
            MailThread(id: "5", mailbox: .inbox, category: .updates, subject: "Welcome to Suite", isRead: true, isStarred: false, messages: [
                message("Suite", "hello@example.com", 60 * 24 * 6, "Mail, Calendar, Drive, and Meet now live in one place. Here are a few tips to get started."),
            ]),
            MailThread(id: "8", mailbox: .inbox, category: .updates, subject: "Your storage summary for October", isRead: false, isStarred: false, messages: [
                message("Drive", "drive@example.com", 60 * 9, "You used 4.2 GB of 30 GB this month. Your largest folder is Photos."),
            ]),
            MailThread(id: "9", mailbox: .inbox, category: .promotions, subject: "40% off annual plans this week", isRead: false, isStarred: false, messages: [
                message("Northwind Design", "news@example.com", 60 * 20, "Upgrade your team to an annual plan before Sunday and save 40%."),
            ]),
            MailThread(id: "10", mailbox: .inbox, category: .promotions, subject: "Conference tickets are now on sale", isRead: true, isStarred: false, messages: [
                message("Design Summit", "events@example.com", 60 * 24 * 3, "Early-bird tickets for next year's conference are available until the end of the month."),
            ]),
            MailThread(id: "6", mailbox: .sent, subject: "Re: Offsite agenda", isRead: true, isStarred: false, messages: [
                message("You", "you@example.com", 60 * 30, "Looks good. I added a slot for the mobile demo after lunch."),
            ]),
            MailThread(id: "7", mailbox: .drafts, subject: "Quarterly update", isRead: true, isStarred: false, messages: [
                message("You", "you@example.com", 60 * 48, "This quarter we shipped…"),
            ]),
        ]
    }
}
