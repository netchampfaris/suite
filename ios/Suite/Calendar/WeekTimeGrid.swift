import SwiftUI

/// Hours down the left and one column per day, with timed events placed by start and end.
struct WeekTimeGrid: View {
    let days: [Date]
    let events: [CalendarEvent]
    let gutter: CGFloat
    let onSelect: (CalendarEvent) -> Void

    static let hourHeight: CGFloat = 52
    /// Room above midnight so the first hour label is not clipped.
    private static let top: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let column = (proxy.size.width - gutter) / CGFloat(days.count)
            ScrollViewReader { scroller in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        hours
                        separators(column: column)
                        ForEach(Array(days.enumerated()), id: \.element) { index, day in
                            dayEvents(day, x: gutter + CGFloat(index) * column, width: column)
                        }
                        nowLine(column: column)
                    }
                    .frame(height: Self.top + 24 * Self.hourHeight, alignment: .top)
                    .padding(.bottom, 12)
                }
                .onChange(of: firstHour, initial: true) { _, hour in
                    scroller.scrollTo(hour, anchor: .top)
                }
            }
        }
    }

    /// The hour to open at: 8:00, or earlier when the week has an earlier event.
    private var firstHour: Int {
        let calendar = Calendar.current
        let hours = events
            .filter { event in !event.isAllDay && days.contains { event.occurs(on: $0) } }
            .map { max(calendar.component(.hour, from: $0.start) - 1, 0) }
        return min(hours.min() ?? 8, 8)
    }

    private var hours: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 6) {
                    Text(hour == 0 ? "" : label(hour))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: gutter - 6, alignment: .trailing)
                        .offset(y: -7)
                    Rectangle().fill(Color(.separator)).frame(height: 0.5)
                }
                .frame(height: Self.hourHeight, alignment: .top)
                .id(hour)
            }
        }
        .padding(.top, Self.top)
    }

    private func separators(column: CGFloat) -> some View {
        ForEach(0..<days.count, id: \.self) { index in
            Rectangle()
                .fill(Color(.separator).opacity(0.5))
                .frame(width: 0.5, height: 24 * Self.hourHeight)
                .offset(x: gutter + CGFloat(index) * column, y: Self.top)
        }
    }

    private func dayEvents(_ day: Date, x: CGFloat, width: CGFloat) -> some View {
        ForEach(WeekLayout.place(events, on: day, minimumMinutes: 22 / Self.hourHeight * 60)) { placed in
            let share = width / CGFloat(placed.columns)
            Button { onSelect(placed.event) } label: {
                EventBlock(event: placed.event, isTall: placed.visibleMinutes >= 50)
            }
            .buttonStyle(.plain)
            .frame(width: share - 2, height: max(placed.minutes / 60 * Self.hourHeight - 1, 20))
            .offset(x: x + CGFloat(placed.column) * share + 1, y: Self.top + placed.offset / 60 * Self.hourHeight)
        }
    }

    private func nowLine(column: CGFloat) -> some View {
        TimelineView(.everyMinute) { context in
            if let index = days.firstIndex(where: { Calendar.current.isDate($0, inSameDayAs: context.date) }) {
                let minutes = context.date.timeIntervalSince(Calendar.current.startOfDay(for: context.date)) / 60
                HStack(spacing: 0) {
                    Circle().frame(width: 6, height: 6)
                    Rectangle().frame(height: 1)
                }
                .foregroundStyle(.red)
                .frame(width: column + 3)
                .offset(x: gutter + CGFloat(index) * column - 3, y: Self.top + minutes / 60 * Self.hourHeight - 3)
                .allowsHitTesting(false)
            }
        }
    }

    private func label(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)!
        return date.formatted(.dateTime.hour())
    }
}

/// A timed event in the grid: a light tint of its calendar color with a bar of the full color.
private struct EventBlock: View {
    let event: CalendarEvent
    let isTall: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(event.color).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                if isTall {
                    Text(event.start.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(event.color.opacity(0.15))
        .clipShape(.rect(cornerRadius: 4))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Places one day's timed events side by side where they overlap.
enum WeekLayout {
    struct Placed: Identifiable {
        let event: CalendarEvent
        /// Minutes from the day's start to the event's start, clipped to the day.
        let offset: Double
        /// Drawn length in minutes, at least `minimumMinutes` so short events stay tappable.
        let minutes: Double
        let visibleMinutes: Double
        var column = 0
        var columns = 1

        var id: String { event.id }
        var end: Double { offset + minutes }
    }

    static func place(_ events: [CalendarEvent], on day: Date, minimumMinutes: Double) -> [Placed] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let end = calendar.endOfDay(start)
        let items = events
            .filter { !$0.isAllDay && $0.occurs(on: day) }
            .map { event in
                let offset = max(event.start, start).timeIntervalSince(start) / 60
                let length = min(event.end, end).timeIntervalSince(start) / 60 - offset
                return Placed(event: event, offset: offset, minutes: max(length, minimumMinutes), visibleMinutes: length)
            }
            .sorted { ($0.offset, -$0.minutes) < ($1.offset, -$1.minutes) }

        var placed: [Placed] = []
        var cluster: [Int] = []
        var columnEnds: [Double] = []
        var clusterEnd = -Double.infinity

        func closeCluster() {
            for index in cluster { placed[index].columns = columnEnds.count }
            cluster = []
            columnEnds = []
        }

        for var item in items {
            if item.offset >= clusterEnd { closeCluster() }
            if let free = columnEnds.firstIndex(where: { $0 <= item.offset }) {
                item.column = free
                columnEnds[free] = item.end
            } else {
                item.column = columnEnds.count
                columnEnds.append(item.end)
            }
            clusterEnd = max(clusterEnd, item.end)
            cluster.append(placed.count)
            placed.append(item)
        }
        closeCluster()
        return placed
    }
}
