import SwiftUI
import Design
import Features

@main
struct KoshaApp: App {
    var body: some Scene {
        WindowGroup {
            AppRoot()
        }
    }
}

/// M1: the tab shell with placeholder tabs. Debug builds open the Inputs kit with `-InputsKit YES`.
struct AppRoot: View {
    @State private var tab = MainTab.overview

    var body: some View {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "InputsKit") {
            InputsKit()
        } else {
            shell
        }
        #else
        shell
        #endif
    }

    private var shell: some View {
        RootTabs(tab: $tab, onAdd: {}) { tab in
            Text(tab.rawValue).kFont(.page)
        }
        .koshaTheme(ThemeSettings(language: L.resolve(nil)))
        .onAppear { L.use(language: L.resolve(nil)) }
    }
}
