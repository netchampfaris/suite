import SwiftUI

/// The signed-in app: a sidebar to switch between apps, and the chosen app beside it.
struct AppShell: View {
    @State private var workspace: Workspace
    @State private var isSidebarOpen = false
    @Environment(Notifications.self) private var notifications

    init(account: Account, api: APIClient) {
        _workspace = State(initialValue: Workspace(account: account, api: api))
    }

    var body: some View {
        @Bindable var workspace = workspace
        GeometryReader { proxy in
            SidebarShell(isOpen: $isSidebarOpen) {
                Sidebar { isSidebarOpen = false }
            } content: {
                VStack(spacing: 0) {
                    // The page below takes its top spacing from where it sits in the window, so it
                    // clears the bar. The bar itself is in the sidebar's full-screen frame, so it
                    // leaves room for the status bar on its own.
                    if let call = workspace.call, !call.isOver, !workspace.isShowingCall {
                        CallBar(call: call, statusBarHeight: proxy.safeAreaInsets.top)
                    }
                    area
                }
                .background(Color(.systemBackground))
            }
        }
        .environment(workspace)
        .task { await workspace.load() }
        .task { await notifications.requestPermission() }
        .onOpenURL(perform: open)
        .task(id: notifications.opened) {
            guard let url = notifications.opened else { return }
            notifications.opened = nil
            open(url)
        }
        .fullScreenCover(item: $workspace.page) { WebPageScreen(route: $0, api: workspace.api) }
        .fullScreenCover(isPresented: $workspace.isShowingCall) {
            if let call = workspace.call { CallScreen(call: call).environment(workspace) }
        }
        .alert("Something went wrong", isPresented: Binding { workspace.error != nil } set: { _ in workspace.error = nil }) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspace.error ?? "")
        }
    }

    /// Opens a `suite://` link, or a site link, which a notification may give relative to the site.
    private func open(_ url: URL) {
        let url = URL(string: url.absoluteString, relativeTo: workspace.account.site)?.absoluteURL ?? url
        if let link = SuiteLink(url, site: workspace.account.site) { workspace.open(link) }
    }

    @ViewBuilder
    private var area: some View {
        switch workspace.area {
        case .home: NavigationStack { HomeScreen() }
        case .drive: DriveStack()
        case .mail: MailScreen()
        case .calendar: NavigationStack { CalendarScreen() }
        case .meet: NavigationStack { MeetScreen() }
        }
    }
}

/// The apps, starred and recent documents, and the account, laid out like ChatGPT's sidebar.
private struct Sidebar: View {
    let close: () -> Void

    @Environment(Workspace.self) private var workspace
    @State private var starred: [DriveNode] = []
    @State private var recents: [DriveNode] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SuiteArea.allCases) { area in
                        row(area.title, icon: Image(area.image), badge: badge(area), isSelected: workspace.area == area) {
                            workspace.area = area
                            close()
                        }
                        .accessibilityIdentifier("sidebar.\(area.rawValue)")
                    }
                    documents("Starred", starred)
                    documents("Recent", recents)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            footer
        }
        .background(Color(.systemBackground))
        .task { await loadDocuments() }
    }

    private var header: some View {
        HStack {
            Text(workspace.name ?? "Suite")
                .font(.title2.bold())
                .lineLimit(1)
            Spacer()
            AccountMenu()
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func documents(_ title: String, _ nodes: [DriveNode]) -> some View {
        if !nodes.isEmpty {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.top, 24)
                .padding(.bottom, 4)
            ForEach(nodes) { node in
                let type = FileType(node)
                row(node.title, icon: type.image, tint: type.color) {
                    workspace.page = .document(node)
                    close()
                }
            }
        }
    }

    private func row(
        _ title: String, icon: Image?, tint: Color = .primary, badge: Int = 0, isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon {
                    icon.resizable().frame(width: 22, height: 22).foregroundStyle(tint)
                }
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                if badge > 0 { Text("\(badge)").font(.subheadline).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(isSelected ? Color(.tertiarySystemFill) : .clear, in: .rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                workspace.area = .drive
                workspace.isSearchingDrive = true
                close()
            } label: {
                Label("Search files", systemImage: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: .capsule)
            }
            .buttonStyle(.plain)
            Menu {
                ForEach(DocumentKind.allCases) { kind in
                    Button {
                        close()
                        Task { await workspace.newDocument(kind) }
                    } label: {
                        kind.menuLabel
                    }
                }
            } label: {
                Label("New", systemImage: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color(.systemBackground))
                    .padding(.horizontal, 18)
                    .frame(height: 48)
                    .background(Color.accentColor, in: .capsule)
            }
            .accessibilityIdentifier("sidebar.new")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func badge(_ area: SuiteArea) -> Int {
        area == .mail ? workspace.mail.unread : 0
    }

    private func loadDocuments() async {
        async let starred = try? workspace.drive.view(.favourites, cursor: nil)
        async let recents = try? workspace.drive.view(.recents, cursor: nil)
        self.starred = Array((await starred?.rows ?? []).filter { DocumentKind($0) != nil }.prefix(4))
        let starredIDs = Set(self.starred.map(\.id))
        // A starred document is listed once, under Starred.
        self.recents = Array((await recents?.rows ?? []).filter { DocumentKind($0) != nil && !starredIDs.contains($0.id) }.prefix(8))
    }
}

/// The person's initial, opening a menu with their name, site, and Sign out.
private struct AccountMenu: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppSession.self) private var session

    var body: some View {
        Menu {
            Section("\(workspace.account.fullName)\n\(workspace.account.site.host() ?? "")") {
                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    Task { await session.signOut() }
                }
            }
        } label: {
            Avatar(name: workspace.account.fullName, size: 36)
        }
        .accessibilityLabel("Account")
    }
}
