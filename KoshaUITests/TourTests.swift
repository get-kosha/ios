import XCTest

/// Run with the KoshaTour scheme. Signs in to a Kosha dev server as the read-only demo account, opens every main screen in light and dark, and keeps a
/// screenshot of each as an attachment (export them from the .xcresult). Fails if a screen crashes. Needs `npm run dev`
/// in ../kosha-web; the simulator reaches localhost directly. Skipped when the server can't be reached. Mirrors the
/// Android app's TourTest.kt; the app does the signing in itself (debug builds only), since UI tests run in their own
/// process.
final class TourTests: XCTestCase {
    private let server = ProcessInfo.processInfo.environment["KOSHA_SERVER"] ?? "http://localhost:3000"

    private let screens = [
        "overview", "activity", "recurring", "accounts", "add", "add-transfer", "account-detail", "investment-detail",
        "account-form", "exchanges", "reconcile", "import", "recurring-form", "ask",
    ] + ["list", "profile", "security", "general", "appearance", "currencies", "categories", "events", "rules", "recurring",
         "ai", "ai-privacy", "ai-log", "data", "api", "delete"].map { "settings-\($0)" }

    override func setUp() async throws {
        continueAfterFailure = true
        let url = URL(string: "\(server)/api/app/meta")!
        let status = try? await (URLSession.shared.data(from: url).1 as? HTTPURLResponse)?.statusCode
        try XCTSkipUnless(status == 401, "No Kosha dev server at \(server)")
    }

    @MainActor func testTour() throws {
        let app = XCUIApplication()
        for dark in [false, true] {
            for screen in screens {
                app.launchArguments = ["-TourServer", server, "-TourScreen", screen, "-TourDark", dark ? "YES" : "NO"]
                app.launch()
                // Let the saved copy and the server's answer settle.
                sleep(4)
                XCTAssertEqual(app.state, .runningForeground, "\(screen) crashed")
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "\(dark ? "dark" : "light")-\(screen)"
                shot.lifetime = .keepAlways
                add(shot)
            }
        }
    }
}
