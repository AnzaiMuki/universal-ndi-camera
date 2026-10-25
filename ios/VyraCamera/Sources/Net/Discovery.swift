import Foundation
import Network

// Découverte des régies VYRA Studio sur le réseau local (Bonjour `_undicam._tcp`, même service que
// l'app Android). L'IP manuelle reste toujours possible : la découverte n'est qu'un raccourci.
final class Discovery: ObservableObject {
    struct Found: Identifiable, Hashable {
        let id = UUID()
        let name: String           // nom affichable de la régie
        let endpoint: NWEndpoint   // à passer tel quel à UndiClient.connect(endpoint:)
    }

    @Published private(set) var services: [Found] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: "_undicam._tcp", domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let found: [Found] = results.map { r in
                var label = "Régie VYRA"
                if case let .service(name, _, _, _) = r.endpoint { label = name }
                return Found(name: label, endpoint: r.endpoint)
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
