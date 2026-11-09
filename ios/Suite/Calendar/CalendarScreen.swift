import SwiftUI

/// The chosen day, week, or month. Day is a large date, a week strip, and the day's events, after Joi's day view.
struct CalendarScreen: View {
    @Environment(Workspace.self) private var workspace
    @State private var mode = CalendarMode.day
    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var events: [CalendarEvent] = []
    @State private var error: String?
    @State private var selected: CalendarEvent?
    @State private var isAdding = false

    var body: some View {
        content
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu {
                Picker("View", selection: $mode) {
                    ForEach(CalendarMode.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
            }
            .toolbar {
                SidebarButton()
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Today") { day = Calendar.current.startOfDay(for: .now) }
                    Button("New event", systemImage: "plus") { isAdding = true }
                }
            }
            .task(id: TaskKey(range: mode.range(around: day), sample: workspace.calendar.isSample, changes: workspace.calendarChanges)) { await load() }
            .sheet(item: $selected) { EventDetail(event: $0) }
            .sheet(isPresented: $isAdding) { EventForm(day: day) }
            .task(id: workspace.link) {
                guard case .calendar(let date) = workspace.link else { return }
                workspace.link = nil
                show(date ?? .now)
            }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .day:
            VStack(spacing: 0) {
                header
                WeekStrip(day: $day)
                agenda
            }
        case .week:
            CalendarWeekView(day: $day, events: events, onSelect: { selected = $0 }, onPickDay: show)
                .safeAreaInset(edge: .bottom) { notice }
                .overlay { failure }
        case .month:
            CalendarMonthView(day: $day, events: events, onPickDay: show)
                .safeAreaInset(edge: .bottom) { notice }
                .overlay { failure }
        }
    }

    /// Opens `date` in Day mode.
    private func show(_ date: Date) {
        day = Calendar.current.startOfDay(for: date)
        mode = .day
    }

    @ViewBuilder private var notice: some View {
        if workspace.calendar.isSample {
            SampleNotice().padding(.horizontal, 20).padding(.vertical, 6)
        }
    }

    @ViewBuilder private var failure: some View {
        if let error {
            ContentUnavailableView("Could not load events", systemImage: "exclamationmark.triangle", description: Text(error))
                .background(Color(.systemBackground))
        }
    }

    private var header: some View {
        HStack {
            Text(day.formatted(.dateTime.day(.twoDigits)))
                .font(.system(size: 56, weight: .bold).monospacedDigit())
                .contentTransition(.numericText())
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(day.formatted(.dateTime.weekday(.wide)))
                Text(day.formatted(.dateTime.month(.wide).day()))
                    .foregroundStyle(.secondary)
            }
            .font(.title3.weight(.semibold))
        }
        .padding(.horizontal, 20)
        .animation(.snappy, value: day)
    }

    private var agenda: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(dayEvents.filter(\.isAllDay) + dayEvents.filter { !$0.isAllDay }) { event in
                    Button { selected = event } label: { AgendaRow(event: event, showsCalendar: dayEvents.spansCalendars) }
                        .buttonStyle(.plain)
                }
                if workspace.calendar.isSample && !dayEvents.isEmpty {
                    SampleNotice()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 16)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
        }
        .overlay {
            if let error {
                ContentUnavailableView("Could not load events", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if dayEvents.isEmpty {
                ContentUnavailableView("Nothing scheduled", systemImage: "calendar", description: Text("Enjoy the free day."))
            }
        }
        .refreshable { await load() }
    }

    /// The chosen day's events. `events` can still hold a week or month just after switching modes.
    private var dayEvents: [CalendarEvent] {
        events.filter { $0.occurs(on: day) }
    }

    private func load() async {
        do {
            events = try await workspace.calendar.events(mode.range(around: day))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private struct TaskKey: Equatable {
        let range: DateInterval
        let sample: Bool
        let changes: Int
    }
}

/// Seven days, swiped a week at a time.
private struct WeekStrip: View {
    @Binding var day: Date
    /// Weeks from this one. It starts at the chosen day's week, which picking a day in Month can move.
    @State private var week: Int

    init(day: Binding<Date>) {
        _day = day
        _week = State(initialValue: Self.weeks(to: day.wrappedValue))
    }

    private static func weeks(to day: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents([.weekOfYear], from: calendar.startOfWeek(.now), to: calendar.startOfWeek(day)).weekOfYear ?? 0
    }

    var body: some View {
        TabView(selection: $week) {
            ForEach(-52...52, id: \.self) { offset in
                HStack(spacing: 4) {
                    ForEach(days(offset), id: \.self) { date in cell(date) }
                }
                .padding(.horizontal, 12)
                .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: 76)
        .onChange(of: week) { old, new in
            // A swipe carries the day along. A day set elsewhere, which moved the week here, stays put.
            guard Self.weeks(to: day) != new else { return }
            day = Calendar.current.date(byAdding: .weekOfYear, value: new - old, to: day)!
        }
        .onChange(of: day) { _, day in
            let weeks = Self.weeks(to: day)
            if weeks != week { week = weeks }
        }
    }

    private func cell(_ date: Date) -> some View {
        let isSelected = Calendar.current.isDate(date, inSameDayAs: day)
        let isToday = Calendar.current.isDateInToday(date)
        return Button { day = date } label: {
            VStack(spacing: 2) {
                Text(date.formatted(.dateTime.day()))
                    .font(.title3.weight(isSelected ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.caption2.weight(isToday ? .heavy : .medium))
                    // Today is marked by weight, not color, so the strip stays neutral.
                    .foregroundStyle(isToday ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(isSelected ? Color(.tertiarySystemFill) : .clear, in: .rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func startOfWeek(_ date: Date) -> Date {
        Calendar.current.startOfWeek(date)
    }

    private func days(_ offset: Int) -> [Date] {
        Calendar.current.week(from: Calendar.current.date(byAdding: .weekOfYear, value: offset, to: startOfWeek(.now))!)
    }
}

/// An event's title, calendar, and place, with its time on the right. Used by Calendar's day and Home.
struct AgendaRow: View {
    let event: CalendarEvent
    /// Off when every event in the list shares one calendar, where the name would only repeat.
    let showsCalendar: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.body.weight(.medium)).lineLimit(2)
                if !detail.isEmpty {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Text(event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        // The calendar is named, not colored, so the list stays quiet. Week, month, and the event's details show its color.
        .padding(.vertical, 12)
        .contentShape(.rect)
    }

    /// The calendar, then the place: "Work · Room 4" or "Personal · Meet".
    private var detail: String {
        let place = event.location ?? event.meetingCode.map { _ in "Meet" }
        return [showsCalendar ? event.calendar : nil, place].compactMap { $0 }.joined(separator: " · ")
    }
}
