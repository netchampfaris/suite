import Foundation
import Observation

/// The apps in the sidebar, in the web app's rail order.
enum SuiteArea: String, CaseIterable, Identifiable {
    case home, drive, mail, calendar, meet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .drive: "Drive"
        case .mail: "Mail"
        case .calendar: "Calendar"
        case .meet: "Meet"
        }
    }

    /// The rail's duotone icon, copied from the web by `scripts/import-icons.py`.
    var image: String { "area-\(rawValue)" }
}

/// What every app in the shell shares: the account, the site, and where the person is.
@MainActor
@Observable
final class Workspace {
    let account: Account
    let api: APIClient
    let drive: DriveClient
    let mail = MailStore()

    var area: SuiteArea = .home
    /// A document or meeting open in the web app, over everything else.
    var page: WebRoute?
    /// The meeting the person is in. It keeps going while the call screen is minimized.
    private(set) var call: Call?
    var isShowingCall = false
    /// A link that the current area's screen still has to open. The screen clears it.
    var link: SuiteLink?
    /// Set by the sidebar's search field to open Drive with its search active.
    var isSearchingDrive = false
    var error: String?
    /// Counts saved event changes, so calendar screens know to load again.
    private(set) var calendarChanges = 0

    /// The company name, which names the organization's files.
    private(set) var name: String?
    private(set) var roots: RootLocations?
    /// Mail and Calendar need a mail server. Without one they show sample data.
    private(set) var hasMailServer = false

    init(account: Account, api: APIClient) {
        self.account = account
        self.api = api
        self.drive = DriveClient(api: api)
    }

    var organizationTitle: String {
        name.map { "\($0) files" } ?? RootLocations.organizationTitle
    }

    /// A folder's title as Drive shows it. Roots are named by place, not by their stored title.
    func folderTitle(_ crumb: Breadcrumb) -> String {
        switch crumb.name {
        case roots?.personal.node: RootLocations.personalTitle
        case roots?.organization?.node: organizationTitle
        default: crumb.title
        }
    }

    func load() async {
        async let boot: Boot? = try? api.method("suite.www.suite.get_boot_data")
        async let user: UserInfo? = try? api.method("suite.mail.api.account.get_user_info", body: [String: String]())
        async let roots = try? drive.roots()
        name = await boot?.suiteWorkspaceName.flatMap { $0.isEmpty ? nil : $0 }
        hasMailServer = await user?.isJmapConfigured ?? false
        self.roots = await roots
        if hasMailServer { await mail.connect(api) }
    }

    /// Writes to the calendar, or nil while the calendar shows sample events.
    var calendarWriter: CalendarWriter? {
        mail.account.map { CalendarWriter(api: api, account: $0, me: mail.myEmail) }
    }

    /// Runs a calendar change, then has every calendar screen load again.
    func changeCalendar(_ change: (CalendarWriter) async throws -> Void) async throws {
        guard let writer = calendarWriter else { return }
        try await change(writer)
        calendarChanges += 1
    }

    /// Joins a meeting, or shows it again when the person is already in it. Another call ends first.
    func join(_ code: String, title: String = "Meeting") {
        if let call, !call.isOver, call.route.code == code {
            isShowingCall = true
            return
        }
        call?.leave()
        let call = Call(route: CallRoute(code: code, title: title), server: MeetServer(api: api), myName: account.fullName)
        call.onEnd = { [weak self, weak call] reason in
            guard let self, self.call === call else { return }
            // A call that ended for a reason stays on screen to say why.
            if reason == nil {
                self.call = nil
                isShowingCall = false
            } else {
                isShowingCall = true
            }
        }
        self.call = call
        isShowingCall = true
        Task { await call.start() }
    }

    /// Leaves the call, if any, and closes its screen.
    func closeCall() {
        call?.leave()
        call = nil
        isShowingCall = false
    }

    /// Shows the place a link names. A thread, day, or Drive node stays in `link` until its app's screen opens it.
    func open(_ link: SuiteLink) {
        page = nil
        isShowingCall = false
        switch link {
        case .meeting(let code): join(code)
        case .mail: area = .mail
        case .mailThread: area = .mail; self.link = link
        case .calendar: area = .calendar; self.link = link
        case .drive: area = .drive
        case .driveNode: area = .drive; self.link = link
        case .document(let name): page = WebRoute(title: "Document", path: "d/\(name)")
        }
    }

    /// Creates an empty document in My files and opens it.
    func newDocument(_ kind: DocumentKind) async {
        do {
            let roots: RootLocations
            if let known = self.roots {
                roots = known
            } else {
                roots = try await drive.roots()
            }
            self.roots = roots
            page = .document(try await drive.createDocument(kind, in: roots.personal.node))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct Boot: Decodable, Sendable {
    let suiteWorkspaceName: String?
}

private struct UserInfo: Decodable, Sendable {
    let isJmapConfigured: Bool?
}
