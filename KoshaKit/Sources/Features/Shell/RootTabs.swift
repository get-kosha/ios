import SwiftUI
import Design

/// The main tabs, in the tab bar's order. Add is the raised button between Activity and Recurring.
public enum MainTab: String, CaseIterable, Hashable, Sendable {
    case overview, activity, recurring, accounts

    public var label: String {
        switch self {
        case .overview: L.shell_nav_overview()
        case .activity: L.shell_nav_activity()
        case .recurring: L.shell_nav_recurring()
        case .accounts: L.shell_nav_accounts()
        }
    }

    public var icon: String {
        switch self {
        case .overview: "chart-pie-slice"
        case .activity: "list-bullets"
        case .recurring: "arrows-clockwise"
        case .accounts: "bank"
        }
    }
}

/// The phone's shell: the tab bar under the selected tab's screen. M1 shows placeholders; each milestone fills a tab.
public struct RootTabs<Screen: View>: View {
    @Binding var tab: MainTab
    let onAdd: () -> Void
    let screen: (MainTab) -> Screen
    @Environment(\.kosha) private var theme

    public init(tab: Binding<MainTab>, onAdd: @escaping () -> Void, @ViewBuilder screen: @escaping (MainTab) -> Screen) {
        _tab = tab
        self.onAdd = onAdd
        self.screen = screen
    }

    public var body: some View {
        screen(tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.colors.bg)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                TabBar(MainTab.allCases.map { Tab($0, label: $0.label, icon: $0.icon) }, selected: $tab,
                       addLabel: L.shell_add_transaction(), onAdd: onAdd)
            }
    }
}
