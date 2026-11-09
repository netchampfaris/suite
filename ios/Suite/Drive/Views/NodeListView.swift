import QuickLook
import SwiftUI

/// Draws a `NodeList` as rows or a grid of cards, with paging, pull to refresh, and the actions on each node.
///
/// Folders push a `FolderRoute`. Suite documents open in the web editor, other files
/// download and open in Quick Look, and links open in the browser. Trashed nodes get Restore and Delete instead of the usual actions.
struct NodeListView<Empty: View>: View {
    let list: NodeList
    @ViewBuilder let empty: () -> Empty

    @State private var opener = FileOpener()
    @State private var renaming: DriveNode?
    @State private var newTitle = ""
    @State private var purging: DriveNode?
    @State private var moving: DriveNode?
    @State private var sharing: DriveNode?
    @State private var page: WebRoute?
    @AppStorage(DriveLayout.storageKey) private var layout = DriveLayout.list
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            switch layout {
            case .list: rows
            case .grid: grid
            }
        }
        .overlay { overlay }
        // SwiftUI keeps a screen's list while it is off screen, such as a tab not in
        // view or Trash between visits, so load again whenever it comes back.
        .task { await list.reload() }
        .refreshable { await list.reload() }
        .quickLookPreview($opener.file)
        .fullScreenCover(item: $page) { WebPageScreen(route: $0, api: list.drive.api) }
        // A moved node may leave this list or change its place in it, so list it again.
        .sheet(item: $moving) { MoveSheet(node: $0, drive: list.drive) { _ in Task { await list.reload() } } }
        .sheet(item: $sharing) { ShareSheet(node: $0, drive: list.drive) }
        .alert("Rename", isPresented: isRenaming) {
            TextField("Name", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { commitRename() }
        }
        .confirmationDialog(
            "Delete “\(purging?.title ?? "")” forever?",
            isPresented: isPurging,
            titleVisibility: .visible
        ) {
            Button("Delete Forever", role: .destructive) {
                if let node = purging { Task { await list.purge(node) } }
            }
        } message: {
            Text("You can't undo this.")
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { clearFailure() } }),
            presenting: failure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: Layouts

    private var rows: some View {
        List {
            ForEach(list.nodes) { node in
                item(for: node) { NodeRow(node: node, api: list.drive.api, isOpening: $0) }
                    .contextMenu { menu(for: node) }
                    .swipeActions(edge: .trailing) { trailingSwipe(for: node) }
                    .swipeActions(edge: .leading) { leadingSwipe(for: node) }
                    .listRowSeparator(.hidden)
            }
            if list.canLoadMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .task { await list.loadMore() }
            }
        }
        .listStyle(.plain)
    }

    /// Cards in as many columns as fit, at least two on a phone. A long press gives the same actions as a row's swipes.
    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)], spacing: 16) {
                ForEach(list.nodes) { node in
                    item(for: node) { NodeCard(node: node, api: list.drive.api, isOpening: $0) }
                        .buttonStyle(.plain)
                        .contextMenu { menu(for: node) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            if list.canLoadMore {
                ProgressView()
                    .padding()
                    .task { await list.loadMore() }
            }
        }
    }

    /// A folder pushes its contents; anything else opens. `label` is told whether the node is opening.
    @ViewBuilder
    private func item(for node: DriveNode, @ViewBuilder label: (Bool) -> some View) -> some View {
        if node.isContainer && !node.isTrashed {
            NavigationLink(value: FolderRoute(node: node.name, title: node.title)) { label(false) }
        } else {
            Button { open(node) } label: { label(opener.opening == node.id) }
                .tint(.primary)
                .disabled(node.isTrashed)
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if !list.hasLoaded && list.isLoading {
            ProgressView()
        } else if list.hasLoaded && list.nodes.isEmpty {
            empty()
        }
    }

    // MARK: Actions

    @ViewBuilder
    private func menu(for node: DriveNode) -> some View {
        if node.isTrashed {
            Button("Restore", systemImage: "arrow.uturn.backward") { Task { await list.restore(node) } }
            Button("Delete Forever", systemImage: "trash.slash", role: .destructive) { purging = node }
        } else {
            let starred = node.favourite ?? false
            Button(starred ? "Unstar" : "Star", systemImage: starred ? "star.slash" : "star") {
                Task { await list.toggleFavourite(node) }
            }
            Button("Rename", systemImage: "pencil") { startRename(node) }
            Button("Move", systemImage: "folder") { moving = node }
            Button("Share", systemImage: "person.crop.circle.badge.plus") { sharing = node }
            Divider()
            Button("Move to Trash", systemImage: "trash", role: .destructive) { Task { await list.trash(node) } }
        }
    }

    @ViewBuilder
    private func trailingSwipe(for node: DriveNode) -> some View {
        if node.isTrashed {
            Button("Delete", systemImage: "trash.slash") { purging = node }.tint(.red)
        } else {
            Button("Trash", systemImage: "trash", role: .destructive) { Task { await list.trash(node) } }
        }
    }

    @ViewBuilder
    private func leadingSwipe(for node: DriveNode) -> some View {
        if node.isTrashed {
            Button("Restore", systemImage: "arrow.uturn.backward") { Task { await list.restore(node) } }.tint(.swipe)
        } else {
            let starred = node.favourite ?? false
            Button(starred ? "Unstar" : "Star", systemImage: starred ? "star.slash" : "star") {
                Task { await list.toggleFavourite(node) }
            }
            .tint(.swipe)
        }
    }

    private func open(_ node: DriveNode) {
        if node.kind == .link, let address = node.url, let url = URL(string: address) {
            openURL(url)
        } else if DocumentKind(node) != nil {
            page = .document(node)
        } else {
            Task { await opener.open(node, with: list.drive) }
        }
    }

    private func startRename(_ node: DriveNode) {
        newTitle = node.title
        renaming = node
    }

    private func commitRename() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let node = renaming, !title.isEmpty, title != node.title else { return }
        Task { await list.rename(node, to: title) }
    }

    // MARK: State bindings

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var isPurging: Binding<Bool> {
        Binding(get: { purging != nil }, set: { if !$0 { purging = nil } })
    }

    private var failure: String? {
        list.error?.message ?? opener.error
    }

    private func clearFailure() {
        list.error = nil
        opener.error = nil
    }
}
