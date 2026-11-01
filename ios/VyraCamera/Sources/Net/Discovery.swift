import Foundation
import Network

// Découverte des régies VYRA Studio sur le réseau local (Bonjour `_undicam._tcp`, même service que
// l'app Android). L'IP manuelle reste toujours possible : la découverte n'est qu'un raccourci.
final class Discovery: ObservableObject {
    struct Found: Identifiable, Hashable {
        let id = UUID()
        let name: String           // nom affichable de la régie
        let endpoint: NWEndpoint   // à passer tel quel à UndiClient.connect(endpoint:)
        let hevc: Bool             // le pont annonce (TXT « hevc=1 ») savoir décoder le H.265
    }

    @Published private(set) var services: [Found] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        // Avec TXT : le pont y annonce ses capacités (« hevc=1 »). Un ancien pont n'annonce rien → H.264.
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_undicam._tcp", domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let found: [Found] = results.map { r in
                var label = "Régie VYRA"
                if case let .service(name, _, _, _) = r.endpoint { label = name }
                var hevc = false
                if case let .bonjour(txt) = r.metadata { hevc = txt["hevc"] == "1" }
                return Found(name: label, endpoint: r.endpoint, hevc: hevc)
            }
            DispatchQueue.main.async { self.services = found }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        services = []
    }
}
