import Foundation

/// A place in Suite that a web address names, read into the app's own screens.
///
/// The app takes the site's own addresses, so a link copied from the web app, a mail, or a
/// notification opens here. `suite://` addresses carry the same path, for when universal links are not set up.
enum SuiteLink: Hashable {
    case meeting(code: String)
    case mail
    case mailThread(id: String)
    /// A calendar day, or today when the address names none.
    case calendar(day: Date?)
    case drive
    /// A file or folder, which the app has to look up to know which.
    case driveNode(name: String)
    /// A document in its web editor.
    case document(name: String)

    /// Reads `url`, or returns nil when it is not an address of `site` that the app can show.
    init?(_ url: URL, site: URL) {
        let parts: [String]
        switch url.scheme?.lowercased() {
        case "suite":
            parts = ([url.host() ?? ""] + url.pathComponents).filter { $0 != "/" && !$0.isEmpty }
        case "http", "https":
            guard url.host()?.lowercased() == site.host()?.lowercased() else { return nil }
            parts = url.pathComponents.filter { $0 != "/" }
        default:
            return nil
        }
        guard let link = Self.read(parts) else { return nil }
        self = link
    }

    private static func read(_ parts: [String]) -> SuiteLink? {
        guard let app = parts.first else { return nil }
        let rest = Array(parts.dropFirst())
        switch app {
        case "meet":
            // The other first segments are the Meet app's own pages.
            guard let code = rest.first, !["scheduled", "recordings", "audio-test"].contains(code) else { return nil }
            return .meeting(code: code)
        case "mail":
            return mailThread(rest).map { .mailThread(id: $0) } ?? .mail
        case "calendar":
            return .calendar(day: day(rest))
        case "drive":
            if rest.first == "f", rest.count > 1 { return .driveNode(name: rest[1]) }
            return .drive
        case "d":
            return rest.first.map { .document(name: $0) }
        default:
            return nil
        }
    }

    /// The thread in `account/<id>/mailbox/<mailbox>/<thread>` or `all/<folder>/account/<id>/<thread>`.
    private static func mailThread(_ parts: [String]) -> String? {
        switch parts.first {
        case "account" where parts.count == 5 && parts[2] == "mailbox": parts[4]
        case "all" where parts.count == 5 && parts[2] == "account": parts[4]
        default: nil
        }
    }

    /// The date in `[account/<id>/]<view>/<year>/<month>/<day>`. A missing month or day is the first.
    private static func day(_ parts: [String]) -> Date? {
        var parts = parts[...]
        if parts.first == "account" { parts = parts.dropFirst(2) }
        guard let view = parts.first, ["day", "week", "month", "agenda"].contains(view) else { return nil }
        let numbers = parts.dropFirst().prefix(3).compactMap { Int($0) }
        guard let year = numbers.first else { return nil }
        let components = DateComponents(
            year: year,
            month: numbers.count > 1 ? numbers[1] : 1,
            day: numbers.count > 2 ? numbers[2] : 1
        )
        return Calendar.current.date(from: components)
    }
}
