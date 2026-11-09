import Foundation
import Testing
@testable import Suite

/// Which screen each of the web app's addresses opens.
struct SuiteLinkTests {
    private let site = URL(string: "https://acme.frappe.io")!

    private func link(_ address: String) -> SuiteLink? {
        SuiteLink(URL(string: address)!, site: site)
    }

    @Test func meetingAddressesJoinTheRoom() {
        #expect(link("https://acme.frappe.io/meet/abc-defg-hij") == .meeting(code: "abc-defg-hij"))
        #expect(link("suite://meet/abc-defg-hij") == .meeting(code: "abc-defg-hij"))
    }

    @Test func meetPagesAreNotRooms() {
        #expect(link("https://acme.frappe.io/meet/scheduled") == nil)
        #expect(link("https://acme.frappe.io/meet") == nil)
    }

    @Test func mailAddressesOpenTheirThread() {
        #expect(link("https://acme.frappe.io/mail/account/i/mailbox/a/ca") == .mailThread(id: "ca"))
        #expect(link("https://acme.frappe.io/mail/all/inbox/account/i/ca") == .mailThread(id: "ca"))
        #expect(link("https://acme.frappe.io/mail/account/i/mailbox/a") == .mail)
    }

    @Test func calendarAddressesOpenTheirDay() {
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 26))
        #expect(link("https://acme.frappe.io/calendar/account/i/week/2026/11/26") == .calendar(day: day))
        #expect(link("https://acme.frappe.io/calendar/day/2026/11/26") == .calendar(day: day))
        #expect(link("https://acme.frappe.io/calendar") == .calendar(day: nil))
    }

    @Test func driveAddressesOpenTheirNode() {
        #expect(link("https://acme.frappe.io/drive/f/n42/quarterly-plan") == .driveNode(name: "n42"))
        #expect(link("https://acme.frappe.io/drive/recent") == .drive)
        #expect(link("https://acme.frappe.io/d/doc7") == .document(name: "doc7"))
    }

    @Test func otherSitesAndAppsStayInTheBrowser() {
        #expect(link("https://other.frappe.io/meet/abc-defg-hij") == nil)
        #expect(link("https://acme.frappe.io/app/user") == nil)
        #expect(link("mailto:leo@acme.test") == nil)
    }
}
