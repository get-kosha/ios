# Kosha for iOS

Native iOS and iPadOS app for Kosha, the personal finance tracker at https://getkosha.app. Swift and SwiftUI, with shared code in a `KoshaKit` Swift package. watchOS comes later in this repo.

The Android app (`../kosha-android`) was built first and is the reference implementation. Build iOS from the same brief, `../kosha-android/HANDOFF.md` (what to build, the server work, every screen, the design system, the build order; §4.3 has the iOS stack), and follow the decisions and conflict rulings in `../kosha-android/PLAN.md`, so both apps behave the same.

## Sources of truth

- **Behaviour and money rules:** the web app at `../kosha-web` (`CLAUDE.md`, `PRODUCT.md`, `DESIGN.md`). The public API contract is `../kosha-web/src/lib/api-contract.ts`; the app-only API is `../kosha-web/src/server/app-api.server.ts`.
- **Layout:** `../kosha-android/design/screens/light/*.png` (2×), one per screen, named `<page>-<Board>.png`.
- **Exact values:** `../kosha-android/design/source/k.css` and `../kosha-android/design/source/<Board>.dc.html`.
- **Words:** `../kosha-web/messages/<locale>/*.json` (including the phone apps' `app*.json` areas) and `../kosha-web/translations.md`, generated into a String Catalog; never hard-code text.
- **How Android solved it:** `../kosha-android` (`core/model`, `core/network`, `core/data`, `feature/*`) and its tests.

## Rules

- Money is integer minor units with the sign as the direction, ×100 for every currency as the web does. No `Double` for money; use `Int64` (`Decimal` only for display maths).
- Days (`YYYY-MM-DD`) and months (`YYYY-MM`) are in the user's time zone from settings, not the device's.
- Neutral categories (corrections, transfers) are neither income nor spending. Transfers are created through the transfer operations.
- Take month figures and net worth from the server's reports.
- Kosha draws its own inputs: no `DatePicker`, no system keyboard for amounts.
- Every colour, size and type style comes from the Kosha design tokens; light, dark, neutral mode and all five accents must work. Support Dynamic Type.
- AI features render nothing when `meta.ai` says they are off.
- The demo account is read-only.
- Only new transactions queue offline, each with a client id.
- Tokens live in the Keychain. Sign-in uses `ASWebAuthenticationSession` (not ephemeral) with the server's HTTPS app callback. Refreshes are serialised; refresh tokens rotate.
- Never use real account data in tests or screenshots. Use the demo account.

## Checking your work

Build and test with `xcodebuild test` for the app scheme and `swift test` for `KoshaKit`, and compare the screens you touched with their PNGs in light and dark.

## Commits

Conventional Commits (`type(scope): subject`, header 100 characters or fewer), the same as the web repo.
