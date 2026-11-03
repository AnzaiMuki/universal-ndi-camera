import SwiftUI

// Point d'entrée : lancement animé, puis CLUF (premier lancement), autorisation caméra, viseur.
@main
struct VyraCameraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate   // scène écran externe (HDMI)
    @StateObject private var manager = StreamManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(manager)
                .preferredColorScheme(.dark)
                .onAppear { ExternalDisplay.shared.capture = manager.capture }
        }
    }
}

private struct RootView: View {
    @State private var splashDone = false

    var body: some View {
        if !splashDone {
            VyraSplash { splashDone = true }
        } else {
            LicenseGate {
                CameraPermissionGate {
                    CameraScreen()
                }
            }
        }
    }
}
