import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Uploads picked files one at a time and shows how far along they are.
@MainActor
@Observable
final class UploadQueue {
    struct Item: Identifiable {
        let id = UUID()
        let name: String
        var progress: Double = 0
        var error: String?
    }

    private(set) var items: [Item] = []
    private let uploader: Uploader
    private struct Job {
        let item: UUID
        let file: URL
        let folder: String
        let done: (DriveNode) -> Void
    }

    private var pending: [Job] = []
    private var isRunning = false

    init(uploader: Uploader) {
        self.uploader = uploader
    }

    var active: [Item] { items.filter { $0.error == nil } }
    var failed: [Item] { items.filter { $0.error != nil } }

    func add(_ files: [URL], into folder: String, done: @escaping (DriveNode) -> Void) {
        for file in files {
            let item = Item(name: file.lastPathComponent)
            items.append(item)
            pending.append(Job(item: item.id, file: file, folder: folder, done: done))
        }
        guard !isRunning else { return }
        Task { await run() }
    }

    func dismissFailures() {
        items.removeAll { $0.error != nil }
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false }
        while !pending.isEmpty {
            let job = pending.removeFirst()
            let id = job.item
            do {
                let node = try await uploader.upload(job.file, into: job.folder) { fraction in
                    Task { @MainActor in self.update(id) { $0.progress = fraction } }
                }
                items.removeAll { $0.id == id }
                job.done(node)
            } catch {
                update(id) { $0.error = error.localizedDescription }
            }
            try? FileManager.default.removeItem(at: job.file.deletingLastPathComponent())
        }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }
}

/// A slim bar above the tab bar while uploads run, and a note when one fails.
struct UploadBanner: View {
    let queue: UploadQueue

    var body: some View {
        if let current = queue.active.first {
            HStack(spacing: 12) {
                ProgressView(value: current.progress)
                    .progressViewStyle(.circular)
                VStack(alignment: .leading, spacing: 2) {
                    Text(queue.active.count == 1 ? "Uploading \(current.name)" : "Uploading \(queue.active.count) items")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    ProgressView(value: current.progress)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
            .padding(.horizontal)
            .padding(.bottom, 8)
        } else if let failure = queue.failed.first {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Couldn't upload \(failure.name)").font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(failure.error ?? "").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button("Dismiss") { queue.dismissFailures() }.font(.subheadline)
            }
            .padding(12)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}

/// Turns what the pickers hand back into plain files the app owns until upload ends.
enum PickedFile {
    /// Copies a Files-app pick out of its security scope, since the upload outlives it.
    static func copy(securityScoped url: URL) -> URL? {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let destination = freshFolder().appending(path: url.lastPathComponent)
        return (try? FileManager.default.copyItem(at: url, to: destination)) == nil ? nil : destination
    }

    static func load(_ items: [PhotosPickerItem]) async -> [URL] {
        var files: [URL] = []
        for item in items {
            if let picked = try? await item.loadTransferable(type: PhotoFile.self) { files.append(picked.url) }
        }
        return files
    }

    fileprivate static func freshFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "uploads/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// A photo or video from the library, kept as its original file and name.
private struct PhotoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie, importing: received)
        FileRepresentation(importedContentType: .image, importing: received)
    }

    private static func received(_ file: ReceivedTransferredFile) throws -> PhotoFile {
        let destination = PickedFile.freshFolder().appending(path: file.file.lastPathComponent)
        try FileManager.default.copyItem(at: file.file, to: destination)
        return PhotoFile(url: destination)
    }
}
