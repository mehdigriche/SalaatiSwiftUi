import SwiftUI

@main
struct SalaatiSwiftUiApp: App {
    var body: some Scene {
        WindowGroup {
            SalaatiApp()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 400, height: 700)
    }
}
