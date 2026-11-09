import SwiftUI

struct NodeRow: View {
    let node: DriveNode
    let api: APIClient
    var isOpening = false

    var body: some View {
        HStack(spacing: 12) {
            NodeThumbnail(node: node, api: api)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(node.details)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isOpening {
                ProgressView()
            } else if node.favourite == true {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Starred")
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }
}

/// A preview image when the server has one, else the node's type icon on its own.
struct NodeThumbnail: View {
    let node: DriveNode
    let api: APIClient

    var body: some View {
        if node.preview?.url != nil {
            Color.clear
                .overlay { NodePreview(node: node, api: api, iconSide: 22) }
                .frame(width: 40, height: 40)
                .clipShape(.rect(cornerRadius: 8))
                // A page preview is mostly white, so it needs an edge.
                .card(cornerRadius: 8)
        } else {
            NodePreview(node: node, api: api, iconSide: 24).frame(width: 40, height: 40)
        }
    }
}
