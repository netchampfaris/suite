import Foundation
import Observation

/// Downloads a node and hands the local copy to Quick Look.
@MainActor
@Observable
final class FileOpener {
    /// The local file Quick Look shows. Setting it to nil closes the preview.
    var file: URL?
    private(set) var opening: String?
    var error: String?

    func open(_ node: DriveNode, with drive: DriveClient) async {
        guard opening == nil else { return }
        opening = node.id
        defer { opening = nil }
        do {
            file = try await drive.download(node)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
