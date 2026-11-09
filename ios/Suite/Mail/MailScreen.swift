import SwiftUI

/// One mailbox's threads, with the mailbox picked from the title menu.
struct MailScreen: View {
    @Environment(Workspace.self) private var workspace
    @State private var mailbox = Mailbox.inbox
    @State private var category = MailCategory.primary
    @State private var isUnreadOnly = false
    @State private var composing: Draft?
    @State private var query = ""
    @State private var path: [String] = []

    private var store: MailStore { workspace.mail }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The threads on screen: search results from every mailbox, or one mailbox's list.
    /// The inbox splits by category, and the filter can hide read mail.
    private var threads: [MailThread] {
        let shown = isSearching ? store.searchResults : store.threads(in: mailbox, category: category)
        return shown.filter { !isUnreadOnly || !$0.isRead }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if mailbox == .inbox && !store.categories.isEmpty && !isSearching {
                    CategoryPills(selection: $category, store: store)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                }
                ForEach(threads) { thread in
                    // A hidden link opens the thread without the row's disclosure arrow, as in Mail.
                    ThreadRow(thread: thread)
                        .background {
                            // A draft opens for more writing, not for reading.
                            if thread.mailbox == .drafts {
                                Button("") { composing = store.edit(thread) }.opacity(0)
                            } else {
                                NavigationLink("", value: thread.id).opacity(0)
                            }
                        }
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .leading) {
                            Button(thread.isRead ? "Unread" : "Read", systemImage: thread.isRead ? "envelope.badge" : "envelope.open") {
                                store.markRead(thread.id, !thread.isRead)
                            }
                            .tint(.swipe)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Trash", systemImage: "trash", role: .destructive) { store.move(thread.id, to: .trash) }
                            if thread.mailbox != .archive {
                                Button("Archive", systemImage: "archivebox") { store.move(thread.id, to: .archive) }
                                    .tint(.swipe)
                            }
                        }
                }
                if !threads.isEmpty && !isSearching && store.hasMore(mailbox, category: category) {
                    // Reaching the end of the list fetches the next page.
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                        .task(id: threads.count) { await store.loadMore(mailbox, category: category) }
                }
                if store.isSample {
                    SampleNotice()
                        .listRowSeparator(.hidden, edges: .bottom)
                }
            }
            .listStyle(.plain)
            .animation(.snappy, value: threads.map(\.id))
            .overlay {
                if threads.isEmpty && (store.isLoading || store.isSearching) {
                    ProgressView()
                } else if threads.isEmpty && isSearching {
                    ContentUnavailableView.search(text: query)
                } else if threads.isEmpty {
                    ContentUnavailableView(isUnreadOnly ? "No unread mail" : "No mail here", systemImage: mailbox.systemImage)
                }
            }
            .task(id: ListID(mailbox: mailbox, category: category, isSample: store.isSample)) {
                await store.load(mailbox, category: category)
            }
            .refreshable { await store.load(mailbox, category: category) }
            .searchable(text: $query, prompt: "Search mail")
            .task(id: query) {
                // Waits for a pause in typing, so each keystroke does not start a search.
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await store.search(query)
            }
            .alert("Mail could not be updated", isPresented: Binding { store.error != nil } set: { _ in store.error = nil }) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.error ?? "")
            }
            .navigationTitle(mailbox.title)
            // A large title cannot open the title menu, so the mailbox name stays inline, as in Calendar.
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu {
                Picker("Mailbox", selection: $mailbox) {
                    ForEach(Mailbox.standard) { box in
                        Label(box == .inbox && store.unread > 0 ? "Inbox (\(store.unread))" : box.title, systemImage: box.systemImage)
                            .tag(box)
                    }
                }
                if !store.folders.isEmpty {
                    Picker("Folders", selection: $mailbox) {
                        ForEach(store.folders) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                    }
                }
            }
            .toolbar {
                SidebarButton()
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Filter", systemImage: isUnreadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") {
                        Toggle("Unread only", systemImage: "envelope.badge", isOn: $isUnreadOnly)
                        Divider()
                        Button("Mark all as read", systemImage: "envelope.open") {
                            store.markAllRead(threads.map(\.id))
                        }
                        .disabled(!threads.contains { !$0.isRead })
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Compose", systemImage: "square.and.pencil") { composing = Draft() }
                }
            }
            .navigationDestination(for: String.self) { id in
                ThreadScreen(store: store, id: id) { composing = $0 }
            }
            .sheet(item: $composing) { draft in
                ComposeSheet(draft: draft, store: store)
            }
        }
        // A link that launched the app comes before the mail account connects, so it waits for it.
        .task(id: [AnyHashable(workspace.link), AnyHashable(store.isSample)]) { await openLink() }
    }

    private func openLink() async {
        guard case .mailThread(let id) = workspace.link, !store.isSample else { return }
        // Cleared once done: clearing it changes this task's id, which would cancel the fetch.
        defer { workspace.link = nil }
        if await store.fetch(id) { path = [id] }
    }
}

private struct ListID: Hashable {
    let mailbox: Mailbox
    let category: MailCategory
    let isSample: Bool
}

/// Inbox categories as pills, after Notion's tabs: the chosen one is filled and shows its name, the others only an icon.
private struct CategoryPills: View {
    @Binding var selection: MailCategory
    let store: MailStore

    var body: some View {
        HStack(spacing: 6) {
            ForEach(store.categories) { category in
                let isSelected = category == selection
                let unread = store.unread(in: category)
                Button { selection = category } label: {
                    HStack(spacing: 6) {
                        Image(systemName: category.systemImage)
                        if isSelected { Text(category.title) }
                        if unread > 0 { Text("\(unread)").foregroundStyle(.secondary) }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(isSelected ? Color(.tertiarySystemFill) : .clear, in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(category.title)
            }
            Spacer(minLength: 0)
        }
        .animation(.snappy, value: selection)
    }
}

private struct ThreadRow: View {
    let thread: MailThread

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(name: thread.latest.fromName, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(senders).font(.body.weight(thread.isRead ? .regular : .semibold)).lineLimit(1)
                    Spacer()
                    Text(thread.latest.date, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !thread.isRead {
                        Circle().fill(Color.accentColor).frame(width: 8, height: 8).accessibilityLabel("Unread")
                    }
                }
                HStack(spacing: 4) {
                    Text(thread.subject).font(.subheadline.weight(thread.isRead ? .regular : .medium)).lineLimit(1)
                    if thread.isStarred { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary) }
                    if !thread.attachments.isEmpty { Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary) }
                }
                Text(thread.latest.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var senders: String {
        let names = thread.messages.map(\.fromName).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let text = names.joined(separator: ", ")
        return thread.messages.count > 1 ? "\(text) (\(thread.messages.count))" : text
    }
}

/// A thread's messages, newest last, with reply and the usual actions.
private struct ThreadScreen: View {
    let store: MailStore
    let id: String
    let reply: (Draft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var preview: URL?
    @State private var opening: MailAttachment?
    @State private var failure: String?

    var body: some View {
        if let thread = store.thread(id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text(thread.subject).font(.title2.bold())
                    ForEach(thread.messages) { message in
                        MessageView(message: message, site: store.site)
                    }
                    ForEach(thread.attachments) { attachment in
                        Button { open(attachment) } label: { AttachmentRow(attachment: attachment, isOpening: opening == attachment) }
                            .buttonStyle(.plain)
                            .disabled(opening != nil)
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { store.markRead(id) }
            .quickLookPreview($preview)
            .alert("Could not open the attachment", isPresented: Binding { failure != nil } set: { _ in failure = nil }) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(thread.isStarred ? "Unstar" : "Star", systemImage: thread.isStarred ? "star.fill" : "star") {
                        store.toggleStar(id)
                    }
                    Button("Archive", systemImage: "archivebox") {
                        store.move(id, to: .archive)
                        dismiss()
                    }
                    Button("Trash", systemImage: "trash") {
                        store.move(id, to: .trash)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Menu("Reply", systemImage: "arrowshape.turn.up.left") {
                        Button("Reply", systemImage: "arrowshape.turn.up.left") { reply(store.reply(to: thread, all: false)) }
                        Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { reply(store.reply(to: thread, all: true)) }
                        Button("Forward", systemImage: "arrowshape.turn.up.right") { reply(store.forward(thread)) }
                    } primaryAction: {
                        reply(store.reply(to: thread, all: false))
                    }
                }
            }
        }
    }

    private func open(_ attachment: MailAttachment) {
        opening = attachment
        Task {
            defer { opening = nil }
            do {
                preview = try await store.download(attachment)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// An attachment's name and size, with a spinner while it downloads.
private struct AttachmentRow: View {
    let attachment: MailAttachment
    let isOpening: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "paperclip").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name).lineLimit(1)
                if let size = attachment.size {
                    Text(Int64(size), format: .byteCount(style: .file)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if isOpening { ProgressView() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .contentShape(.rect)
    }
}

/// One message in a thread, unboxed: who sent it and when, then the message.
private struct MessageView: View {
    let message: MailMessage
    let site: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Avatar(name: message.fromName, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.fromName).font(.subheadline.weight(.semibold))
                    Text("to \(message.to.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(message.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let html = message.html, let site {
                MailBody(html: html, site: site)
            } else {
                Text(message.body).textSelection(.enabled)
            }
        }
    }
}
