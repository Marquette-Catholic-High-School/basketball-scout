# Basketball Scout for iPhone, iPad and Mac

A native app for your Basketball Scout server. It does everything the web pages do: create games,
upload film, follow the analysis, watch the film with the event timeline, map the court, read the box
score, shot chart, plays and data quality, write the scouting report, export to FastScout, and edit
rosters and jersey assignments.

One app runs on all three: **iPhone and iPad** (iOS / iPadOS 18 or later) and **Mac** (macOS 15
Sequoia or later). It is a real Mac app, not the iPad app in a window. On the iPhone home screen it
is called **Scout**, on iPad and Mac **Basketball Scout**.

The app talks only to your own server. It has no account of its own and sends nothing anywhere else.

## Contents

- [Build and install](#build-and-install)
- [Connect to your server](#connect-to-your-server)
- [Using the app](#using-the-app)
- [Live games](#live-games)
- [What is stored on the device](#what-is-stored-on-the-device)
- [Troubleshooting](#troubleshooting)
- [Tests](#tests)
- [Project layout](#project-layout)

## Build and install

You need a Mac with **Xcode 26 or later** (free from the Mac App Store) and an Apple ID.

1. Open `apple/BasketballScout.xcodeproj` in Xcode.
2. Click the **BasketballScout** project in the left sidebar, then the **BasketballScout** target,
   then **Signing & Capabilities**. Under **Team**, choose your team.
   - Any Apple ID works for running the app on your own iPhone, iPad or Mac (a "Personal Team"; the
     app then has to be reinstalled from Xcode every 7 days).
   - To give the app to other coaches, use your school's Apple Developer account and distribute it
     with TestFlight or Apple Business Manager (custom apps).
   - If Xcode says the bundle identifier is taken, change `org.marquettecatholic.BasketballScout` to
     something unique, for example with your school's domain reversed.
3. Choose where to run it in the toolbar at the top: **My Mac**, a connected iPhone or iPad, or a
   simulator.
4. Press **Run** (⌘R).

The first time you run the app on an iPhone or iPad, you may have to trust the developer:
**Settings > General > VPN & Device Management**, then your Apple ID. On an iPhone or iPad, also turn
on **Developer Mode** when iOS asks (Settings > Privacy & Security > Developer Mode).

## Connect to your server

Sign in with the same three things you use for the web pages:

- **Server address**: what the installer printed, for example `http://10.20.30.40:8000`,
  `http://scout.local` or `https://scout.myschool.org`. Type only the address: no path after it.
- **Username**: usually `coach` (`SCOUT_AUTH_USERNAME` in the server's `.env`).
- **Password**: `SCOUT_AUTH_PASSWORD` in the server's `.env`.

The app checks that the address really is a Basketball Scout server before it sends the password. If
you leave out the port and nothing answers on port 80, it tries port 8000 (an install without nginx).

**http or https.** Apple only lets apps use plain `http://` on the local network:

| Address | Works with |
|---|---|
| An IP address: `http://10.20.30.40:8000` | http or https |
| A `.local` name: `http://scout.local` | http or https |
| A one-word name: `http://scout` | http or https |
| A full domain name: `scout.myschool.org` | **https only** |

So for a full domain name, set up HTTPS on the server first (`install.sh --with-nginx --domain NAME`
and certbot, or Tailscale: see [Security and privacy](../README.md#security-and-privacy)), or type
the server's IP address instead. Over plain http the password crosses the network unencrypted, so
the app warns you once per address before it sends it.

**iPhone and iPad: allow Local Network.** The first time the app connects to a server on your
network, iOS asks to let it find and connect to devices on your local network. Choose **Allow**. If
you chose Don't Allow: **Settings > Privacy & Security > Local Network > Scout**.

**Wrong password.** The server locks an address out for 5 minutes after 10 wrong passwords in 5
minutes, and at a school everyone may share one address. So the app stops at the first rejected
password and asks again; it never retries a password by itself. If the server has locked you out,
the app shows how long to wait.

To sign out or switch servers: **Settings** (the gear button; on the Mac, **Basketball Scout >
Settings…**, ⌘,) > **Sign out**.

## Using the app

The screens follow the web pages (see [Using the app](../README.md#using-the-app) in the main README):

- **Games**: the list on the left (iPad, Mac) or the first screen (iPhone). Search by team. Right-click
  (Mac) or touch and hold (iPhone, iPad) a game for Open, Roster, Add film and Delete; on iPhone you
  can also swipe. A **System status** row appears when the server reports a problem.
- **New game** (+, ⌘N): the game details, then the film.
- **Film**: choose it from Photos or Files, or drop it on the film area (iPad, Mac). Uploads go in
  chunks and continue after a dropped connection or after the app restarts. Pause and Resume are on
  the upload panel. On iPhone and iPad, keep the app open for long uploads: iOS gives an app only a
  short time in the background, and the upload continues when you come back. A link to an MP4 works
  too ("Use a video link").
- **Game page**: the analysis progress, the film with the event timeline, and the tabs Box score,
  Shot chart, Plays, Scouting report, Exports and Data quality. On iPad and Mac the actions (Roster &
  jerseys, Add or Replace film, Re-run analysis, Full re-analysis) are in the toolbar; on iPhone they
  are in the ⋯ menu. On the Mac they are also in the **Game** menu, with ⌘1 to ⌘6 for the tabs.
- **Film player**: Space plays and pauses, ← and → step 5 seconds, [ and ] jump between events
  (with a keyboard on iPad and Mac). Tap an event, a play or a shot to jump to it in the film.
- **Court calibration** ("Calibrate court" under the film): for fixed cameras, as on the web.
- **Scouting report**: generate, read, share, print or copy it.
- **Exports**: the FastScout paste block (copied ready to paste), the FastScout and timeline CSV
  files, the analysis JSON and the report as Markdown. Share them or save them to Files / Finder.
- **Roster & jerseys**: both rosters, CSV import and the template, and the jersey assignments from
  the film. Each track shows a small picture of the player from the film; tap it (iPad, Mac) or
  open the track (iPhone) for up to three larger ones, to tell who an unnamed track is. Save, then
  re-run the analysis when the page offers it.

The app refreshes on its own while film is processing and when you come back to it. ⌘R refreshes on
the Mac and on an iPad with a keyboard; on iPhone and iPad you can also pull down.

## Live games

A live game is analysed while it is played: the **Mac** reads the camera's stream, cuts it into
parts of about two minutes and sends each part to the server, and the stats fill in on the game
page a few minutes behind the play. iPhone and iPad show a live game but do not capture one.
What the server does with the parts, what to expect and the server settings are in the main
README, [Live games](../README.md#live-games).

**Once, on the Mac that will capture:** install ffmpeg, the free tool the app uses to read the
stream. With [Homebrew](https://brew.sh):

```bash
brew install ffmpeg
```

The app looks for it where Homebrew puts it (`/opt/homebrew/bin` or `/usr/local/bin`). Without
it, the Live stream form says **ffmpeg is needed**, with the command to copy, **Check again** and
**Choose ffmpeg…** for one installed somewhere else.

**At the game**

1. **New game** (+), fill in the teams. On the film screen, under **Live stream**, paste the
   camera's **Stream link** (for example `rtmp://192.168.1.50/live`; `rtmps`, `rtsp`, `srt`, `udp`
   and `http(s)` links are accepted too) and press **Start live game**.
2. The game page shows **Live game** with the film received, how far the stats have got ("Stats
   through 12:00") and the parts analysed, and **Capture on this Mac**: Capturing, the parts
   captured, sent and waiting, and the last problem if there was one.
3. Leave Basketball Scout open. The Mac stays awake while it captures. If the network drops, the
   parts wait on the Mac and are sent when it is back; if the camera's stream drops, the app
   reconnects by itself (**Stream lost, reconnecting…**).
4. **End live game** when the game is over. The Mac stops reading the stream and sends the last
   parts; the server analyses them and puts the film together.

Good to know:

- Any device signed in to the server can watch the live game. **End live game** on another
  device (or on the web page) ends it for good: the capturing Mac then stops and says **This game
  no longer takes film**, and keeps the parts it had not sent yet in a folder it shows you.
- If you quit or the Mac restarts during a game, open the app and the game again: **This Mac was
  capturing this game** offers to send the waiting parts and **Resume capture**.
- The stream link is kept in the Keychain while the game is captured and removed when it ends.
  It is never sent to the server and never written to a log.
- The first time the app reads a camera on the local network, macOS asks to let it find devices
  on your local network. Choose **Allow**.
- One live game at a time per Mac.

Live capture has **not been tried with a real camera or a real ffmpeg yet** (only with stand-ins
in the tests): try it at a practice before you rely on it at a game.

## What is stored on the device

- **Server address and username**: in the app's settings.
- **Password**: in the Keychain, never in a file, never in a log.
- **A copy of each game's analysis**, so a game opens instantly: in the app's cache, protected while
  the device is locked, never backed up, and deleted when you sign out.
- **Film you are uploading** from Photos: a copy, deleted when the upload is done or cancelled.
  Films you choose from Files are read in place.
- **Exports**: temporary files, deleted when you share or save them and every time the app starts.
- **Pictures of tracked players**: in memory only while the app is open, never written to the device.
- **Live games** (Mac): the parts not yet sent, in the app's own folder, deleted as each one
  arrives on the server; and the stream link, in the Keychain, until the game ends.

Rosters and analyses name high school students. Treat a device with the app signed in like the
web pages: use a passcode, and sign out on shared devices.

## Troubleshooting

| What you see | What to do |
|---|---|
| "This address needs https" | The address is a full domain name. Use `https://`, or the server's IP address. |
| "Local Network access is off" | iPhone/iPad: Settings > Privacy & Security > Local Network > Scout. |
| "Nothing answered", "Can't find that server" or "The server didn't answer" | Check that the device is on the school network (or VPN) and that the server is running. Open the same address in Safari. |
| "Not a Basketball Scout server" | Something answers at that address, but not Basketball Scout (for example nginx without the app). Check the port. On guest Wi-Fi, sign in to the network first. |
| "Wrong username or password" | Both are case-sensitive. Check `.env` on the server. |
| "Too many wrong passwords" | Wait for the countdown; the lockout ends by itself after 5 minutes. |
| The Mac app asks for the password again after a new build | Builds signed with a different team keep the password in a different keychain. Sign in once more. |
| "ffmpeg is needed" (Mac, Live stream) | `brew install ffmpeg` in Terminal, then **Check again**. |
| "Stream lost, reconnecting…" that never recovers | The Mac cannot reach the camera's link: check that the Mac is on the camera's network and that the link opens in another player (VLC: File > Open Network). **Last problem** shows what ffmpeg said. |
| "This game no longer takes film" | The live game was ended somewhere else, no film arrived for 45 minutes, or the server's length limit was reached. The parts not sent are kept on the Mac; start a new live game for the rest. |

## Tests

**Unit tests** (about 1,850; no server, no network):

```bash
xcodebuild test -project apple/BasketballScout.xcodeproj -scheme BasketballScout \
  -destination 'platform=macOS'
xcodebuild test -project apple/BasketballScout.xcodeproj -scheme BasketballScout \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Or in Xcode: choose the **BasketballScout** scheme and press ⌘U.

**UI tests** (the **BasketballScoutUITests** scheme) drive the app on an iPhone or iPad simulator
against a running server. They create and delete games, so use a throwaway test server, never your
real one:

```bash
# a throwaway server with made-up analysis, on this Mac, run from the repository folder
cat > /tmp/scout-uitest.env <<'EOF'
SCOUT_PROCESSOR=mock
SCOUT_QUEUE_BACKEND=sqlite
SCOUT_DATA_DIR=/tmp/scout-uitest
SCOUT_AUTH_USERNAME=coach
SCOUT_AUTH_PASSWORD=pick-a-test-password
SCOUT_AUTO_REPORT=false
EOF
SCOUT_ENV_FILE=/tmp/scout-uitest.env .venv/bin/python -m uvicorn scout.main:app --host 127.0.0.1 --port 8791 &
SCOUT_ENV_FILE=/tmp/scout-uitest.env .venv/bin/python -m scout.worker &

TEST_RUNNER_SCOUT_UITEST_SERVER=http://127.0.0.1:8791 \
TEST_RUNNER_SCOUT_UITEST_USERNAME=coach \
TEST_RUNNER_SCOUT_UITEST_PASSWORD=pick-a-test-password \
xcodebuild test -project apple/BasketballScout.xcodeproj -scheme BasketballScoutUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

`SCOUT_ENV_FILE` keeps the test server away from your real `.env` (and its Modal and Anthropic keys).
Without those three variables the UI tests are skipped. They run on the iOS Simulator; UI tests on
the Mac need macOS "Automation Mode", which asks for your password the first time.

## Project layout

```
apple/
  BasketballScout.xcodeproj     the project (folders are synchronised: new files are picked up)
  BasketballScout/
    App/                        app entry, windows, menus, navigation
    Core/Models/                the server's data (Codable), labels and derived states
    Core/Networking/            the API client, sign-in checks, errors
    Core/Storage/               Keychain, saved server, protected files
    Core/Services/              uploads, video streaming, job polling, the analysis cache, live capture
    Core/Session/               the signed-in session, games list, game page state
    DesignSystem/               colours, type, cards, badges, notices, formatting
    Features/                   one folder per screen: SignIn, Games, NewGame, GameDetail, Player,
                                Calibration, Stats, Report, Roster, Settings, Live
    AppIcon.icon                the icon (Icon Composer)
  BasketballScoutTests/         unit tests, with real server responses in Fixtures/
  BasketballScoutUITests/       UI tests (need a test server, see above)
  Config/                       Info.plist (local-network http), the Mac entitlements (sandbox; read
                                access to Homebrew's folders so the app can run ffmpeg)
```
