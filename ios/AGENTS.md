# iOS app

A native SwiftUI client for Suite. `README.md` covers running it and the code layout.

- The Xcode project is generated. Edit `project.yml`, then run `xcodegen generate`. Never commit `Suite.xcodeproj`.
- The app calls the same HTTP routes as the web app, such as `/api/suite/drive/` (listed in `suite/drive/http/translator.py`). When you change a route the app uses, update the Swift client in the same pull request.
- Swift 6 with complete strict concurrency. Keep the build free of warnings.
- Follow Apple's platform conventions before copying the web layout: navigation stacks, menus, sheets, swipe actions, and the share sheet.
- Keep the palette neutral. Color is for file types and calendars, not for chrome.
- Check UI changes in the simulator against a real site. `SuiteUITests` signs in with `TEST_RUNNER_SUITE_SITE`, `TEST_RUNNER_SUITE_USER` and `TEST_RUNNER_SUITE_PASSWORD`, and saves screenshots to `TEST_RUNNER_SUITE_SHOTS`.
- `SuiteTests` run against a stub server and need no site. CI runs them.
