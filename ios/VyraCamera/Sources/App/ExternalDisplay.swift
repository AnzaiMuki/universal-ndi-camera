import SwiftUI
import UIKit
import AVFoundation
import Combine

// Sortie HDMI de l'iPhone (maquette validée « Entrée HDMI », parité avec l'Android) : branché via un
// adaptateur Lightning/USB-C → HDMI sur une carte d'acquisition, l'iPhone devient une caméra filaire,
// sans encodage ni réseau.
//
// Par défaut iOS RECOPIE l'écran (boutons compris). En « Caméra seule », l'app pose une fenêtre sur la
// scène de l'écran externe : iOS cesse alors la recopie et n'y affiche que l'image caméra, en 16:9.
// L'image vient directement des tampons de capture (AVSampleBufferDisplayLayer) : aucun réencodage.
@MainActor
final class ExternalDisplay: ObservableObject {
    static let shared = ExternalDisplay()
    private static let cleanKey = "vyra_hdmi.clean"

    /// Un écran externe (HDMI) est branché.
    @Published private(set) var connected = false
    /// « Caméra seule » (vrai, défaut) ou « Copie d'écran » (faux). Mémorisé entre les sessions.
    @Published var clean: Bool {
        didSet { UserDefaults.standard.set(clean, forKey: Self.cleanKey); route() }
    }

    /// Source des images ; posée au lancement par l'app (l'ordre avec le branchement est indifférent).
    weak var capture: CameraCapture? { didSet { route() } }
    private weak var layer: AVSampleBufferDisplayLayer?

    private init() {
        clean = UserDefaults.standard.object(forKey: Self.cleanKey) as? Bool ?? true
    }

    fileprivate func attach(_ layer: AVSampleBufferDisplayLayer?) {
        self.layer = layer
        connected = layer != nil
        route()
    }

    /// Branche les images caméra sur l'écran externe seulement quand il est affiché.
    private func route() {
        guard let capture else { return }
        guard clean, let layer else { capture.setExternalSink(nil); return }
        capture.setExternalSink { [weak layer] sample in
            guard let layer else { return }
            if layer.status == .failed { layer.flush() }
            Self.markDisplayImmediately(sample)
            layer.enqueue(sample)
        }
    }

    /// Affichage à réception, sans horloge de présentation : latence minimale.
    nonisolated private static func markDisplayImmediately(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}

// MARK: - Scène de l'écran externe

/// Oriente la scène de l'écran externe vers [ExternalSceneDelegate] ; les autres scènes restent à SwiftUI.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role.isExternalDisplay { config.delegateClass = ExternalSceneDelegate.self }
        return config
    }
}

private extension UISceneSession.Role {
    var isExternalDisplay: Bool {
        if #available(iOS 16.0, *), self == .windowExternalDisplayNonInteractive { return true }
        return rawValue == "UIWindowSceneSessionRoleExternalDisplay"   // nom d'avant iOS 16
    }
}

@MainActor
final class ExternalSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    private var cleanSub: AnyCancellable?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let controller = ExternalCameraController()
        let w = UIWindow(windowScene: windowScene)
        w.rootViewController = controller
        window = w
        let ext = ExternalDisplay.shared
        ext.attach(controller.displayLayer)
        // Fenêtre visible = « Caméra seule » ; masquée = iOS reprend la recopie d'écran.
        cleanSub = ext.$clean.sink { [weak w] clean in w?.isHidden = !clean }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        cleanSub = nil
        window = nil
        ExternalDisplay.shared.attach(nil)
    }
}

/// Image caméra la plus grande possible en 16:9, centrée sur fond noir.
final class ExternalCameraController: UIViewController {
    let displayLayer = AVSampleBufferDisplayLayer()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(displayLayer)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        displayLayer.frame = view.bounds
    }
}

// MARK: - Bandeau « Écran HDMI branché »

/// Choix Caméra seule / Copie d'écran. Se replie après quelques secondes en une pastille « HDMI »
/// (pour ne pas masquer le viseur) ; un appui le rouvre.
struct HdmiBanner: View {
    @ObservedObject var display: ExternalDisplay
    @State private var expanded = true
    @State private var token = 0

    private let ink = Color(red: 0.918, green: 0.941, blue: 0.925)    // #EAF0EC
    private let sage = Color(red: 0.616, green: 0.690, blue: 0.651)   // #9DB0A6
    private let green = Color(red: 0.133, green: 0.773, blue: 0.369)  // #22C55E
    private let accent = Color(red: 0.086, green: 0.639, blue: 0.290) // #16A34A
    private let bg = Color(red: 0.055, green: 0.075, blue: 0.094).opacity(0.92)

    var body: some View {
        Group {
            if expanded { full } else { pill }
        }
        .onAppear(perform: scheduleCollapse)
        .onChange(of: display.clean) { _ in scheduleCollapse() }
    }

    private var pill: some View {
        Button { expanded = true; scheduleCollapse() } label: {
            HStack(spacing: 6) {
                Circle().fill(green).frame(width: 7, height: 7)
                Text("HDMI").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(bg, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.14)))
        }
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(green).frame(width: 7, height: 7)
                Text("Écran HDMI branché").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
            }
            HStack(spacing: 0) {
                option(true, "Caméra seule")
                option(false, "Copie d'écran")
            }
            .padding(2)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(10)
        .frame(width: 260)
        .background(bg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.14)))
    }

    private func option(_ value: Bool, _ label: String) -> some View {
        let on = display.clean == value
        return Button { display.clean = value } label: {
            Text(label).font(.system(size: 11, weight: .semibold))
                .foregroundColor(on ? .white : sage)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(on ? accent : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func scheduleCollapse() {
        token += 1
        let t = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if token == t { expanded = false }
        }
    }
}
