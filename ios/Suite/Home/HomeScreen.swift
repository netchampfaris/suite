import SwiftUI

/// The first screen after sign-in, like the web app's Home: new documents, recent
/// files, and what is coming up.
struct HomeScreen: View {
    @Environment(Workspace.self) private var workspace
    @State private var recents: [DriveNode]?
    @State private var recentsError: String?
    @State private var upcoming: [CalendarEvent] = []
    @State private var isJoining = false
    @State private var isScheduling = false
    @State private var selected: CalendarEvent?

    private let gutter: CGFloat = 16

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                newSection
                recentSection
                upcomingSection
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .navigationTitle("Home")
        .toolbar { SidebarButton() }
        // Reload once the site turns out to have a mail server, so Upcoming shows real events.
        .task(id: [workspace.calendar.isSample ? 1 : 0, workspace.calendarChanges]) { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $isJoining) {
            JoinSheet {
                isJoining = false
                workspace.join($0)
            }
        }
        .sheet(isPresented: $isScheduling) { EventForm(day: .now) }
        .sheet(item: $selected) { EventDetail(event: $0) }
        .navigationDestination(for: DriveViewRoute.self) { DriveViewScreen(route: $0, drive: workspace.drive) }
    }

    // MARK: Sections

    private var newSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("New").padding(.horizontal, gutter)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                ForEach(DocumentKind.allCases) { kind in
                    Button { Task { await workspace.newDocument(kind) } } label: {
                        HStack(spacing: 10) {
                            kind.image
                                .resizable()
                                .frame(width: 20, height: 20)
                                .foregroundStyle(kind.color)
                            Text(kind.label)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .card()
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, gutter)
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Recent") {
                NavigationLink("View all", value: DriveViewRoute.recents)
            }
            .padding(.horizontal, gutter)
            if let recents, !recents.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(recents) { node in
                            Button { open(node) } label: { RecentCard(node: node) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, gutter)
                }
            } else if let recentsError {
                placeholder(recentsError)
            } else if recents != nil {
                placeholder("Nothing yet")
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
    }

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Upcoming") {
                HStack(spacing: 4) {
                    Menu {
                        Section {
                            Button("New event", systemImage: "calendar.badge.plus") { isScheduling = true }
                            Button("New meeting", systemImage: "video.badge.plus") { isScheduling = true }
                        }
                        Section {
                            Button("Start instant meeting", systemImage: "video") { workspace.area = .meet }
                            Button("Join with code", systemImage: "keyboard") { isJoining = true }
                        }
                    } label: {
                        Image(systemName: "plus")
                            // The icon alone is a tiny target.
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .padding(.vertical, -12)
                    .accessibilityLabel("Schedule or meet")
                    Button("View all") { workspace.area = .calendar }
                }
            }
            .padding(.horizontal, gutter)
            if upcoming.isEmpty {
                placeholder("Nothing scheduled")
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(days, id: \.self) { day in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(dayLabel(day))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(upcoming.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }) { event in
                                Button { selected = event } label: { AgendaRow(event: event, showsCalendar: upcoming.spansCalendars) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, gutter)
            }
            if workspace.calendar.isSample {
                SampleNotice().padding(.horizontal, gutter)
            }
        }
    }

    // MARK: Pieces

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 72)
            .card()
            .padding(.horizontal, gutter)
    }

    private var days: [Date] {
        upcoming.map { Calendar.current.startOfDay(for: $0.start) }
            .reduce(into: [Date]()) { if !$0.contains($1) { $0.append($1) } }
    }

    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide).day().month())
    }

    private func open(_ node: DriveNode) {
        if DocumentKind(node) != nil {
            workspace.page = .document(node)
        } else {
            workspace.area = .drive
        }
    }

    private func load() async {
        let calendar = workspace.calendar
        async let events = try? calendar.events(DateInterval(start: .now, duration: 7 * 86_400))
        do {
            let page = try await workspace.drive.view(.recents, cursor: nil)
            recents = Array(page.rows.filter { !$0.isContainer }.prefix(12))
            recentsError = nil
        } catch {
            recentsError = "Could not load recent files."
        }
        upcoming = Array((await events ?? []).prefix(3))
    }
}

/// A recent file as the web Home shows it: its type icon at the top, its name and age at the bottom.
private struct RecentCard: View {
    let node: DriveNode

    var body: some View {
        let type = FileType(node)
        VStack(alignment: .leading, spacing: 0) {
            type.image
                .resizable()
                .frame(width: 20, height: 20)
                .foregroundStyle(type.color)
            Spacer(minLength: 24)
            Text(node.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text((node.openedAt ?? node.changed)?.formatted(.relative(presentation: .named)) ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 168, height: 112, alignment: .leading)
        .card()
        .contentShape(.rect)
    }
}
