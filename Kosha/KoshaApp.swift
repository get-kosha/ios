import SwiftUI
import BackgroundTasks
import WidgetKit
import Store
import Features

/// The background task that sends entries saved offline once there is a connection.
private let outboxTask = "app.getkosha.outbox"

@main
struct KoshaApp: App {
    @State private var kosha: Kosha

    init() {
        // The app and its widget share the session through this keychain group.
        let kosha = Kosha(accessGroup: "654ASRW868.app.getkosha")
        _kosha = State(initialValue: kosha)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: outboxTask, using: nil) { task in
            Task { @MainActor in
                kosha.sendOutbox()
                try? await Task.sleep(for: .seconds(20))
                task.setTaskCompleted(success: kosha.waiting.isEmpty)
            }
        }
        kosha.widgetChanged = { WidgetCenter.shared.reloadAllTimelines() }
        kosha.scheduleSend = {
            let request = BGAppRefreshTaskRequest(identifier: outboxTask)
            request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
            try? BGTaskScheduler.shared.submit(request)
        }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "InputsKit") {
                InputsKit()
            } else {
                KoshaRoot(kosha: kosha)
            }
            #else
            KoshaRoot(kosha: kosha)
            #endif
        }
    }
}
