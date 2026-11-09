import SwiftUI

/// Seven day columns on a time grid, swiped a week at a time.
struct CalendarWeekView: View {
    @Binding var day: Date
    let events: [CalendarEvent]
    let onSelect: (CalendarEvent) -> Void
    let onPickDay: (Date) -> Void

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 0) {
            title
            TabView(selection: week) {
                ForEach(-52...52, id: \.self) { offset in
                    WeekPage(
                        days: calendar.week(from: calendar.date(byAdding: .weekOfYear, value: offset, to: calendar.startOfWeek(.now))!),
                        events: events,
                        onSelect: onSelect,
                        onPickDay: onPickDay
                    )
                    .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    private var title: some View {
        let days = calendar.week(from: calendar.startOfWeek(day))
        let first = days.first!, last = days.last!
        let sameMonth = calendar.isDate(first, equalTo: last, toGranularity: .month)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(sameMonth
                 ? first.formatted(.dateTime.month(.wide))
                 : "\(first.formatted(.dateTime.month(.abbreviated))) – \(last.formatted(.dateTime.month(.abbreviated)))")
                .font(.title2.bold())
            Text(last.formatted(.dateTime.year()))
                .font(.title2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    /// The page offset from this week, read from and written to `day`.
    private var week: Binding<Int> {
        Binding {
            calendar.dateComponents([.weekOfYear], from: calendar.startOfWeek(.now), to: calendar.startOfWeek(day)).weekOfYear ?? 0
        } set: { offset in
            let start = calendar.date(byAdding: .weekOfYear, value: offset, to: calendar.startOfWeek(.now))!
            let weekday = calendar.dateComponents([.day], from: calendar.startOfWeek(day), to: day).day ?? 0
            day = calendar.date(byAdding: .day, value: weekday, to: start)!
        }
    }
}

/// One week: a header of days, the all-day events, and the time grid.
private struct WeekPage: View {
    let days: [Date]
    let events: [CalendarEvent]
    let onSelect: (CalendarEvent) -> Void
    let onPickDay: (Date) -> Void

    private let gutter: CGFloat = 36

    var body: some View {
        VStack(spacing: 0) {
            header
            if hasAllDay { allDay }
            Divider()
            WeekTimeGrid(days: days, events: events, gutter: gutter, onSelect: onSelect)
        }
        .padding(.horizontal, 16)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(days, id: \.self) { date in
                let isToday = Calendar.current.isDateInToday(date)
                Button { onPickDay(date) } label: {
                    VStack(spacing: 4) {
                        Text(date.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(date.formatted(.dateTime.day()))
                            .font(.callout.weight(isToday ? .bold : .regular).monospacedDigit())
                            .foregroundStyle(isToday ? Color(.systemBackground) : .primary)
                            .frame(width: 30, height: 30)
                            .background(isToday ? Color.accentColor : .clear, in: .circle)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
            }
        }
    }

    private var hasAllDay: Bool {
        events.contains { event in event.isAllDay && days.contains { event.occurs(on: $0) } }
    }

    private var allDay: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("all-day")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: gutter, alignment: .leading)
            ForEach(days, id: \.self) { date in
                let dayEvents = events.filter { $0.isAllDay && $0.occurs(on: date) }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(dayEvents.prefix(2)) { event in
                        Button { onSelect(event) } label: { EventChip(event: event) }
                            .buttonStyle(.plain)
                    }
                    if dayEvents.count > 2 {
                        Text("+\(dayEvents.count - 2)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 1)
            }
        }
        .padding(.vertical, 6)
    }
}
