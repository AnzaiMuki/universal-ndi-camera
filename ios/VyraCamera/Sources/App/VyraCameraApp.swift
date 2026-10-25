import SwiftUI

// Point d'entrée de l'app. Un seul écran (ContentView) en version minimale.
@main
struct VyraCameraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate   // scène écran externe (HDMI)
    @StateObject private var manager = StreamManager()
    @StateObject private var discovery = Discovery()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .environmentObject(discovery)
                .preferredColorScheme(.dark)
                .onAppear { ExternalDisplay.shared.capture = manager.capture }
        }
    }
}
