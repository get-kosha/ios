# Kosha for iOS: build plan

How the iOS and iPadOS app is built from `../kosha-android/HANDOFF.md`, following the decisions and "Conflicts (the web wins)" rulings in `../kosha-android/PLAN.md`. Those bind iOS too; this file records only what is new or different. The web repo is `../kosha-web` (the Android docs still say `../kosha`).

## Decisions

- **Bundle id** `app.getkosha` (the server's `APP_ID`). OAuth client `kosha-ios`, already registered on every server by `migrations/0009_app_clients.sql`.
- **Minimum iOS 17.4**, which `ASWebAuthenticationSession.Callback.https(host:path:)` needs. iPadOS the same.
- **XcodeGen** (`project.yml`); the `.xcodeproj` is generated and git-ignored. Install with `brew install xcodegen` (not on this Mac yet).
- **Swift 6** (strict concurrency), SwiftUI, Observation (`@Observable`), Swift Testing for unit tests, XCUITest for the screenshot tour.
- **No third-party packages.** Everything Android used a library for has a system framework here (see the table below).
- **App Store first.** watchOS after M10.
- **Apple Team ID:** needed in M2 for the Associated Domains entitlement and for `APPLE_TEAM_ID` on getkosha.app. I'll ask then.

Carried over from Android's PLAN.md, unchanged: money is ×100 for every currency (Conflicts 1); the keypad caps each number's whole part at 8 digits (2); Fix balance uses `update_account { balance }` (3); a transfer's amount includes the fee (4); the phone converts server totals at server rates but never sums rows (5); category icons are an emoji or `ph:<name>` (6). Sign-in asks for `resource=<server>/api/v1`, demo uses `login_hint=demo&prompt=login`, sign-out revokes at `/api/auth/oauth2/revoke`, own servers are checked through discovery then `/api/app/meta` (no dynamic registration), refreshes resend the same refresh token after 429, 408 or 5xx, and the outbox keeps entries on 429 and 5xx.

## Android modules → Swift targets

One Swift package, `KoshaKit`, shared by the app, the widget extension and later the watch app. Its library targets mirror Android's `core:*` modules; the feature screens live in one `Features` target, because SwiftUI screens have no per-module wiring to justify a target each.

| Android | iOS | Contents |
|---|---|---|
| `core:model` | `KoshaKit/Model` | API models (`Api.kt`), `Keypad`, `Money`, `EntryKind`, quick-add parser, statement helpers, day and month maths in the user's zone. No UI, no I/O. |
| `core:network` | `KoshaKit/API` | `KoshaAPI` (URLSession, `/api/v1` and `/api/app`), `TokenStore` (Keychain), serialised refresh (an actor), `SignInFlow` (PKCE, state and `iss` checks). |
| `core:data` | `KoshaKit/Store` | `Cache` (JSON files), `Outbox`, `Kosha` (cache-first loads), local prefs. |
| `core:design` | `KoshaKit/Design` | Tokens, fonts, Phosphor, category icons, every component of the Inputs kit. |
| `core:ui` | `KoshaKit/Design` (shell parts) | Header, banners, shared month and currency. Android split these out only to keep `core:design` free of data; here they sit in `Design` and take plain values. |
| `feature:*` | `KoshaKit/Features` | One folder per Android feature module: Auth, Add, Overview, Activity, Recurring, Accounts, Statements, Settings, Welcome. |
| `app` | `Kosha` (iOS app target) | `@main`, root navigation, tab bar and iPad sidebar, lock, scene handling, BGTask registration, App Shortcuts. |
| `app/widget` | `KoshaWidgets` (extension) | WidgetKit quick-add and spent-so-far widgets, App Intents. |
| — | `KoshaTests`, `KoshaUITests` | Swift Testing runs through `swift test` on `KoshaKit`; the XCUITest tour mirrors `TourTest.kt`. |
| `wear` (later) | `KoshaWatch` (later) | Quick-add keypad and a "spent so far" complication. |

Strings: `scripts/sync-strings.py` builds `Kosha/Localizable.xcstrings` from `../kosha-web/messages/<locale>/*.json` in all 12 languages, plurals included (a String Catalog handles the two-selector import messages Android couldn't, through `%#@a@ %#@b@` substitutions). Icons: `scripts/phosphor-codes.py` writes the Phosphor name → code point table as a Swift file. Fonts (Geist, Geist Mono, Phosphor regular and fill) are the same files Android bundles.

## Android library → iOS framework

| Need | Android | iOS |
|---|---|---|
| Browser sign-in | Auth Tab / Custom Tabs | `ASWebAuthenticationSession`, not ephemeral |
| Token storage | Keystore AES-GCM | Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, shared with the widget through a keychain access group) |
| HTTP and JSON | OkHttp, kotlinx.serialization | `URLSession`, `Codable` |
| Cache and outbox | JSON files (`AtomicFile`) | JSON files in the App Group container, atomic writes |
| Background send | WorkManager | `BGTaskScheduler` (`BGAppRefreshTask`) and `NWPathMonitor`; sent at once on reconnect while the app runs |
| Biometric lock | BiometricPrompt | `LocalAuthentication` (`.deviceOwnerAuthentication`, so the passcode works too) |
| Hidden in recents | `FLAG_SECURE` | A cover view while the scene is not active |
| Charts | Compose Canvas | Swift Charts where it can draw the design; `Canvas` otherwise |
| Camera | CameraX | `AVFoundation` (receipt frame), `PhotosPicker`, `fileImporter` |
| Widget | Glance | WidgetKit, App Intents |
| Shortcuts | app shortcuts | App Shortcuts (Add expense, Add income, Scan receipt) and Home Screen quick actions |
| Share target | intent filter | Document types for CSV, OFX, QFX and PDF (Open in Kosha); a Share extension only if that isn't enough |
| Haptics | `HapticFeedback` | `sensoryFeedback` (`.selection` on keys, `.success` on save, `.warning` on errors) |
| Per-app language | `locales_config` | `CFBundleLocalizations` plus the `language` setting applied as the SwiftUI `locale` |

## iOS-specific work

- **Sign-in callback.** For getkosha.app the session uses `.https(host: "getkosha.app", path: "/app/oauth/callback")`, which skips consent. That needs the Associated Domains entitlement (`applinks:getkosha.app` and `webcredentials:getkosha.app`) and the server's `apple-app-site-association` listing the app under `webcredentials` (milestone I0). An app can only be associated with the domains in its entitlement, so a self-hosted server, and `localhost` in development, use `.customScheme("app.getkosha")`: the server still redirects to its `/app/oauth/callback` page, and its **Open Kosha** button (`app.getkosha:/oauth/callback?…`) ends the session. That is Android's fallback too. If the HTTPS session fails because the association isn't verified yet (getkosha.app before `APPLE_TEAM_ID` is set), the app falls back to the custom scheme.
- **Associated domains in development.** iOS fetches `apple-app-site-association` through Apple's CDN, which can't reach `localhost`. Dev builds sign in to a local server through the custom-scheme fallback; the HTTPS path is tested against getkosha.app once it serves the file.
- **iPad.** A `NavigationSplitView` sidebar with Overview, Activity, Recurring and Accounts, Add as a toolbar button, and the phone screens as the content and detail columns, like the web's desktop layout.
- **Widgets.** The app writes the month figures the widget shows to the App Group cache; the widget never calls the server. Quick add opens the app's Add through an App Intent.
- **Dynamic Type.** Every type style scales with `@ScaledMetric` / `relativeTo:` from the token sizes; rows grow rather than truncate money.

## Server gaps for iOS

Checked in milestone I0 on `../kosha-web` branch `feat/ios-app` (from `main`, which already has the merged `feat/mobile-app-api` and `feat/mobile-app-hardening` work):

- **Added:** a `webcredentials` entry in `/.well-known/apple-app-site-association` next to `applinks`. Apple's docs say only that the callback host "must be a member of a domain associated with the app"; in practice iOS checks the `webcredentials` service, and sessions fail with "HTTPS callbacks require Associated Domains using the webcredentials service type" without it.
- **Already the same as Android, no change:** `kosha-ios` is in `APP_CLIENTS` (consent skipped only on `APP_CALLBACK`, `/api/app` access, the app rate-limit bucket, `Accept-Language` on `/api/v1`, `grant_id` tokens), in migration 0009 with PKCE and `skipConsent`, and in the 0010 and 0012 refresh-overlap triggers. `ensureAppClients` sets its redirects and resource link with Android's.
- **Owner, before release:** set `APPLE_TEAM_ID` on getkosha.app (a var, not a secret), merge and deploy `feat/ios-app`.

## Where iOS differs from Android on purpose

- **One `Features` target instead of nine feature modules.** Gradle modules speed up Android builds and enforce boundaries Hilt needs; SwiftPM targets would add public-API boilerplate for every view with no gain at this size.
- **No dependency injection framework.** An `@Observable` `AppModel` passed through the environment replaces Hilt.
- **System sheet container.** Sheets use SwiftUI's `.sheet` with `presentationDetents`, `presentationCornerRadius(24)` and Kosha's own content, grab handle and scrim colour. Android likewise used Material only for drag, insets and back.
- **Custom-drawn time wheel**, not `UIPickerView` or `Picker(.wheel)`: the rule is that Kosha draws its own inputs, and the design's band and fades differ from the system wheel.
- **Passcode as the lock's fallback.** `.deviceOwnerAuthentication` offers the device passcode after Face ID fails, which is what LockScreen's "Use passcode" asks for.

## Android bugs and gaps noted, not copied

From Android's PLAN.md "Still open", to do right here rather than port:

- The `motion` preference must reach every animation, not only the charts (SwiftUI: one `Motion` environment value read by every animated view, with the system's Reduce Motion as Reduced).
- A credit card's **Pay** should open Add as a transfer with the card as To and the owed amount filled in.
- Android's `feature:accounts` borrows a helper file from `feature:recurring`; here shared helpers go in `Design` from the start.

Anything else found while porting gets listed here.

## Milestones

| # | Milestone | Status |
|---|---|---|
| I0 | iOS server bits in `../kosha-web` | Done: `webcredentials` in apple-app-site-association (`1a8f8f9`, now on main and live on getkosha.app with team `654ASRW868`). |
| I1 | Project, KoshaKit and design system | Done: XcodeGen project, KoshaKit (Model, API, Store, Design, Features), tokens from k.css (light, dark, five accents, s1–s6, neutral mode, density, figures, motion), Geist and Geist Mono, Phosphor regular and fill, category icons, the String Catalog, every component on the debug Inputs kit (`-InputsKit YES`), the tab bar shell, launch screen and app icon. `Keypad` and `Money` pass Android's test cases. |
| M2 | Sign-in and session | Done in code: ASWebAuthenticationSession (shared, not ephemeral) with the HTTPS callback on getkosha.app and the `app.getkosha` scheme elsewhere, PKCE with state and `iss` checks, own server with a live check, demo, Keychain tokens, serialised refresh (an actor) that keeps the session on 429/408/5xx, revoke on sign-out, Launch, Finishing, SignInError, app lock (Face ID, Touch ID or passcode) and the app-switcher cover. To check on the simulator. |
| M3 | Data layer | Done in code: typed client, cache-first `Kosha.load` (JSON files in the app group), the outbox with client ids (kept on 429/5xx and offline, 409 checked), NWPathMonitor and a BGAppRefreshTask, the shared month and currency, preferences applied at once, banners, the header with the month, currency and account-menu sheets, shared pickers (account, category, date and time, amount). |
| M4–M9 | Screens | Built in parallel by area (Add; Overview, Search and Ask; Activity; Recurring and Accounts; Reconcile and Import; Settings, Welcome and AI settings), merged, then each area compared with its PNGs from the tour's screenshots and fixed. A Codex review of the foundation fixed sign-in, refresh, outbox and date-parsing edge cases and added 31 tests; a Codex pass tightened the design components. |
| M10 | Polish and release | Mostly done. Checked on the iPhone 18 Pro (iOS 27.2): sign-in through the browser against the local server, the tour in light and dark (30 screens), neutral mode, the blue accent, the largest text size and the VoiceOver tree. Built: the quick-add widget (reads a snapshot the app writes, no server calls), App Shortcuts (Add expense, Add income, Scan a receipt) with phrases from the web's messages, app.getkosha://add deep links, the iPad sidebar, and the XCUITest tour (`TourTests`, debug-only demo sign-in through launch arguments). |

Each screen is done when it matches its PNG in light and dark, works in neutral mode and every accent, takes every string from the String Catalog, has VoiceOver labels, holds up at the largest Dynamic Type size, reads from the cache offline, is read-only for the demo and shows no trace of AI when AI is off.

## Notes from building

- **Differences from Android found while building (not copied):**
  - The header's currency pill cycles through the main currency plus the active accounts' currencies in the saved order (web shell.tsx `currencyOptions`); Android uses only the saved order, so it hides the pill for accounts that never reordered.
  - A card's Pay in Needs attention prefills the transfer (card as To, owed amount); Android opens an empty one.
  - Android reads some AI and suggestion preferences with a default of "0"; the web's PREFS default them to "1". iOS uses the web's defaults.
  - Android's Activity cache key used `String.hashCode`; iOS uses a stable FNV hash (Swift's hash changes every launch).
- **Platform differences kept for now:** iOS 27 draws partial-height sheets inset from the screen edges, where the boards attach them at the bottom; matching it needs a Kosha-drawn sheet container. The wordmark asset draws its "o" as the coin, where the Launch and SignIn boards show a plain "o" set in Bricolage Grotesque.
- **Still to do:** a full VoiceOver pass by hand, the sheets and states the tour can't open (checked by reading the code), and the App Store build (signing, TestFlight). watchOS comes after.

- **Strings.** `scripts/sync-strings.py` keeps each message's `{name}` variables and `{#tag}` markup in the catalog and fills them by name in `L`, so messages read as on the web. Plurals are stored one entry per case (`key|one`, `key|any`, and `key|one|any` for the import messages with two selectors) and picked with the language's CLDR rules through a `kosha.plural` probe entry, so the two-selector messages Android couldn't express work here. The app target gets its own small catalogs for App Intents titles and Siri phrases (`Kosha/Localizable.xcstrings`, `Kosha/AppShortcuts.xcstrings`). iOS-only strings live in the web repo's `messages/<locale>/app-ios-*.json`.
- **Swift Codable has no field defaults.** Models use `@D` (the type's default when a field is missing or null) and `@Rounded` (whole minor units from the web's unrounded reads), Android's `= default` and `RoundedLong`.
- **The package builds for the Mac too,** so `swift test` runs there. iOS-only modifiers go through `Design/Platform.swift`.
- **Testing device:** iPhone 18 Pro simulator, which needs an iOS runtime newer than 27.1.
- **Web repo:** `npm run db:demo` fails on Node 26 (`ERR_UNSUPPORTED_ESM_URL_SCHEME` for a `virtual:` import); the local database already had the demo account.
