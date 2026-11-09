import XCTest

/// Walks through Drive against a real site. Skipped unless a site is given:
///
///     TEST_RUNNER_SUITE_SITE=http://dev-suite.localhost:8002 TEST_RUNNER_SUITE_USER=Administrator \
///     TEST_RUNNER_SUITE_PASSWORD=admin xcodebuild test -only-testing:SuiteUITests ...
///
/// Set `TEST_RUNNER_SUITE_SHOTS` to a folder to also save each screenshot there.
@MainActor
final class DriveFlowTests: XCTestCase {
    private var app: XCUIApplication!
    private let env = ProcessInfo.processInfo.environment

    override func setUpWithError() throws {
        try XCTSkipIf(env["SUITE_SITE"] == nil, "No SUITE_SITE given")
        continueAfterFailure = false
        app = XCUIApplication()
        // Rows, not cards, whatever layout the app last saved: `row(_:)` finds list cells.
        app.launchArguments = ["-drive.layout", "list"]
        app.launch()
    }

    func testBrowseCreateRenameStarTrashRestoreAndOpen() throws {
        signIn()
        openArea("drive")
        expect(app.navigationBars["Drive"], 10)
        shot("d1-drive")

        app.buttons["My files"].tap()
        expect(app.navigationBars["My files"], 10)
        shot("d2-my-files")

        let folder = "Trip \(Int.random(in: 1000...9999))"
        app.buttons["Add"].tap()
        app.buttons["Folder"].tap()
        app.alerts.textFields.firstMatch.typeText(folder)
        app.alerts.buttons["Create"].tap()
        expect(row(folder), 10)

        let renamed = "\(folder) Renamed"
        row(folder).press(forDuration: 1)
        app.buttons["Rename"].tap()
        app.alerts.textFields.firstMatch.typeText(" Renamed")
        app.alerts.buttons["Rename"].tap()
        expect(row(renamed), 10)

        row(renamed).press(forDuration: 1)
        app.buttons["Star"].tap()
        expect(row(renamed).images["Starred"], 5)
        shot("d3-renamed-and-starred")

        back()
        app.buttons["Starred"].tap()
        expect(row(renamed), 10)
        shot("d4-starred")
        back()

        app.buttons["My files"].tap()
        row(renamed).press(forDuration: 1)
        app.buttons["Move to Trash"].tap()
        expectGone(row(renamed), 10)
        back()
        app.buttons["Trash"].tap()
        expect(row(renamed), 10)
        shot("d5-trash")
        row(renamed).press(forDuration: 1)
        app.buttons["Restore"].tap()
        expectGone(row(renamed), 10)
        back()

        app.buttons["My files"].tap()
        expect(row(renamed), 10)
        row(renamed).tap()
        expect(app.navigationBars[renamed], 10)
        back()

        row("Roadmap.pdf").tap()
        // Quick Look titles the preview with the file name, without its extension.
        expect(app.descendants(matching: .any)["Roadmap"], 15)
        sleep(1)
        shot("d6-quick-look")
        app.buttons.matching(NSPredicate(format: "label ==[c] 'close' OR label ==[c] 'done'")).firstMatch.tap()

        // Leave nothing behind: trash the folder, then delete it forever.
        row(renamed).press(forDuration: 1)
        app.buttons["Move to Trash"].tap()
        expectGone(row(renamed), 10)
        back()
        app.buttons["Trash"].tap()
        expect(row(renamed), 10)
        row(renamed).press(forDuration: 1)
        app.buttons["Delete Forever"].tap()
        let confirm = app.buttons.matching(identifier: "Delete Forever").element(boundBy: 0)
        expect(confirm, 5)
        confirm.tap()
        expectGone(row(renamed), 10)
        back()

        let search = app.searchFields.firstMatch
        expect(search, 5)
        search.tap()
        search.typeText("Ideas")
        expect(row("Ideas.txt"), 10)
        shot("d7-search")
    }

    /// Moves a folder into another, then shares it with a teammate, changes their access, and removes it.
    func testMoveAndShare() throws {
        try XCTSkipIf(env["SUITE_USER"] != "maya@northwind.test", "Needs the Northwind demo, signed in as Maya")
        signIn()
        openArea("drive")
        app.buttons["My files"].tap()
        let number = Int.random(in: 1000...9999)
        let box = "Box \(number)", crate = "Crate \(number)"
        for folder in [box, crate] {
            app.buttons["Add"].tap()
            app.buttons["Folder"].tap()
            app.alerts.textFields.firstMatch.typeText(folder)
            app.alerts.buttons["Create"].tap()
            expect(row(folder), 10)
        }

        row(box).press(forDuration: 1)
        app.buttons["Move"].tap()
        expect(app.navigationBars["Move “\(box)”"], 5)
        app.collectionViews.buttons["My files"].firstMatch.tap()
        // A folder cannot move into itself, so only the other one is offered.
        let picker = app.collectionViews["move.folders"]
        let choice = { (title: String) in picker.cells.containing(.staticText, identifier: title).firstMatch }
        expect(choice(crate), 10)
        XCTAssertFalse(choice(box).exists)
        let here = app.buttons["Already Here"]
        expect(here, 5)
        XCTAssertFalse(here.isEnabled)
        shot("v1-move-picker")
        choice(crate).tap()
        app.buttons["Move Here"].tap()
        expectGone(row(box), 10)
        row(crate).tap()
        expect(row(box), 10)
        shot("v2-moved")

        row(box).press(forDuration: 1)
        app.buttons["Share"].tap()
        expect(app.navigationBars["Share “\(box)”"], 5)
        let search = app.searchFields["Add people or groups"]
        expect(search, 10)
        search.tap()
        search.typeText("nisha")
        let nisha = app.cells.containing(.staticText, identifier: "nisha@northwind.test").firstMatch
        expect(nisha, 10)
        nisha.tap()
        let view = app.buttons["View access"]
        expect(view, 10)
        shot("v3-shared")
        view.tap()
        app.buttons["Edit"].tap()
        let edit = app.buttons["Edit access"]
        expect(edit, 10)
        edit.tap()
        app.buttons["Remove Access"].tap()
        expectGone(app.staticTexts["Nisha Patel"], 10)
        app.buttons["Done"].tap()

        // Leave nothing behind but the folder in Trash.
        back()
        row(crate).press(forDuration: 1)
        app.buttons["Move to Trash"].tap()
        expectGone(row(crate), 10)
    }

    /// Visits Home, the sidebar, Mail, Calendar, Meet, and a new drawing in the web editor.
    func testShellTour() throws {
        signIn()
        expect(app.staticTexts["Recent"], 10)
        sleep(2)
        shot("t1-home")
        app.buttons["Schedule or meet"].tap()
        expect(app.buttons["Join with code"], 5)
        sleep(1)
        shot("t1b-home-add-menu")
        // A tap outside closes the menu; the large title is a safe place.
        app.navigationBars["Home"].staticTexts["Home"].firstMatch.tap()

        openSidebar()
        shot("t2-sidebar")
        app.buttons["sidebar.mail"].tap()
        expect(app.navigationBars["Inbox"], 10)
        shot("t3-mail")
        app.buttons["Updates"].tap()
        expect(app.staticTexts["Your storage summary for October"], 5)
        shot("t3b-mail-updates")
        app.buttons["Primary"].tap()
        row("Asha Rao").tap()
        expect(app.staticTexts["Drive mobile: sidebar feedback"], 5)
        shot("t4-mail-thread")
        back()

        openArea("calendar")
        expect(app.buttons["Today"], 10)
        shot("t5-calendar")
        let review = app.staticTexts["Design review: Drive mobile"]
        if review.waitForExistence(timeout: 3) {
            review.tap()
            expect(app.buttons["Join meeting"], 5)
            shot("t6-event")
            app.buttons["Join meeting"].tap()
            expect(app.buttons["Leave call"], 5)
            app.buttons["Mute"].tap()
            expect(app.buttons["Unmute"], 3)
            sleep(1)
            shot("t6b-call")
            app.buttons["Leave call"].tap()
        }

        openArea("meet")
        expect(app.navigationBars["Meet"], 10)
        shot("t7-meet")
        app.buttons["New meeting"].tap()
        expect(app.staticTexts["Your meeting is ready"], 10)
        shot("t8-meeting-ready")
        app.swipeDown(velocity: .fast)

        openSidebar()
        app.buttons["sidebar.new"].tap()
        app.buttons["Drawing"].tap()
        // The server adds a number when an untitled drawing already exists.
        expect(app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH 'Untitled drawing'")).firstMatch, 15)
        sleep(6)
        shot("t9-drawing")
        app.buttons["Close"].tap()

        openSidebar()
        app.buttons["Search files"].tap()
        expect(app.navigationBars["Drive"], 10)
        sleep(1)
        shot("t10-drive-search")
    }

    /// Only signs in, to leave the app ready on a site for someone to try by hand.
    func testSignIn() throws {
        signIn()
        shot("s1-signed-in")
    }

    /// Walks three folders deep, then jumps back to the top through the folder menu.
    /// Needs the Northwind demo, signed in as Maya.
    func testBreadcrumbs() throws {
        try XCTSkipIf(env["SUITE_USER"] != "maya@northwind.test", "Needs the Northwind demo, signed in as Maya")
        signIn()
        openArea("drive")
        let top = "Northwind Labs files"
        app.buttons[top].tap()
        // An earlier run may have left Drive in grid view, where items are not list cells.
        app.buttons["View options"].tap()
        app.buttons["List"].tap()
        for folder in ["Northwind Labs - Company", "Handbook", "Policies and reference"] {
            expect(row(folder), 10)
            row(folder).tap()
            expect(app.navigationBars[folder], 10)
        }
        sleep(1)
        shot("b0-folder-button")
        app.buttons["Folders above"].tap()
        expect(app.buttons[top], 5)
        sleep(1)
        shot("b1-trail")
        app.buttons[top].tap()
        expect(app.navigationBars[top], 10)
        sleep(1)
        shot("b2-jumped")
        // The stack is the trail, so Back from the top folder lands on Drive.
        back()
        expect(app.navigationBars["Drive"], 10)
    }

    /// Sends Maya a message from herself and checks that the server accepts it.
    /// Needs the Northwind demo with a mail server, signed in as Maya.
    func testSendMail() throws {
        try XCTSkipIf(env["SUITE_USER"] != "maya@northwind.test", "Needs the Northwind demo, signed in as Maya")
        signIn()
        openArea("mail")
        expect(app.navigationBars["Inbox"], 10)
        let subject = "iOS send check \(Int(Date().timeIntervalSince1970))"
        app.buttons["Compose"].tap()
        expect(app.navigationBars["New message"], 5)
        app.typeText(env["SUITE_USER"]!)
        app.textFields["Subject"].tap()
        app.typeText(subject)
        app.textFields["Message"].tap()
        app.typeText("Sent from the iOS app to check that sending works.")
        shot("m0-compose")
        app.buttons["Send"].tap()
        // The sheet closes only once the server accepts the message.
        expectGone(app.navigationBars["New message"], 15)
        XCTAssertFalse(app.alerts["Could not send"].exists)
        // Delivery itself is not checked: a local mail server can take minutes to file the message.
        shot("m1-sent")
    }

    /// Writes a message with a photo, keeps it as a draft, opens it again from Drafts, and sends it.
    /// Needs the Northwind demo with a mail server, signed in as Maya.
    func testDraftMail() throws {
        try XCTSkipIf(env["SUITE_USER"] != "maya@northwind.test", "Needs the Northwind demo, signed in as Maya")
        signIn()
        openArea("mail")
        expect(app.navigationBars["Inbox"], 10)
        let subject = "iOS draft check \(Int(Date().timeIntervalSince1970))"
        app.buttons["Compose"].tap()
        expect(app.navigationBars["New message"], 5)
        app.typeText(env["SUITE_USER"]!)
        app.buttons["Cc/Bcc"].tap()
        app.typeText(env["SUITE_USER"]!)
        app.textFields["Subject"].tap()
        app.typeText(subject)

        app.buttons["Attach"].firstMatch.tap()
        app.buttons["Photos or Videos"].tap()
        sleep(3)
        shot("d0-picker")
        // The picker runs outside the app and hides its photos from the tree, so tap the grid by position.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        sleep(1)
        shot("d0b-picked")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.125)).tap()
        sleep(4)
        shot("d1-attached")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove'")).firstMatch.exists)

        app.buttons["Cancel"].tap()
        app.buttons["Save Draft"].tap()
        expectGone(app.navigationBars["New message"], 15)
        XCTAssertFalse(app.alerts["Could not send"].exists)

        openTitleMenu("Inbox")
        app.buttons["Drafts"].tap()
        let row = app.staticTexts[subject]
        expect(row, 15)
        shot("d2-drafts")
        row.tap()
        expect(app.navigationBars["New message"], 5)
        sleep(2)
        shot("d3-reopened")
        XCTAssertEqual(app.textFields["Subject"].value as? String, subject)
        XCTAssertTrue(app.textFields["Cc"].exists, "the copy list comes back open")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove'")).firstMatch.exists, "the photo stays attached")

        app.buttons["Send"].tap()
        expectGone(app.navigationBars["New message"], 15)
        XCTAssertFalse(app.alerts["Could not send"].exists)
        sleep(3)
        shot("d4-sent")
        XCTAssertFalse(app.staticTexts[subject].exists, "a sent draft leaves Drafts")
    }

    /// Finds a thread filed in Sent while looking at the inbox, and opens it.
    func testSearchMail() throws {
        try XCTSkipIf(env["SUITE_USER"] != "maya@northwind.test", "Needs the Northwind demo, signed in as Maya")
        signIn()
        openArea("mail")
        expect(app.navigationBars["Inbox"], 10)
        app.swipeDown()
        let field = app.searchFields["Search mail"]
        expect(field, 5)
        field.tap()
        app.typeText("design review")
        // Two threads match: one in the inbox and one in Sent.
        let match = app.staticTexts["Collections spec ready for design review"]
        expect(match, 15)
        shot("s0-results")
        XCTAssertGreaterThanOrEqual(app.cells.count, 2)
        match.tap()
        sleep(2)
        shot("s1-thread")
        XCTAssertTrue(app.buttons["Reply"].exists)

        app.navigationBars.buttons.firstMatch.tap()
        field.buttons["Clear text"].tap()
        app.typeText("zzqx no such mail")
        expect(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No Results'")).firstMatch, 15)
    }

    /// Adds an event with a guest and a Meet link, renames it, and deletes it.
    /// Needs the Northwind demo with a mail server, signed in as Maya, before 23:00.
    func testEditEvent() throws {
        try XCTSkipIf(env["SUITE_USER"] != "maya@northwind.test", "Needs the Northwind demo, signed in as Maya")
        signIn()
        openArea("calendar")
        let title = "iOS event check \(Int(Date().timeIntervalSince1970))"
        app.buttons["New event"].tap()
        expect(app.navigationBars["New event"], 5)
        app.textFields["Title"].tap()
        app.typeText(title)
        app.textFields["Guests"].tap()
        app.typeText("leo@northwind.test")
        shot("c0-new")
        app.buttons["Add"].tap()
        expectGone(app.navigationBars["New event"], 20)
        XCTAssertFalse(app.alerts["Could not save the event"].exists)

        // It starts at the next whole hour today, so today's list shows it.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        expect(row, 15)
        row.tap()
        expect(app.buttons["Join meeting"], 5)
        shot("c1-detail")
        app.buttons["Edit"].tap()
        expect(app.navigationBars["Edit event"], 5)
        app.textFields["Title"].tap()
        app.typeText(" edited")
        app.buttons["Save"].tap()
        expectGone(app.navigationBars["Edit event"], 20)
        XCTAssertFalse(app.alerts["Could not save the event"].exists)

        let edited = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "\(title) edited")).firstMatch
        expect(edited, 15)
        shot("c2-edited")
        edited.tap()
        app.buttons["Delete"].tap()
        app.buttons["Delete Event"].tap()
        expectGone(edited, 15)
        XCTAssertFalse(app.alerts["Could not change the event"].exists)
        shot("c3-deleted")
    }

    /// Answers Maybe to an invitation from Leo on 17 November, picked from Month.
    func testAnswerInvitation() throws {
        try XCTSkipIf(env["SUITE_USER"] != "maya@northwind.test", "Needs the Northwind demo, signed in as Maya")
        signIn()
        openArea("calendar")
        openTitleMenu("Day")
        app.buttons["Month"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tuesday, 17 November 2026' OR label BEGINSWITH 'Tuesday 17 November 2026' OR label BEGINSWITH 'Tuesday, November 17, 2026'")).firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Collections retest'")).firstMatch
        expect(row, 10)
        row.tap()
        expect(app.staticTexts["Going?"], 5)
        app.buttons["Maybe"].tap()
        sleep(3)
        XCTAssertFalse(app.alerts["Could not change the event"].exists)
        shot("c4-maybe")
        XCTAssertTrue(app.buttons["Maybe"].isSelected)
    }

    /// Opens a mail thread, a calendar day, and a Drive folder from the site's addresses.
    func testOpenLinks() throws {
        try XCTSkipIf(env["SUITE_USER"] != "maya@northwind.test", "Needs the Northwind demo, signed in as Maya")
        signIn()
        openLink(URL(string: "suite://mail/account/i/mailbox/a/ca")!)
        expect(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'iOS send check'")).firstMatch, 10)
        shot("l1-mail")
        openLink(URL(string: "suite://calendar/account/i/day/2026/11/17")!)
        expect(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Collections retest'")).firstMatch, 10)
        shot("l2-calendar")
        openLink(URL(string: "suite://drive/f/mdfaq9p5sb/northwind-labs-design")!)
        expect(app.navigationBars["Northwind Labs - Design"], 10)
        shot("l3-drive")
    }

    /// Joins a room that `SUITE_CALL` names, where fake participants send audio and video.
    func testJoinCall() throws {
        guard let room = env["SUITE_CALL"] else { throw XCTSkip("Needs a room with people in it, in SUITE_CALL") }
        signIn()
        addUIInterruptionMonitor(withDescription: "Microphone") { alert in
            alert.buttons["Allow"].exists ? { alert.buttons["Allow"].tap(); return true }() : false
        }
        openLink(URL(string: "suite://meet/\(room)")!)
        let leave = app.buttons["Leave call"]
        expect(leave, 20)
        // The tiles fill in as each person's video arrives.
        sleep(6)
        app.tap()
        shot("m1-call")
        app.buttons["Mute"].tap()
        expect(app.buttons["Unmute"], 5)
        shot("m2-muted")
        app.buttons["Minimize"].tap()
        expect(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Return to call'")).firstMatch, 5)
        shot("m3-minimized")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Return to call'")).firstMatch.tap()
        expect(leave, 5)
        leave.tap()
        expectGone(leave, 5)
    }

    /// Opens Reply All and Forward from a thread's reply menu.
    /// Taps a notification sent with `xcrun simctl push` while the test waits, as `ios/README.md` shows.
    func testOpenNotification() throws {
        try XCTSkipIf(env["SUITE_PUSH"] == nil, "Send a notification while this runs, and set SUITE_PUSH")
        signIn()
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'iOS push check'")).firstMatch
        expect(banner, 90)
        shot("p1-banner")
        banner.tap()
        expect(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'iOS send check'")).firstMatch, 15)
        shot("p2-opened")
    }

    func testReplyMenu() throws {
        try XCTSkipIf(env["SUITE_USER"] != "maya@northwind.test", "Needs the Northwind demo, signed in as Maya")
        signIn()
        openArea("mail")
        expect(app.navigationBars["Inbox"], 10)
        app.cells.element(boundBy: 1).tap()
        sleep(2)
        app.buttons["Reply"].press(forDuration: 1)
        shot("f0-menu")
        app.buttons["Reply All"].tap()
        expect(app.navigationBars["Reply"], 5)
        shot("f1-reply-all")
        // Nothing was changed, so closing asks nothing.
        app.buttons["Cancel"].tap()
        expectGone(app.navigationBars["Reply"], 5)
        XCTAssertFalse(app.buttons["Save Draft"].exists)
        app.buttons["Reply"].press(forDuration: 1)
        app.buttons["Forward"].tap()
        expect(app.navigationBars["Forward"], 5)
        sleep(1)
        shot("f2-forward")
        XCTAssertTrue(app.staticTexts["Forwarded message"].exists)
        app.buttons["Cancel"].tap()
    }

    /// Switches mailboxes from the title menu, reads an HTML thread, and opens its attachment.
    /// Needs the Northwind demo with a mail server, signed in as Maya.
    func testReadMail() throws {
        try XCTSkipIf(env["SUITE_USER"] != "maya@northwind.test", "Needs the Northwind demo, signed in as Maya")
        signIn()
        openArea("mail")
        sleep(2)
        openTitleMenu("Inbox")
        shot("r0-mailboxes")
        app.buttons["Sent"].tap()
        sleep(3)
        shot("r0b-sent")
        openTitleMenu("Sent")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Inbox'")).firstMatch.tap()
        let thread = app.staticTexts["Collections spec ready for design review"]
        // The thread is further down, and the floating Compose button covers the last row.
        for _ in 0..<6 where !(thread.exists && thread.frame.maxY < app.frame.height * 0.75) {
            app.swipeUp(velocity: .slow)
        }
        expect(thread, 5)
        thread.tap()
        sleep(3)
        shot("r1-thread")
        let attachment = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] '.'")).matching(NSPredicate(format: "label CONTAINS[c] 'KB' OR label CONTAINS[c] 'MB' OR label CONTAINS[c] 'bytes'")).firstMatch
        for _ in 0..<4 where !attachment.isHittable { app.swipeUp() }
        shot("r2-attachment")
        attachment.tap()
        sleep(4)
        shot("r3-preview")
        XCTAssertFalse(app.alerts["Could not open the attachment"].exists)
    }

    /// Screenshots each area's main screens without changing anything on the site.
    func testScreens() throws {
        signIn()
        sleep(3)
        shot("v1-home")
        openSidebar()
        shot("v1b-sidebar")
        openArea("drive")
        expect(app.navigationBars["Drive"], 10)
        sleep(1)
        shot("v2-drive")
        app.buttons["My files"].tap()
        sleep(3)
        shot("v3-my-files")
        back()
        openArea("mail")
        expect(app.navigationBars["Inbox"], 10)
        sleep(3)
        shot("v4-mail")
        app.collectionViews.cells.element(boundBy: 1).tap()
        sleep(2)
        shot("v5-mail-thread")
        back()
        openArea("calendar")
        expect(app.buttons["Today"], 10)
        sleep(2)
        shot("v6-calendar")
        openArea("meet")
        expect(app.navigationBars["Meet"], 10)
        sleep(2)
        shot("v7-meet")
    }

    /// Reads the Northwind demo's real mail and calendar, and opens one of each web document.
    /// Needs a site seeded with `suite.composition.demo.drive.seed` and a mail server, signed in as Maya.
    func testNorthwindTour() throws {
        try XCTSkipIf(env["SUITE_USER"] != "maya@northwind.test", "Needs the Northwind demo, signed in as Maya")
        signIn()
        sleep(3)
        shot("n0a-home")
        openArea("drive")
        app.buttons["My files"].tap()
        expect(app.navigationBars["My files"], 10)
        sleep(3)
        shot("n0c-my-files")
        app.buttons["View options"].tap()
        app.buttons["Grid"].tap()
        sleep(2)
        shot("n0e-grid")
        app.buttons["View options"].tap()
        sleep(1)
        shot("n0f-view-options")
        app.buttons["List"].tap()
        app.buttons["Add"].tap()
        sleep(1)
        shot("n0d-add-menu")
        // A tap outside closes the menu; the large title is a safe place.
        app.navigationBars["My files"].staticTexts["My files"].firstMatch.tap()
        back()
        openSidebar()
        shot("n0b-sidebar")
        app.buttons["sidebar.mail"].tap()
        expect(app.navigationBars["Inbox"], 10)
        expect(app.staticTexts["Beta invitation email: draft for review"], 15)
        shot("n1-mail")
        app.buttons["Promotions"].tap()
        expect(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Product Weekly'")).firstMatch, 10)
        shot("n2-mail-promotions")
        app.buttons["Primary"].tap()
        app.staticTexts["Beta invitation email: draft for review"].tap()
        expect(app.buttons["Reply"], 10)
        sleep(1)
        shot("n3-mail-thread")
        back()

        openArea("calendar")
        expect(app.buttons["Today"], 10)
        sleep(2)
        shot("n4-calendar-day")
        for (current, mode) in [("Day", "Week"), ("Week", "Month")] {
            // The title opens the view menu.
            app.navigationBars.firstMatch.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", current)).firstMatch.tap()
            app.buttons[mode].tap()
            sleep(2)
            shot("n5-calendar-\(mode.lowercased())")
        }

        for kind in ["Document", "Presentation", "Drawing"] {
            openSidebar()
            app.buttons["sidebar.new"].tap()
            app.buttons[kind].tap()
            expect(app.buttons["Close"], 15)
            sleep(8)
            shot("n6-\(kind.lowercased())")
            app.buttons["Close"].tap()
        }
    }

    // MARK: Helpers

    private func signIn() {
        // A run before this one may have left the app signed in. To change sites, uninstall the app first.
        if app.navigationBars["Home"].waitForExistence(timeout: 5) {
            allowNotifications()
            return
        }
        let site = app.textFields["suite.frappe.io"]
        expect(site, 10)
        // The app fills in the last site signed in to.
        let current = site.value as? String ?? ""
        if current != env["SUITE_SITE"]!.replacingOccurrences(of: "https://", with: "") {
            sleep(1)
            site.tap()
            site.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + env["SUITE_SITE"]!)
        }
        // Return moves focus to the next field, and Return on the password signs in.
        let email = app.textFields["Email"]
        email.tap()
        email.typeText((env["SUITE_USER"] ?? "Administrator") + "\n")
        app.typeText(env["SUITE_PASSWORD"] ?? "admin")
        shot("0-sign-in")
        app.typeText("\n")
        let signedIn = app.navigationBars["Home"].waitForExistence(timeout: 15)
        if !signedIn { shot("0-sign-in-failed") }
        XCTAssertTrue(signedIn)
        dismissSavePasswordPrompt()
        allowNotifications()
        // The prompt can still be on its way out, and it takes the next tap.
        sleep(2)
    }

    /// The app asks to send notifications once it is signed in.
    private func allowNotifications() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    /// iOS offers to save the password after a sign-in, over the app.
    private func dismissSavePasswordPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for host in [app!, springboard] {
            let notNow = host.buttons["Not Now"]
            if notNow.waitForExistence(timeout: 3) {
                notNow.tap()
                return
            }
        }
    }

    /// Taps an inline title that opens a menu, such as Calendar's view or Mail's mailbox.
    private func openTitleMenu(_ title: String) {
        app.navigationBars.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title)).firstMatch.tap()
    }

    private func openArea(_ area: String) {
        openSidebar()
        app.buttons["sidebar.\(area)"].tap()
    }

    /// Opens a `suite://` address, accepting the system's "Open in Suite?" prompt.
    private func openLink(_ url: URL) {
        app.open(url)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }
    }

    /// Opens the sidebar and waits for it to settle. A tap while a screen is still loading can miss, so it tries twice.
    private func openSidebar() {
        let home = app.buttons["sidebar.home"]
        for _ in 0..<2 where !home.isHittable {
            app.buttons["Menu"].tap()
            // Tapping Menu again while the sidebar slides in would close it, so wait it out first.
            let open = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: home)
            _ = XCTWaiter.wait(for: [open], timeout: 4)
        }
        expect(home, 1)
        // Let the slide finish, or a tap lands on whatever passes under it.
        sleep(1)
    }

    private func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    private func expect(_ element: XCUIElement, _ timeout: TimeInterval, line: UInt = #line) {
        guard !element.waitForExistence(timeout: timeout) else { return }
        shot("failed-line-\(line)")
        XCTFail("Missing \(element)", line: line)
    }

    private func expectGone(_ element: XCUIElement, _ timeout: TimeInterval, line: UInt = #line) {
        guard !element.waitForNonExistence(timeout: timeout) else { return }
        shot("failed-line-\(line)")
        XCTFail("Still showing \(element)", line: line)
    }

    private func row(_ title: String) -> XCUIElement {
        app.collectionViews.cells.containing(.staticText, identifier: title).firstMatch
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = env["SUITE_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(filePath: folder).appending(path: "\(name).png"))
        }
    }
}
