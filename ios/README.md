# Suite for iOS

A native SwiftUI client for Frappe Suite, for iPhone.

## What it does

A sidebar switches between the apps, in the web app's order: Home, Drive, Mail,
Calendar, and Meet. Swipe from the left edge or tap the menu button to open it.

- **Home**: new documents, recent files, and upcoming events, like the web Home.
- **Drive**: My files, Organization files, Shared with me, Recent, Starred,
  Trash, and search. Create folders and documents, rename, star, move, share,
  move to Trash, restore, delete forever, and upload photos, videos, and files.
  Share adds people and groups, changes their access, and removes it. Share
  links and publishing to the web stay in the web app.
- **Documents**: new documents, spreadsheets, presentations, and drawings are
  created natively. They open in the web editor inside the app, signed in with
  the app's session.
- **Mail**: read threads, search, write, reply, reply all, forward, and keep
  drafts.
- **Calendar**: day, week, and month views. Create and edit events, and answer
  invitations.
- **Meet**: start a meeting or join one with a code. Calls are native: audio and
  video, mute, camera on and off, switch camera, a grid of participants, and
  leave. A call keeps going when you minimize it or lock the phone, through
  CallKit. A room with end-to-end encryption opens in the browser instead.
- **Links**: `suite://` links and links to the site open the matching screen.
  Examples: `suite://meet/abc-defg-hij`, `suite://mail/account/<id>/mailbox/<mailbox>/<thread>`,
  `suite://calendar/day/2026/11/17`, `suite://drive/f/<node>`, `suite://d/<document>`.
- **Notifications**: the app asks for permission after sign-in. Tapping a
  notification opens the link in its `click_action`.

Mail and Calendar need a mail server on the site. Without one they show sample
data, with a note that says so.

### Not done yet

- **Push delivery.** The site sends notifications through Frappe's notification
  relay, which addresses devices by Firebase token. The app needs the Firebase
  SDK, the relay project's `GoogleService-Info.plist` for this app, and an APNs
  key in that Firebase project. Then it can call
  `suite.suite_core.push.subscribe` with its token. The app also needs the
  Push Notifications capability, which needs an Apple team.
- **Universal links.** `https://<site>/...` links open the app only after the
  app has the Associated Domains entitlement and each site serves an
  `apple-app-site-association` file. Both need the Apple team ID.
  `suite://` links work now.

## Run it

You need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd ios
xcodegen generate
open Suite.xcodeproj
```

The Xcode project is generated from `project.yml` and is not committed. Run
`xcodegen generate` again after you add or remove a file.

To run the tests from the command line:

```sh
xcodebuild test -project Suite.xcodeproj -scheme Suite \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The UI tests in `SuiteUITests` sign in to a real site. They are skipped unless
you give them a site:

| Variable | Use |
| --- | --- |
| `TEST_RUNNER_SUITE_SITE` | The site, such as `http://dev-suite.localhost:8002` |
| `TEST_RUNNER_SUITE_USER`, `TEST_RUNNER_SUITE_PASSWORD` | The login. The default is `Administrator` / `admin` |
| `TEST_RUNNER_SUITE_SHOTS` | A folder for screenshots |
| `TEST_RUNNER_SUITE_CALL` | A Meet room code with people in it, for `testJoinCall` |
| `TEST_RUNNER_SUITE_PUSH` | Any value, for `testOpenNotification` |

The Drive test expects `Roadmap.pdf` in My files and a file named `Ideas.txt`
somewhere. The Mail, Calendar, link, and share tests expect the Northwind demo
data, signed in as `maya@northwind.test`.

`scripts/typecheck.sh` checks the app sources for compiler errors without a
full build.

### Use a local bench

The simulator can reach a bench on your Mac over plain HTTP. Sign in with
`http://<site>.localhost:<port>`, for example `http://dev-suite.localhost:8002`.
A bench picks the site from the host name, so `127.0.0.1` does not work unless
the bench sets a `default_site`.

Uploads need File Storage v2. Add `"storage_v2": 1` to the site's
`site_config.json` and restart the bench.

### Test a call

A call needs the media server in `suite/meet/sfu-server`:

1. In its `.env`, set `JWT_SECRET` and set `WEBRTC_ANNOUNCED_IP` to your Mac's
   LAN address. With `127.0.0.1`, the simulator joins but gets no audio or
   video.
2. In the site config, set `sfu_server_url` to `http://localhost:3000` and
   `sfu_secret` to the same secret.
3. Start it with `yarn dev`.
4. Grant the simulator the microphone before the first call:
   `xcrun simctl privacy booted grant microphone io.frappe.suite`. Without it,
   the audio unit stops the app.

`scripts/spawn-fake-users.js` in the media server adds people with audio and
video to a room. Its video needs an `ffmpeg` with the `drawtext` filter.

CallKit does not work in the simulator. The app falls back to WebRTC's own
audio session there, so test background audio and the lock screen on a phone.

### Test a notification

Run `testOpenNotification`. While it waits on the home screen, send this
payload with `xcrun simctl push booted io.frappe.suite payload.json`:

```json
{
  "aps": { "alert": { "title": "Mail", "body": "iOS push check" } },
  "click_action": "/mail/account/i/mailbox/a/ca"
}
```

## How it talks to Suite

The app uses the same APIs as the web app. Drive uses `/api/suite/drive/`,
whose routes are listed in `suite/drive/http/translator.py`. Meet uses
`/api/suite/meet/rooms/` to join, then talks to the media server over
socket.io and WebRTC, through mediasoup, as the web client does.

Sign-in calls `/api/method/login`. The site answers with a `sid` cookie. The
app keeps the cookie in the system cookie store and sends it with every
request. A session started this way has no CSRF token until a web page opens
with the same cookie. After that, write requests need the token, so `APIClient`
fetches it from the boot data the first time the site asks for it.

## Code layout

| Folder | Contents |
| --- | --- |
| `Suite/App` | The app entry point and notifications |
| `Suite/Core` | `APIClient` (requests and errors), `AppSession` (sign-in state), and `JSONValue` |
| `Suite/Shell` | The sidebar, `Workspace` (what every app shares), `SuiteLink` (links), and sample data |
| `Suite/Home` | The Home screen |
| `Suite/Documents` | Document types and the web page that hosts the web editors |
| `Suite/Mail`, `Suite/Calendar` | Those apps' screens and stores |
| `Suite/Meet` | Meet's screens, and the native call: `Call` (state), `CallSignal` (socket.io), `CallMedia` (mediasoup), `CallAudio` (CallKit) |
| `Suite/Drive` | `DriveClient` (typed routes), sharing, models, `NodeList` (one list model for every screen), `Uploader` |
| `Suite/Drive/Views` | Drive's screens, rows, and the move and share sheets |
| `Suite/Login` | The sign-in screen |
| `SuiteTests` | Tests against a stub server, and link parsing |
| `SuiteUITests` | Flows against a real site |
