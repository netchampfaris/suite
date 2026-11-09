import SwiftUI

/// Picks a folder to move a node into, and warns when the move would give more people access.
struct MoveSheet: View {
    let node: DriveNode
    let drive: DriveClient
    let onMoved: (DriveNode) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(Workspace.self) private var workspace
    @State private var roots: [Destination] = []
    @State private var pending: Pending?
    @State private var failure: String?
    @State private var isMoving = false

    var body: some View {
        NavigationStack {
            List(roots) { root in
                NavigationLink(value: root) {
                    Label(root.title, systemImage: root.title == RootLocations.personalTitle ? "folder" : "building.2")
                }
            }
            .navigationTitle("Move “\(node.title)”")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Destination.self) { folder in
                FolderChoice(folder: folder, moving: node, drive: drive, isMoving: isMoving) { await choose(folder) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { await loadRoots() }
            .confirmationDialog("Move and Share?", isPresented: isConfirming, titleVisibility: .visible, presenting: pending) { pending in
                Button("Move") { Task { await move(to: pending.folder) } }
            } message: { pending in
                Text(pending.gains == 1
                    ? "1 more person or group will get access to “\(node.title)” in “\(pending.folder.title)”."
                    : "\(pending.gains) more people or groups will get access to “\(node.title)” in “\(pending.folder.title)”.")
            }
            .alert("Can't Move", isPresented: Binding { failure != nil } set: { if !$0 { failure = nil } }) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
        }
    }

    /// The roots, named as the Drive screen names them.
    private func loadRoots() async {
        do {
            let locations = try await drive.roots()
            roots = [Destination(node: locations.personal.node, title: RootLocations.personalTitle)]
            if let organization = locations.organization {
                roots.append(Destination(node: organization.node, title: workspace.organizationTitle))
            }
        } catch {
            failure = message(error)
        }
    }

    /// Asks first when the folder is shared with people the node is not.
    private func choose(_ folder: Destination) async {
        isMoving = true
        defer { isMoving = false }
        do {
            let preview = try await drive.previewMove(node.name, to: folder.node)
            if preview.gains.isEmpty {
                await move(to: folder)
            } else {
                pending = Pending(folder: folder, gains: preview.gains.count)
            }
        } catch {
            failure = message(error)
        }
    }

    private func move(to folder: Destination) async {
        isMoving = true
        defer { isMoving = false }
        do {
            onMoved(try await drive.move(node.name, to: folder.node, from: node.parentNode))
            dismiss()
        } catch {
            failure = message(error)
        }
    }

    private var isConfirming: Binding<Bool> {
        Binding { pending != nil } set: { if !$0 { pending = nil } }
    }

    private func message(_ error: any Error) -> String {
        (error as? APIError)?.message ?? error.localizedDescription
    }

    private struct Pending {
        let folder: Destination
        let gains: Int
    }
}

/// A folder the node could move into.
private struct Destination: Hashable, Identifiable {
    let node: String
    let title: String

    var id: String { node }
}

/// One folder's subfolders, and Move Here for the folder itself.
private struct FolderChoice: View {
    let folder: Destination
    let moving: DriveNode
    let drive: DriveClient
    let isMoving: Bool
    let choose: () async -> Void

    @State private var folders: [DriveNode]?

    var body: some View {
        List(folders ?? []) { child in
            NavigationLink(value: Destination(node: child.name, title: child.title)) {
                Label(child.title, systemImage: "folder")
            }
        }
        .accessibilityIdentifier("move.folders")
        .overlay {
            if folders == nil {
                ProgressView()
            } else if folders?.isEmpty == true {
                ContentUnavailableView("No Folders", systemImage: "folder", description: Text("“\(folder.title)” has no folders inside."))
            }
        }
        .navigationTitle(folder.title)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    Task { await choose() }
                } label: {
                    Text(isHere ? "Already Here" : "Move Here").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isHere || isMoving)
            }
        }
        .task { await load() }
    }

    private var isHere: Bool { folder.node == moving.parentNode }

    /// Folders come first in a listing, so the first page holds them unless a folder has very many.
    private func load() async {
        let page = try? await drive.children(of: folder.node, sort: .title, cursor: nil)
        // A folder cannot move into itself.
        folders = (page?.rows ?? []).filter { $0.isContainer && $0.name != moving.name }
    }
}
