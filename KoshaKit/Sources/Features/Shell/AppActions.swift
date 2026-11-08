import Foundation
import Observation

/// Deep links handed over by App Intents, which run in the app's process but outside its views. The root opens them
/// as it opens app.getkosha:// links from the widget.
@MainActor @Observable
public final class AppActions {
    public static let shared = AppActions()
    public var pending: URL?
    private init() {}
}
