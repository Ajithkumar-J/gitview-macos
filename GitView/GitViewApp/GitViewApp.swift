import SwiftUI

@main
struct GitViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.titleBar)
    }
}
