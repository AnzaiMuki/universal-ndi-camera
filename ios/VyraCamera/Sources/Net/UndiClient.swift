import Foundation
import Network

// Client réseau TCP vers VYRA Studio (Network.framework). Envoie HELLO + STREAM_CONFIG puis les
// trames VIDEO. Un seul sens (émission) en v1 ; la voie retour (TALLY/CONTROL) viendra ensuite.
final class UndiClient {
    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "com.ndicam.undi.client")
    private var sequence: UInt32 = 0
    private(set) var connected = false

    var onStatus: ((String) -> Void)?

    /// Connexion par IP + port (saisie manuelle).
    func connect(host: String, port: UInt16, completion: @escaping (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { completion(false); return }
        connect(endpoint: .hostPort(host: NWEndpoint.Host(host), port: nwPort), label: "\(host):\(port)", completion: completion)
    }

    /// Connexion à un point de terminaison Bonjour découvert (`_undicam._tcp`).
    func connect(endpoint: NWEndpoint, label: String, completion: @escaping (Bool) -> Void) {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true               // latence : désactive Nagle
            tcp.connectionTimeout = 5        // secondes
        }
        let c = NWConnection(to: endpoint, using: params)
        conn = c
        var done = false
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.connected = true
                self.onStatus?("Connecté à \(label)")
                if !done { done = true; completion(true) }
            case .failed(let error):
                self.connected = false
                self.onStatus?("Échec : \(error.localizedDescription)")
                if !done { done = true; completion(false) }
            case .cancelled:
                self.connected = false
            case .waiting(let error):
                self.onStatus?("En attente réseau : \(error.localizedDescription)")
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func writeFrame(type: FrameType, flags: UInt16, ptsUs: Int64, payload: Data) {
        guard connected, let conn else { return }
        let header = UndiProtocol.header(type: type, flags: flags, length: payload.count, ptsUs: ptsUs, sequence: sequence)
        sequence &+= 1
        var frame = header
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    func sendHello(name: String) {
        writeFrame(type: .hello, flags: 0, ptsUs: 0, payload: DeviceInfo.encodePayload(name: name))
    }

    func sendStreamConfig(_ cfg: StreamConfig) {
        writeFrame(type: .streamConfig, flags: 0, ptsUs: 0, payload: cfg.encodePayload())
    }

    /// Envoie une unité d'accès H.264 (Annex-B). `config` = SPS/PPS, `keyframe` = image clé (IDR).
    func sendVideo(_ annexB: Data, ptsUs: Int64, keyframe: Bool, config: Bool) {
        var flags: UInt16 = 0
        if keyframe { flags |= UndiProtocol.flagKeyframe }
        if config { flags |= UndiProtocol.flagConfig }
        writeFrame(type: .video, flags: flags, ptsUs: ptsUs, payload: annexB)
    }

    /// Envoie un bloc audio PCM. Charge utile : sampleRate(u32 LE) | channels(u16 LE) | PCM int16 LE
    /// (format EXACT attendu par VYRA Studio ; cf. TcpSink.onAudioFrame côté Android).
    func sendAudio(_ pcm: Data, sampleRate: Int, channels: Int, ptsUs: Int64) {
        var payload = Data()
        payload.reserveCapacity(6 + pcm.count)
        var sr = UInt32(sampleRate).littleEndian
        withUnsafeBytes(of: &sr) { payload.append(contentsOf: $0) }
        var ch = UInt16(channels).littleEndian
        withUnsafeBytes(of: &ch) { payload.append(contentsOf: $0) }
        payload.append(pcm)
        writeFrame(type: .audio, flags: 0, ptsUs: ptsUs, payload: payload)
    }

    func close() {
        conn?.cancel()
        conn = nil
        connected = false
    }
}
