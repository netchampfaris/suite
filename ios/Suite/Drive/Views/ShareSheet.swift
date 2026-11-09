import SwiftUI

/// Who has access to a node, and adding, changing, or removing people and groups.
///
/// Share links and publishing to the web stay on the web app; their rows show here without changes.
struct ShareSheet: View {
    let node: DriveNode
    let drive: DriveClient

    @Environment(\.dismiss) private var dismiss
    @State private var access: Grants?
    @State private var loadError: String?
    @State private var failure: String?
    @State private var query = ""
    @State private var isSearching = false
    @State private var candidates: [Candidate] = []
    @State private var newRole = DriveRole.view

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Share “\(node.title)”")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, isPresented: $isSearching, placement: .navigationBarDrawer(displayMode: .always), prompt: "Add people or groups")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        ShareLink(item: drive.api.site.appending(path: "drive/f/\(node.name)")) {
                            Label("Send Link", systemImage: "link")
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .task { await load() }
                .task(id: query) { await search() }
                .alert("Something Went Wrong", isPresented: Binding { failure != nil } set: { if !$0 { failure = nil } }) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(failure ?? "")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ContentUnavailableView("Can't Show Access", systemImage: "lock", description: Text(loadError))
        } else if access == nil {
            ProgressView()
        } else {
            List {
                if query.isEmpty { people } else { results }
            }
        }
    }

    // MARK: Who has access

    @ViewBuilder
    private var people: some View {
        Section("People with access") {
            if let owner = access?.owner {
                row(title: owner.fullName, subtitle: owner.id, icon: .initial(owner.fullName)) {
                    Text("Owner").foregroundStyle(.secondary)
                }
            }
            ForEach(access?.grants.filter { !$0.isDeny } ?? []) { grant in
                let (title, subtitle, icon) = describe(grant)
                row(title: title, subtitle: subtitle, icon: icon) { roleControl(for: grant) }
            }
        }
    }

    @ViewBuilder
    private func roleControl(for grant: Grant) -> some View {
        let label = DriveRole(rawValue: grant.role)?.label ?? "Custom"
        switch grant.who {
        case .link, .anyone:
            Text(label).foregroundStyle(.secondary)
        case .user, .group, .everyone:
            Menu {
                Picker("Access", selection: Binding { DriveRole(rawValue: grant.role) } set: { role in
                    if let role { Task { await change(grant.principal, to: role) } }
                }) {
                    ForEach(DriveRole.choices(for: node)) { Text($0.label).tag(Optional($0)) }
                }
                Divider()
                Button("Remove Access", systemImage: "person.badge.minus", role: .destructive) {
                    Task { await remove(grant.principal) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(label)
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                }
            }
            .accessibilityLabel("\(label) access")
        }
    }

    private func describe(_ grant: Grant) -> (String, String?, RowIcon) {
        switch grant.who {
        case .user(let id):
            let name = grant.person?.fullName ?? id
            return (name, id, .initial(name))
        case .group(let name): return (name, "Group", .symbol("person.3"))
        case .everyone: return ("Everyone in the workspace", nil, .symbol("building.2"))
        case .link: return ("Anyone with the link", nil, .symbol("link"))
        case .anyone: return ("Anyone on the web", nil, .symbol("globe"))
        }
    }

    // MARK: Adding people

    @ViewBuilder
    private var results: some View {
        Section {
            Picker("New people can", selection: $newRole) {
                ForEach(DriveRole.choices(for: node)) { Text($0.label).tag($0) }
            }
        }
        Section {
            ForEach(candidates) { candidate in
                Button {
                    Task { await add(candidate) }
                } label: {
                    if candidate.kind == "group" {
                        row(title: candidate.title, subtitle: members(candidate), icon: .symbol("person.3")) { EmptyView() }
                    } else {
                        row(title: candidate.title, subtitle: candidate.name, icon: .initial(candidate.title)) { EmptyView() }
                    }
                }
                .tint(.primary)
            }
        } footer: {
            if candidates.isEmpty { Text("No one matches “\(query)”.") }
        }
    }

    private func members(_ group: Candidate) -> String {
        guard let count = group.memberCount else { return "Group" }
        return count == 1 ? "Group, 1 person" : "Group, \(count) people"
    }

    // MARK: Rows

    private enum RowIcon {
        case initial(String)
        case symbol(String)
    }

    private func row(title: String, subtitle: String?, icon: RowIcon, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 12) {
            switch icon {
            case .initial(let name): Avatar(name: name, size: 36)
            case .symbol(let name):
                Image(systemName: name)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Color(.tertiarySystemFill), in: .circle)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if let subtitle, subtitle != title {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }

    // MARK: Changes

    private func load() async {
        do {
            access = try await drive.grants(of: node.name)
        } catch {
            loadError = (error as? APIError)?.status == 403
                ? "Only people who can manage “\(node.title)” can see who has access."
                : message(error)
        }
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let found = try? await drive.people(matching: term) else { return }
        // People who already have their own row are changed there, not added again.
        let listed = Set(access?.grants.filter { !$0.isDeny }.map(\.principal) ?? [])
        candidates = found.filter { !listed.contains($0.principal) }
    }

    private func add(_ candidate: Candidate) async {
        await write { try await drive.share(node.name, with: candidate.principal, as: newRole) }
        // Back to the list, where the person just added now shows.
        isSearching = false
        query = ""
    }

    private func change(_ principal: String, to role: DriveRole) async {
        await write { try await drive.share(node.name, with: principal, as: role) }
    }

    private func remove(_ principal: String) async {
        await write { try await drive.unshare(node.name, from: principal) }
    }

    /// Runs a change, then lists access again, since a change can touch more than its own row.
    private func write(_ change: () async throws -> Void) async {
        do {
            try await change()
            access = try await drive.grants(of: node.name)
        } catch {
            failure = message(error)
        }
    }

    private func message(_ error: any Error) -> String {
        (error as? APIError)?.message ?? error.localizedDescription
    }
}
