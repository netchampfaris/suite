import PhotosUI
import SwiftUI

/// One folder's children, with sorting, new folders, and uploads.
struct FolderScreen: View {
    let route: FolderRoute
    @State private var list: NodeList
    @State private var uploads: UploadQueue
    @AppStorage("drive.sort") private var sort: DriveSort = .title

    @State private var isNamingFolder = false
    @State private var folderName = ""
    @State private var isImportingFiles = false
    @State private var isPickingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var page: WebRoute?
    @State private var trail: [Breadcrumb] = []
    @Environment(Workspace.self) private var workspace
    @Environment(\.openDriveFolder) private var openDriveFolder

    init(route: FolderRoute, drive: DriveClient) {
        self.route = route
        let folder = route.node
        let sort = DriveSort(rawValue: UserDefaults.standard.string(forKey: "drive.sort") ?? "") ?? .title
        _list = State(initialValue: NodeList(drive: drive, source: Self.source(folder, sort)))
        _uploads = State(initialValue: UploadQueue(uploader: Uploader(drive: drive)))
    }

    var body: some View {
        NodeListView(list: list) {
            ContentUnavailableView(
                "This folder is empty",
                systemImage: "folder",
                description: Text("Use + to create a folder or a document, or to upload files.")
            )
        }
        .navigationTitle(route.title)
        .toolbar { trailMenu }
        .toolbar { toolbar }
        .task { trail = (try? await list.drive.breadcrumbs(of: route.node))?.filter(\.isFolder) ?? [] }
        .safeAreaInset(edge: .bottom) { UploadBanner(queue: uploads) }
        .fullScreenCover(item: $page) { WebPageScreen(route: $0, api: list.drive.api) }
        .onChange(of: sort) { _, sort in
            Task { await list.replaceSource(Self.source(route.node, sort)) }
        }
        .alert("New Folder", isPresented: $isNamingFolder) {
            TextField("Name", text: $folderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createFolder() }
        }
        .fileImporter(isPresented: $isImportingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { upload(urls.compactMap(PickedFile.copy(securityScoped:))) }
        }
        .photosPicker(isPresented: $isPickingPhotos, selection: $photos, matching: .any(of: [.images, .videos]))
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            Task { upload(await PickedFile.load(items)) }
        }
    }

    /// The folders above this one, top first, in a menu beside Back. Picking one jumps there.
    @ToolbarContentBuilder
    private var trailMenu: some ToolbarContent {
        if let openDriveFolder, !trail.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                let routes = trail.map { FolderRoute(node: $0.name, title: workspace.folderTitle($0)) }
                Menu {
                    ForEach(routes.indices, id: \.self) { index in
                        Button(routes[index].title, systemImage: "folder") {
                            openDriveFolder(Array(routes[...index]))
                        }
                    }
                    Label(route.title, systemImage: "checkmark")
                } label: {
                    Image(systemName: "arrow.turn.left.up")
                }
                .accessibilityLabel("Folders above")
            }
        }
    }

    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                DriveLayoutPicker()
                Picker("Sort By", selection: $sort) {
                    ForEach(DriveSort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("View options")
            Menu {
                Section {
                    ForEach(DocumentKind.allCases) { kind in
                        Button { createDocument(kind) } label: { kind.menuLabel }
                    }
                }
                Section {
                    Button("Folder", systemImage: "folder.badge.plus") {
                        folderName = ""
                        isNamingFolder = true
                    }
                }
                Section {
                    Button("Upload Photos or Videos", systemImage: "photo.on.rectangle") { isPickingPhotos = true }
                    Button("Upload Files", systemImage: "doc.badge.plus") { isImportingFiles = true }
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add")
        }
    }

    private func createFolder() {
        let title = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        Task {
            do {
                list.insert(try await list.drive.createFolder(in: route.node, title: title))
            } catch {
                list.error = error as? APIError ?? APIError(type: "RequestError", message: error.localizedDescription, status: 0)
            }
        }
    }

    private func createDocument(_ kind: DocumentKind) {
        Task {
            do {
                let node = try await list.drive.createDocument(kind, in: route.node)
                list.insert(node)
                page = .document(node)
            } catch {
                list.error = error as? APIError ?? APIError(type: "RequestError", message: error.localizedDescription, status: 0)
            }
        }
    }

    private func upload(_ files: [URL]) {
        uploads.add(files, into: route.node) { list.insert($0) }
    }

    private static func source(_ folder: String, _ sort: DriveSort) -> NodeList.Source {
        { drive, cursor in try await drive.children(of: folder, sort: sort, cursor: cursor) }
    }
}
