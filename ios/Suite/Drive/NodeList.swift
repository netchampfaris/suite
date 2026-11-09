import Foundation
import Observation

/// One pageable list of nodes and the changes a person makes to it.
///
/// A folder, a discovery view, and search results all differ only in where the
/// pages come from, so each screen hands this a `source` and shares the rest.
@MainActor
@Observable
final class NodeList {
    typealias Source = @Sendable (DriveClient, String?) async throws -> Page<DriveNode>

    private(set) var nodes: [DriveNode] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    var error: APIError?

    let drive: DriveClient
    private var source: Source
    private var cursor: String?
    private var generation = 0

    init(drive: DriveClient, source: @escaping Source) {
        self.drive = drive
        self.source = source
    }

    var canLoadMore: Bool { cursor != nil && !isLoading }

    /// Points the list at new pages, such as a new sort or search term, and reloads.
    func replaceSource(_ source: @escaping Source) async {
        self.source = source
        await reload()
    }

    func reload() async {
        generation += 1
        let current = generation
        isLoading = true
        defer { if current == generation { isLoading = false } }
        do {
            let page = try await source(drive, nil)
            // A newer reload started while this one waited; its answer wins.
            guard current == generation else { return }
            nodes = page.rows
            cursor = page.nextCursor
            hasLoaded = true
        } catch {
            guard current == generation, !(error is CancellationError) else { return }
            report(error)
        }
    }

    func loadMore() async {
        guard let cursor, !isLoading else { return }
        let current = generation
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await source(drive, cursor)
            guard current == generation else { return }
            nodes.append(contentsOf: page.rows.filter { row in !nodes.contains { $0.id == row.id } })
            self.cursor = page.nextCursor
        } catch {
            report(error)
        }
    }

    // MARK: Changes

    /// Adds a node the person just made, folders first and then by name.
    func insert(_ node: DriveNode) {
        nodes.removeAll { $0.id == node.id }
        let index = nodes.firstIndex { other in
            if other.isContainer != node.isContainer { return node.isContainer }
            return other.title.localizedStandardCompare(node.title) == .orderedDescending
        }
        nodes.insert(node, at: index ?? nodes.endIndex)
    }

    func rename(_ node: DriveNode, to title: String) async {
        do {
            replace(node, with: try await drive.rename(node.name, to: title))
        } catch {
            report(error)
        }
    }

    func trash(_ node: DriveNode) async {
        await remove(node) { try await $0.trash(node.name) }
    }

    func restore(_ node: DriveNode) async {
        await remove(node) { try await $0.restore(node.name) }
    }

    func purge(_ node: DriveNode) async {
        await remove(node) { try await $0.purge(node.name) }
    }

    /// Stars at once, and puts the star back if the server refuses.
    func toggleFavourite(_ node: DriveNode) async {
        let on = !(node.favourite ?? false)
        setFavourite(node.id, on)
        do {
            try await drive.setFavourite(node.name, on)
        } catch {
            setFavourite(node.id, !on)
            report(error)
        }
    }

    // MARK: Helpers

    /// Runs a write that takes the node out of this list, and drops it once the server agrees.
    private func remove<Result>(_ node: DriveNode, by write: (DriveClient) async throws -> Result) async {
        do {
            _ = try await write(drive)
            nodes.removeAll { $0.id == node.id }
        } catch {
            report(error)
        }
    }

    private func replace(_ node: DriveNode, with updated: DriveNode) {
        guard let index = nodes.firstIndex(where: { $0.id == node.id }) else { return }
        var merged = updated
        // A write answers without the caller's own star or the preview, so keep them.
        merged.favourite = node.favourite
        merged.preview = node.preview
        nodes[index] = merged
    }

    private func setFavourite(_ id: String, _ on: Bool) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].favourite = on
    }

    private func report(_ error: any Error) {
        self.error = error as? APIError ?? APIError(type: "RequestError", message: error.localizedDescription, status: 0)
    }
}
