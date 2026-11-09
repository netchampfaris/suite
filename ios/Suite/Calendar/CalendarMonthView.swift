import SwiftUI

/// A six-week grid of days with their first events, swiped a month at a time.
struct CalendarMonthView: View {
    @Binding var day: Date
    let events: [CalendarEvent]
    let onPickDay: (Date) -> Void

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 0) {
            title
            weekdays
            TabView(selection: month) {
                ForEach(-24...24, id: \.self) { offset in
                    MonthPage(
                        month: calendar.date(byAdding: .month, value: offset, to: calendar.startOfMonth(.now))!,
                        selected: day,
                        events: events,
                        onPickDay: onPickDay
                    )
                    .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(day.formatted(.dateTime.month(.wide))).font(.title2.bold())
            Text(day.formatted(.dateTime.year())).font(.title2).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var weekdays: some View {
        HStack(spacing: 0) {
            ForEach(calendar.week(from: calendar.startOfWeek(.now)), id: \.self) { date in
                Text(date.formatted(.dateTime.weekday(.narrow)))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    /// The page offset from this month, read from and written to `day`.
    private var month: Binding<Int> {
        Binding {
            calendar.dateComponents([.month], from: calendar.startOfMonth(.now), to: calendar.startOfMonth(day)).month ?? 0
        } set: { offset in
            let start = calendar.date(byAdding: .month, value: offset, to: calendar.startOfMonth(.now))!
            // Keep today selected when swiping back to this month.
            day = calendar.isDate(start, equalTo: .now, toGranularity: .month) ? calendar.startOfDay(for: .now) : start
        }
    }
}

/// One month: six rows of seven days.
private struct MonthPage: View {
    let month: Date
    let selected: Date
    let events: [CalendarEvent]
    let onPickDay: (Date) -> Void

    private let calendar = Calendar.current

    var body: some View {
        let start = calendar.startOfWeek(month)
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { row in
                let days = calendar.week(from: calendar.date(byAdding: .weekOfYear, value: row, to: start)!)
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 0) {
                        ForEach(days, id: \.self) { date in cell(date) }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func cell(_ date: Date) -> some View {
        let isToday = calendar.isDateInToday(date)
        let isSelected = calendar.isDate(date, inSameDayAs: selected)
        let inMonth = calendar.isDate(date, equalTo: month, toGranularity: .month)
        let dayEvents = events.filter { $0.occurs(on: date) }.sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
        return Button { onPickDay(date) } label: {
            VStack(spacing: 3) {
                Text(date.formatted(.dateTime.day()))
                    .font(.footnote.weight(isToday ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(isToday ? Color(.systemBackground) : inMonth ? Color.primary : Color(.tertiaryLabel))
                    .frame(width: 24, height: 24)
                    .background(isToday ? Color.accentColor : .clear, in: .circle)
                ForEach(dayEvents.prefix(2)) { event in
                    EventChip(event: event, font: .system(size: 9, weight: .medium))
                        .opacity(inMonth ? 1 : 0.5)
                }
                if dayEvents.count > 2 {
                    Text("+\(dayEvents.count - 2)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
            .padding(.horizontal, 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(isSelected && !isToday ? Color(.tertiarySystemFill) : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(date, count: dayEvents.count))
    }

    private func accessibilityLabel(_ date: Date, count: Int) -> String {
        let when = date.formatted(date: .complete, time: .omitted)
        return count == 0 ? when : "\(when), \(count) event\(count == 1 ? "" : "s")"
    }
}
