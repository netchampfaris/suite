import SwiftUI

/// A folder or location to open, kept small so navigation paths stay cheap to hash.
struct FolderRoute: Hashable {
    let node: String
    let title: String
}

/// One of the server's views of Drive, named the way the web app names them.
enum DriveViewRoute: Hashable {
    case shared, recents, starred, trash(root: String)

    var title: String {
        switch self {
        case .shared: "Shared with me"
        case .recents: "Recent"
        case .starred: "Starred"
        case .trash: "Trash"
        }
    }

    var systemImage: String {
        switch self {
        case .shared: "person.2"
        case .recents: "clock"
        case .starred: "star"
        case .trash: "trash"
        }
    }
}

/// Drive's first screen, laid out like the web app's Drive sidebar.
struct DriveHome: View {
    let drive: DriveClient

    @Environment(Workspace.self) private var workspace
    @State private var roots: RootLocations?
    @State private var error: String?
    @State private var term = ""

    var body: some View {
        ScrollView {
            if let roots {
                VStack(alignment: .leading, spacing: 24) {
                    group("Locations") {
                        row(RootLocations.personalTitle, systemImage: "folder",
                            value: FolderRoute(node: roots.personal.node, title: RootLocations.personalTitle))
                        if let organization = roots.organization {
                            row(workspace.organizationTitle, systemImage: "building.2",
                                value: FolderRoute(node: organization.node, title: workspace.organizationTitle))
                        }
                    }
                    group("Views") {
                        view(.shared)
                        view(.recents)
                        view(.starred)
                        view(.trash(root: roots.personal.node))
                    }
                }
                .padding(16)
            } else if let error {
                ContentUnavailableView {
                    Label("Could not load Drive", systemImage: "exclamationmark.icloud")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await load() } }
                }
            }
        }
        .overlay { if roots == nil && error == nil { ProgressView() } }
        .navigationTitle("Drive")
        .toolbar { SidebarButton() }
        .searchable(text: $term, isPresented: Bindable(workspace).isSearchingDrive, prompt: "Search files")
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .overlay { if !term.isEmpty { SearchResults(term: term, drive: drive) } }
        .task { if roots == nil { await load() } }
        .refreshable { await load() }
        .withDriveDestinations(drive)
    }

    private func view(_ route: DriveViewRoute) -> some View {
        row(route.title, systemImage: route.systemImage, value: route)
    }

    /// A gray label over a card of rows, as in Espresso's settings.
    private func group(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4)
            VStack(spacing: 0) { rows() }
                .padding(.vertical, 6)
                .card(cornerRadius: 16)
        }
    }

    private func row(_ title: String, systemImage: String, value: some Hashable) -> some View {
        NavigationLink(value: value) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).frame(width: 24).foregroundStyle(.secondary)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        do {
            roots = try await drive.roots()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension RootLocations {
    // The server stores a root's title as data, so the web app names roots by place.
    static let personalTitle = "My files"
    static let organizationTitle = "Organization files"
}

/// Drive's navigation stack. It owns the path so a folder's title menu can jump to any folder above it.
struct DriveStack: View {
    @Environment(Workspace.self) private var workspace
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            DriveHome(drive: workspace.drive)
        }
        // Rebuilding the path from the trail makes Back go up the folder tree,
        // even when the folder was opened from Recent or search.
        .environment(\.openDriveFolder, OpenDriveFolderAction { path = NavigationPath($0) })
        .task(id: workspace.link) { await openLink() }
    }

    /// Opens a linked folder, or a linked document in its editor. Any other file opens the folder that holds it.
    private func openLink() async {
        guard case .driveNode(let name) = workspace.link else { return }
        // Cleared once done: clearing it changes this task's id, which would cancel the lookup.
        defer { workspace.link = nil }
        do {
            let (node, trail) = try await workspace.drive.locate(name)
            if DocumentKind(node) != nil {
                workspace.page = .document(node)
                return
            }
            var folders = trail.filter(\.isFolder).map { FolderRoute(node: $0.name, title: workspace.folderTitle($0)) }
            if node.isContainer { folders.append(FolderRoute(node: node.name, title: node.title)) }
            path = NavigationPath(folders)
        } catch {
            workspace.error = error.localizedDescription
        }
    }
}

/// Replaces Drive's stack with a folder and the folders above it, top first.
struct OpenDriveFolderAction {
    let open: @MainActor ([FolderRoute]) -> Void
    @MainActor func callAsFunction(_ trail: [FolderRoute]) { open(trail) }
}

extension EnvironmentValues {
    @Entry var openDriveFolder: OpenDriveFolderAction?
}

extension View {
    func withDriveDestinations(_ drive: DriveClient) -> some View {
        navigationDestination(for: FolderRoute.self) { route in
            FolderScreen(route: route, drive: drive)
        }
        .navigationDestination(for: DriveViewRoute.self) { route in
            DriveViewScreen(route: route, drive: drive)
        }
    }
}

/// Shared with me, Recent, Starred, or Trash.
struct DriveViewScreen: View {
    let route: DriveViewRoute
    @State private var list: NodeList

    init(route: DriveViewRoute, drive: DriveClient) {
        self.route = route
        _list = State(initialValue: NodeList(drive: drive) { drive, cursor in
            switch route {
            case .shared: try await drive.view(.shared, cursor: cursor)
            case .recents: try await drive.view(.recents, cursor: cursor)
            case .starred: try await drive.view(.favourites, cursor: cursor)
            case .trash(let root): try await drive.view(.trash, root: root, cursor: cursor)
            }
        })
    }

    var body: some View {
        NodeListView(list: list) {
            ContentUnavailableView(empty.title, systemImage: route.systemImage, description: Text(empty.message))
        }
        .navigationTitle(route.title)
        .toolbar {
            Menu("View options", systemImage: "ellipsis") { DriveLayoutPicker() }
        }
    }

    private var empty: (title: String, message: String) {
        switch route {
        case .shared: ("Nothing shared with you yet", "Files and folders that people share with you will appear here.")
        case .recents: ("No recent files", "Files you open will appear here.")
        case .starred: ("No starred files", "Star a file or folder to find it here quickly.")
        case .trash: ("Trash is empty", "Items you move to Trash stay here for 30 days, then are deleted forever.")
        }
    }
}

/// Search results across every Drive the person can read, shown over Drive's first screen.
private struct SearchResults: View {
    let term: String
    @State private var list: NodeList
    @State private var searched: String?

    init(term: String, drive: DriveClient) {
        self.term = term
        _list = State(initialValue: NodeList(drive: drive) { _, _ in Page(rows: [], nextCursor: nil) })
    }

    var body: some View {
        NodeListView(list: list) {
            if searched == term {
                ContentUnavailableView("No results for “\(term)”", systemImage: "magnifyingglass", description: Text("Try a different search term."))
            }
        }
        .background(Color(.systemBackground))
        .task(id: term) {
            let query = term.trimmingCharacters(in: .whitespaces)
            // Wait for a pause in typing before asking the server.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, !query.isEmpty else { return }
            await list.replaceSource { drive, cursor in
                try await drive.view(.search, term: query, cursor: cursor)
            }
            searched = term
        }
    }
}
