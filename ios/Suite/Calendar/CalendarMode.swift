import SwiftUI

/// How much time the Calendar screen shows at once.
enum CalendarMode: String, CaseIterable, Identifiable {
    case day, week, month

    var id: Self { self }

    var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        }
    }

    var systemImage: String {
        switch self {
        case .day: "list.bullet"
        case .week: "calendar.day.timeline.left"
        case .month: "calendar"
        }
    }

    /// The events to fetch around `day`: one day, or the visible page plus its neighbors so swipes land on data.
    func range(around day: Date) -> DateInterval {
        let calendar = Calendar.current
        switch self {
        case .day:
            return DateInterval(start: day, end: calendar.date(byAdding: .day, value: 1, to: day)!)
        case .week:
            let start = calendar.startOfWeek(day)
            return DateInterval(
                start: calendar.date(byAdding: .weekOfYear, value: -1, to: start)!,
                end: calendar.date(byAdding: .weekOfYear, value: 2, to: start)!
            )
        case .month:
            let start = calendar.startOfMonth(day)
            return DateInterval(
                start: calendar.startOfWeek(calendar.date(byAdding: .month, value: -1, to: start)!),
                end: calendar.date(byAdding: .day, value: 42, to: calendar.date(byAdding: .month, value: 1, to: start)!)!
            )
        }
    }
}

extension Calendar {
    func startOfWeek(_ date: Date) -> Date {
        dateInterval(of: .weekOfYear, for: date)!.start
    }

    func startOfMonth(_ date: Date) -> Date {
        dateInterval(of: .month, for: date)!.start
    }

    /// The seven days of the week that starts on `start`.
    func week(from start: Date) -> [Date] {
        (0..<7).map { self.date(byAdding: .day, value: $0, to: start)! }
    }

    /// The day after `date`'s start, for half-open day intervals.
    func endOfDay(_ date: Date) -> Date {
        self.date(byAdding: .day, value: 1, to: startOfDay(for: date))!
    }
}

extension CalendarEvent {
    /// Whether any part of the event falls on `day`.
    func occurs(on day: Date, in calendar: Calendar = .current) -> Bool {
        let start = calendar.startOfDay(for: day)
        // A zero-length event still shows on the day it starts.
        return self.start < calendar.endOfDay(start) && (end > start || self.start == start)
    }
}

/// An event's title on a light tint of its calendar color, with a bar of the full color.
struct EventChip: View {
    let event: CalendarEvent
    var font: Font = .caption2.weight(.medium)

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(event.color).frame(width: 2)
            Text(event.title)
                .font(font)
                .lineLimit(1)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
            Spacer(minLength: 0)
        }
        // The bar would otherwise stretch to fill a tall month cell.
        .fixedSize(horizontal: false, vertical: true)
        .background(event.color.opacity(0.15))
        .clipShape(.rect(cornerRadius: 3))
    }
}
