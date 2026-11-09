import SwiftUI

/// How Drive lays out a folder or view. One choice for every screen, remembered between launches.
enum DriveLayout: String, CaseIterable, Identifiable {
    case list, grid

    static let storageKey = "drive.layout"

    var id: String { rawValue }
    var title: String { self == .list ? "List" : "Grid" }
    var systemImage: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

/// The List and Grid choice, for a screen's view options menu.
struct DriveLayoutPicker: View {
    @AppStorage(DriveLayout.storageKey) private var layout = DriveLayout.list

    var body: some View {
        Picker("View", selection: $layout) {
            ForEach(DriveLayout.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
        }
        .pickerStyle(.inline)
    }
}

/// A node as a card: its preview, or its type icon, over its name. Used by Drive's grid.
struct NodeCard: View {
    let node: DriveNode
    let api: APIClient
    var isOpening = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay { NodePreview(node: node, api: api, iconSide: 32) }
                .clipShape(.rect(cornerRadius: 12))
                .card()
                .overlay(alignment: .topTrailing) { badge.padding(8) }
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(node.details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private var badge: some View {
        if isOpening {
            ProgressView()
        } else if node.favourite == true {
            Image(systemName: "star.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(5)
                .background(.regularMaterial, in: .circle)
                .accessibilityLabel("Starred")
        }
    }
}

/// The server's preview image filling its frame, or the node's type icon centered in it.
struct NodePreview: View {
    let node: DriveNode
    let api: APIClient
    let iconSide: CGFloat

    var body: some View {
        if let reference = node.preview?.url, let url = api.resolve(reference) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    icon
                }
            }
        } else {
            icon
        }
    }

    private var icon: some View {
        let type = FileType(node)
        return type.image.resizable().frame(width: iconSide, height: iconSide).foregroundStyle(type.color)
    }
}

extension DriveNode {
    /// When the node was last opened or changed, and a file's size.
    var details: String {
        var parts: [String] = []
        if let date = openedAt ?? changed {
            parts.append(date.formatted(.relative(presentation: .named)))
        }
        if kind == .file {
            parts.append(size.formatted(.byteCount(style: .file)))
        }
        return parts.joined(separator: " · ")
    }
}
