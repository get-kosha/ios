import AppIntents
import Features

// App Shortcuts: Add expense, Add income and Scan a receipt, for Siri, Spotlight and the Action button. Each opens the
// app on Add. Titles and phrases come from Localizable.xcstrings and AppShortcuts.xcstrings, which
// scripts/sync-strings.py builds from the web's messages.

struct AddExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "Add expense"
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        AppActions.shared.pending = URL(string: "app.getkosha://add?kind=expense")
        return .result()
    }
}

struct AddIncomeIntent: AppIntent {
    static let title: LocalizedStringResource = "Add income"
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        AppActions.shared.pending = URL(string: "app.getkosha://add?kind=income")
        return .result()
    }
}

struct ScanReceiptIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan a receipt"
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        AppActions.shared.pending = URL(string: "app.getkosha://add?kind=expense&scan=1")
        return .result()
    }
}

struct KoshaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddExpenseIntent(), phrases: ["Add an expense in \(.applicationName)"],
                    shortTitle: "Add expense", systemImageName: "minus.circle")
        AppShortcut(intent: AddIncomeIntent(), phrases: ["Add income in \(.applicationName)"],
                    shortTitle: "Add income", systemImageName: "plus.circle")
        AppShortcut(intent: ScanReceiptIntent(), phrases: ["Scan a receipt in \(.applicationName)"],
                    shortTitle: "Scan a receipt", systemImageName: "doc.viewfinder")
    }
}
