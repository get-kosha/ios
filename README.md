# Kosha for iOS

The native iPhone and iPad app for [Kosha](https://getkosha.app), the personal finance tracker. Jot down what you spent, and see how the month compares with a usual one. It signs in to getkosha.app or your own Kosha server, and is written in Swift 6 and SwiftUI with no third-party packages.

The server, the money rules and every string live in the web repo, [get-kosha/web](https://github.com/get-kosha/web). The Android app, [get-kosha/android](https://github.com/get-kosha/android), was built first from the same brief and is the reference: both apps behave the same.

## What it does

- **Every screen of the web app, made for a phone:** Overview, Activity, Add, Recurring, Accounts, Reconcile, Import, Ask Kosha, Settings and the welcome flow. On iPad, a sidebar holds the main pages, as on the web's desktop layout.
- **Add in a few taps.** The amount comes first on Kosha's own calculator keypad. Then pick the category, date and account, add a note and files, and set Repeat to make it a recurring payment.
- **Offline.** Screens open from what the app saved last time. New entries wait on the device and are sent when the connection returns, or in the background. Each entry has its own id, so a retry saves it only once.
- **Sign-in through the browser** with `ASWebAuthenticationSession` and PKCE, on getkosha.app's HTTPS app callback. Passwords, passkeys, Google and two-factor stay on the website. Tokens are kept in the Keychain.
- **App lock** with Face ID, Touch ID or the passcode, and a cover in the app switcher.
- **Outside the app:** a quick-add widget, App Shortcuts (Add expense, Add income, Scan a receipt) and `app.getkosha://add` links.
- **Statements from other apps.** Open a CSV, OFX, QFX or PDF statement in Kosha to reconcile or import it.
- **Optional AI**, with the key you connect in Settings › AI: Describe it, receipt scanning, auto-categorise, the monthly recap and Ask Kosha. When AI is off, these don't appear.
- **12 languages**, Dynamic Type, and VoiceOver labels. Light and dark, five accents, a neutral mode and a choice of number font.
- **The demo account** is read-only, as on the web.

## Build and run

You need Xcode with Swift 6 and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The app supports iOS and iPadOS 17.4 and later. The Xcode project is generated from `project.yml` and isn't in the repo:

```sh
brew install xcodegen
xcodegen generate
open Kosha.xcodeproj    # run the Kosha scheme on a simulator or device
```

Run `xcodegen generate` again after you add files or change `project.yml`.

| Check | Command |
| --- | --- |
| KoshaKit's unit tests, on the Mac | `cd KoshaKit && swift test` |
| The app with those tests, on a simulator | `xcodebuild test -project Kosha.xcodeproj -scheme Kosha -destination 'platform=iOS Simulator,name=<simulator>'` |

To use a Kosha server on your Mac, run `npm run dev` in the web repo. The simulator reaches it at `http://localhost:3000`. In the app, choose **Use your own server** and enter that address. Plain HTTP works only for `localhost` and `127.0.0.1`. Sign in as the demo account, `demo@kosha.local` with the password `kosha-demo-2026`. Never use real account data in tests or screenshots.

Sign-in to getkosha.app uses the HTTPS callback, through the Associated Domains entitlement. Other servers, `localhost` among them, use the `app.getkosha` URL scheme instead: the server's callback page shows an **Open Kosha** button. The app also falls back to the scheme if the HTTPS callback fails.

Launch a debug build with the argument `-InputsKit YES` to see every design component on one screen.

### Strings

Every string comes from the web repo's `messages/<locale>/*.json`. Never hard-code text. After changing messages there, rebuild the String Catalog and its Swift accessors:

```sh
python3 scripts/sync-strings.py ../kosha-web
```

Add strings that only the phone apps show to `messages/<locale>/app.json` in the web repo, or to an `app-<feature>.json` file. Use an `app-ios-*.json` file for strings only iOS shows. Add them in every locale. The App Shortcuts' titles and Siri phrases live in `Kosha/AppShortcuts.xcstrings`.

### Screenshot tour

The `KoshaTour` scheme runs `TourTests`. It signs in to a dev server as the demo account (debug builds only), opens every main screen in light and dark, and keeps a screenshot of each in the `.xcresult`. It skips itself when no server is running. Set `KOSHA_SERVER` to use another address than `http://localhost:3000`.

### Designs

The design boards are in the Android repo, in `../kosha-android/design/`:

- `screens/light/*.png`: one picture per screen
- `source/k.css`: every token and size
- `source/*.dc.html`: each screen's markup

## Project layout

| Path | Contents |
| --- | --- |
| `Kosha/` | The app target: `@main`, the App Intents and shortcuts, the entitlements and privacy manifest |
| `KoshaWidgets/` | The widget extension. It reads a snapshot the app writes to the app group and never calls the server |
| `KoshaUITests/` | The screenshot tour |
| `KoshaKit/Sources/Model` | API models, money, the keypad, quick add, statement helpers, and days and months in the user's time zone. No UI, no I/O |
| `KoshaKit/Sources/API` | The `/api/v1` and `/api/app` client, sign-in, the Keychain token store and the serialised refresh |
| `KoshaKit/Sources/Store` | Cache-first loads, the offline outbox and local preferences |
| `KoshaKit/Sources/Design` | Tokens, fonts, Phosphor icons, generated strings and every component |
| `KoshaKit/Sources/Features` | The screens, one folder per area |

`AGENTS.md` (also `CLAUDE.md`) lists the rules the code depends on. `PLAN.md` records how the app maps to Android, the decisions, where it differs on purpose, and what is still open. The full brief is `../kosha-android/HANDOFF.md`.

## Release

The [iOS workflow](.github/workflows/ios.yml) runs on Blacksmith's macOS 26 Apple Silicon runners. Pull requests run the release-script checks, `swift test` and the app's simulator tests. Every push to `main` runs the same checks, then archives and uploads the app to App Store Connect for TestFlight. A manual run on `main` uses the same path.

Before delivery can run, add these repository secrets:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_BASE64` | Base64-encoded `.p12` containing the team's Apple Development signing identity and private key |
| `APPLE_CERTIFICATE_PASSWORD` | Password protecting that `.p12` |
| `ASC_KEY_ID` | App Store Connect team API key ID |
| `ASC_ISSUER_ID` | That key's issuer ID |
| `ASC_PRIVATE_KEY` | Complete contents of the downloaded `.p8`, including its PEM headers and newlines |

The API key needs permission to manage provisioning for `app.getkosha` and `app.getkosha.widgets`, use cloud-managed distribution signing, and upload builds for team `654ASRW868`. CI imports the existing development identity into a temporary keychain; Xcode manages the app and widget profiles and distribution signing. Signing files and the temporary keychain are removed when the release step exits. Secrets are used only for delivery from `main`.

The upload must finish processing in App Store Connect before testers can install it. In **TestFlight → Internal Testing**, add the build to the tester group, or enable that group's automatic distribution for these uploads. This workflow does not submit the app for public App Review or release it on the App Store.

Once this workflow has been merged, disable the old **Default** Xcode Cloud workflow in its General settings. The Cloud setup script remains available if Cloud builds are needed again.

To upload by hand, run `scripts/release.sh` from a Mac signed into Xcode. It archives with automatic signing for team `654ASRW868` and uploads to App Store Connect. The build number is the commit count, and the version is `MARKETING_VERSION` in `project.yml`. CI fetches the full history to keep that number accurate. A rerun of a commit that was already uploaded cannot upload the same build number again; make a new commit for a new build.

For the HTTPS sign-in callback, the server must have `APPLE_TEAM_ID` set, so it serves `/.well-known/apple-app-site-association` with the app under `applinks` and `webcredentials`. getkosha.app already does.

## Commits

[Conventional Commits](https://www.conventionalcommits.org) (`type(scope): subject`, header 100 characters or fewer), the same as the web repo.
