import PhotosUI
import SwiftUI

/// A message being written: new, a reply, a forward, or a saved draft opened again.
struct Draft: Identifiable {
    let id = UUID()
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""
    /// The thread a reply belongs to, so it shows there once sent.
    var threadID: String?
    /// The message a reply answers, for its `In-Reply-To` header.
    var replying: MailMessage?
    /// The message a forward quotes. Its attachments go along unless removed.
    var forwarding: MailMessage?
    /// Files already on the mail server: a forward's or a saved draft's.
    var kept: [MailAttachment] = []
    /// Files picked here, uploaded as soon as they are picked.
    var added: [ComposeFile] = []
    /// The draft's id on the server, once it has been saved.
    var savedID: String?

    var title: String {
        if forwarding != nil { "Forward" } else if replying != nil { "Reply" } else { "New message" }
    }

    /// Whether the person changed anything since the draft opened, which is when closing asks to keep it.
    func differs(from start: Draft) -> Bool {
        [to, cc, bcc, subject, body] != [start.to, start.cc, start.bcc, start.subject, start.body]
            || !added.isEmpty || kept != start.kept
    }

    var recipients: (to: [String], cc: [String], bcc: [String]) {
        (Self.addresses(to), Self.addresses(cc), Self.addresses(bcc))
    }

    /// Splits what the person typed on commas, semicolons, and spaces.
    static func addresses(_ text: String) -> [String] {
        text.split(whereSeparator: { ",; \n".contains($0) }).map(String.init)
    }

    static func isAddress(_ text: String) -> Bool {
        text.wholeMatch(of: /[^@\s]+@[^@\s]+\.[^@\s]+/) != nil
    }
}

/// A file picked while writing, and its place on the site once uploaded.
struct ComposeFile: Identifiable, Hashable {
    let id = UUID()
    let local: URL
    var uploaded: UploadedFile?
    var failed = false

    var name: String { local.lastPathComponent }
}

struct UploadedFile: Decodable, Hashable, Sendable {
    let fileUrl: String
    let fileName: String
    let fileSize: Int?
}

/// Writes a message. Closing it with something written offers to keep it as a draft.
struct ComposeSheet: View {
    @State private var draft: Draft
    private let start: Draft
    let store: MailStore

    init(draft: Draft, store: MailStore) {
        _draft = State(initialValue: draft)
        start = draft
        self.store = store
    }

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?
    @State private var showsCopies = false
    @State private var isSending = false
    @State private var isClosing = false
    @State private var isImporting = false
    @State private var isPickingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var failure: String?

    private enum Field { case to, cc, bcc, subject, body }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    field("To", text: $draft.to, focus: .to)
                    Divider()
                    if showsCopies {
                        field("Cc", text: $draft.cc, focus: .cc)
                        Divider()
                        field("Bcc", text: $draft.bcc, focus: .bcc)
                    } else {
                        Button { reveal() } label: {
                            Text("Cc/Bcc").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    Divider()
                    field("Subject", text: $draft.subject, focus: .subject)
                    Divider()
                    files
                    TextField("", text: $draft.body, axis: .vertical)
                        .focused($focus, equals: .body)
                        .accessibilityLabel("Message")
                        .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
                        .padding(16)
                    if let original = draft.forwarding {
                        ForwardedNote(message: original)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(draft.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .interactiveDismissDisabled(isSending || isEdited)
            .confirmationDialog("Keep this message?", isPresented: $isClosing, titleVisibility: .hidden) {
                Button("Save Draft") { finish { try await store.saveDraft(draft) } }
                Button("Delete Draft", role: .destructive) { finish { try await store.discard(draft) } }
            }
            .alert("Could not send", isPresented: Binding { failure != nil } set: { _ in failure = nil }) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) {
                if case .success(let urls) = $0 { attach(urls.compactMap(PickedFile.copy(securityScoped:))) }
            }
            .photosPicker(isPresented: $isPickingPhotos, selection: $photos, matching: .any(of: [.images, .videos]))
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                photos = []
                Task { attach(await PickedFile.load(items)) }
            }
            .onAppear {
                showsCopies = !draft.cc.isEmpty || !draft.bcc.isEmpty
                focus = draft.to.isEmpty ? .to : .body
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { isEdited ? (isClosing = true) : dismiss() }
                .disabled(isSending)
        }
        ToolbarItem(placement: .confirmationAction) {
            if isSending {
                ProgressView()
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill") { send() }
                    .disabled(!canSend)
            }
        }
        // The bottom bar sits under the keyboard, so while typing the button moves above it.
        if focus == nil {
            ToolbarItem(placement: .bottomBar) { attachMenu }
        } else {
            ToolbarItemGroup(placement: .keyboard) {
                attachMenu
                Spacer()
            }
        }
    }

    private var attachMenu: some View {
        Menu {
            Button("Photos or Videos", systemImage: "photo.on.rectangle") { isPickingPhotos = true }
            Button("Files", systemImage: "doc") { isImporting = true }
        } label: {
            Label("Attach", systemImage: "paperclip")
        }
    }

    /// Attachments, kept and added, each removable.
    @ViewBuilder
    private var files: some View {
        if !draft.kept.isEmpty || !draft.added.isEmpty {
            VStack(spacing: 8) {
                ForEach(draft.kept) { file in
                    FileChip(name: file.name, state: .ready) { draft.kept.removeAll { $0 == file } }
                }
                ForEach(draft.added) { file in
                    FileChip(name: file.name, state: file.failed ? .failed : file.uploaded == nil ? .uploading : .ready) {
                        draft.added.removeAll { $0.id == file.id }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    private var isEdited: Bool { draft.differs(from: start) }

    private var canSend: Bool {
        let (to, cc, bcc) = draft.recipients
        return !(to + cc + bcc).isEmpty && !draft.added.contains { $0.uploaded == nil }
    }

    private func field(_ label: String, text: Binding<String>, focus field: Field) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            TextField("", text: text)
                .focused($focus, equals: field)
                .accessibilityLabel(label)
                .modifier(AddressField(isAddress: field != .subject))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func reveal() {
        showsCopies = true
        focus = .cc
    }

    private func attach(_ urls: [URL]) {
        for url in urls {
            let file = ComposeFile(local: url)
            draft.added.append(file)
            Task {
                let uploaded = try? await store.upload(url)
                guard let index = draft.added.firstIndex(where: { $0.id == file.id }) else { return }
                draft.added[index].uploaded = uploaded
                draft.added[index].failed = uploaded == nil
            }
        }
    }

    private func send() {
        let (to, cc, bcc) = draft.recipients
        if let wrong = (to + cc + bcc).first(where: { !Draft.isAddress($0) }) {
            failure = "“\(wrong)” is not an email address."
            return
        }
        finish { try await store.send(draft) }
    }

    /// Runs the closing step, then closes. On failure the sheet stays open with the reason.
    private func finish(_ step: @escaping () async throws -> Void) {
        isSending = true
        Task {
            defer { isSending = false }
            do {
                try await step()
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// Email keyboard and no autocorrection, for the address fields.
private struct AddressField: ViewModifier {
    let isAddress: Bool

    func body(content: Content) -> some View {
        if isAddress {
            content.keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
        } else {
            content
        }
    }
}

private struct FileChip: View {
    enum State { case uploading, ready, failed }

    let name: String
    let state: State
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state == .failed ? "exclamationmark.triangle" : "paperclip")
                .foregroundStyle(state == .failed ? .red : .secondary)
            Text(name).lineLimit(1)
            Spacer(minLength: 0)
            if state == .uploading { ProgressView() }
            Button("Remove \(name)", systemImage: "xmark", action: remove)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .card()
    }
}

/// The message a forward carries, shown below what the person writes.
private struct ForwardedNote: View {
    let message: MailMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Forwarded message").font(.footnote.weight(.semibold))
            Text("From \(message.fromName), \(message.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.footnote)
            Text(message.body).font(.footnote).lineLimit(6)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}
