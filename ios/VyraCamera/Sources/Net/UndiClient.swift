import Foundation
import Network

// Client réseau TCP vers VYRA Studio (Network.framework). Émission (HELLO, STREAM_CONFIG, VIDEO,
// AUDIO, STATS, REPLY, écho CONTROL) ET réception du canal retour (TALLY, CONTROL, CUE, SEEN).
final class UndiClient: Uplink {
    private var conn: NWConnection?
    private var listener: NWListener?   // mode câble USB : attente du pont (voir accept)

    // Santé du lien. Politique d'abandon (comme TcpSink côté Android) : SPS/PPS et images clés ne sont
    // jamais lâchés ; une image intermédiaire l'est si la file d'envoi déborde, et elle est comptée.
    private let statsLock = NSLock()
    private var pendingFrames = 0
    private var dropped = 0
    private var windowBytes = 0
    private var windowStart = DispatchTime.now().uptimeNanoseconds
    private var lastThroughput = 0
    private static let maxPendingFrames = 30
    private let queue = DispatchQueue(label: "com.ndicam.undi.client")
    private var sequence: UInt32 = 0
    private(set) var connected = false
    private var rxBuffer = Data()   // accumulateur de réception (toujours ré-ancré à l'index 0)
    private var didConnect = false  // a atteint .ready au moins une fois sur cette connexion
    private var closing = false     // fermeture VOLONTAIRE (stop) : ne pas signaler de perte

    var onStatus: ((String) -> Void)?
    var onDisconnected: (() -> Void)?   // perte INVOLONTAIRE du lien (déclenche la reconnexion)
    // Canal retour (appelés sur la file du client ; l'appelant repasse sur le thread principal).
    var onTally: ((TallyState) -> Void)?
    var onCommand: ((CameraCommand) -> Void)?
    var onCue: ((Cue) -> Void)?
    var onSeen: (() -> Void)?

    /// Connexion par IP + port (saisie manuelle).
    func connect(host: String, port: UInt16, completion: @escaping (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { completion(false); return }
        connect(endpoint: .hostPort(host: NWEndpoint.Host(host), port: nwPort), label: "\(host):\(port)", completion: completion)
    }

    /// Connexion à un point de terminaison Bonjour découvert (`_undicam._tcp`).
    func connect(endpoint: NWEndpoint, label: String, completion: @escaping (Bool) -> Void) {
        stopListening()
        run(NWConnection(to: endpoint, using: Self.tcpParameters()), label: label, completion: completion)
    }

    /// Mode câble USB : iOS n'a pas d'équivalent à `adb reverse`, l'iPhone ne peut pas joindre le PC
    /// par le câble. Il ÉCOUTE donc, et VYRA Studio vient à lui via usbmuxd (service Apple Mobile Device).
    /// Écoute limitée au bouclage (là où usbmuxd livre ses connexions) : rien n'est exposé sur le Wi-Fi.
    /// Abandon (`completion(false)`) si le pont ne s'est pas présenté au bout de `timeout` secondes.
    func accept(port: UInt16, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { completion(false); return }
        let params = Self.tcpParameters()
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        stopListening()
        conn?.cancel()
        conn = nil
        guard let l = try? NWListener(using: params, on: nwPort) else { completion(false); return }
        listener = l
        // Tout se passe sur `queue` : ces drapeaux n'ont pas besoin de verrou.
        var adopted = false
        var done = false
        let finish: (Bool) -> Void = { ok in if !done { done = true; completion(ok) } }
        l.newConnectionHandler = { [weak self] c in
            guard let self, !adopted else { c.cancel(); return }
            adopted = true
            self.stopListening()
            self.run(c, label: "VYRA Studio (câble USB)", completion: finish)
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed(_) = state, !adopted { self?.stopListening(); finish(false) }
        }
        onStatus?("En attente de VYRA Studio par câble…")
        l.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard !adopted else { return }
            self?.stopListening()
            finish(false)
        }
    }

    private func stopListening() {
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    private static func tcpParameters() -> NWParameters {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true               // latence : désactive Nagle
            tcp.connectionTimeout = 5        // secondes
        }
        return params
    }

    /// Prend en charge une connexion (sortante ou acceptée) : même cycle de vie dans les deux sens.
    private func run(_ c: NWConnection, label: String, completion: @escaping (Bool) -> Void) {
        conn?.cancel()                 // abandonne une éventuelle connexion précédente
        closing = false
        didConnect = false
        conn = c
        var done = false
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.connected = true
                self.didConnect = true
                self.statsLock.lock(); self.pendingFrames = 0; self.statsLock.unlock()
                self.onStatus?("Connecté à \(label)")
                self.rxBuffer.removeAll(keepingCapacity: true)
                self.startReceive()
                if !done { done = true; completion(true) }
            case .failed(let error):
                self.connected = false
                self.onStatus?("Échec : \(error.localizedDescription)")
                if !done { done = true; completion(false) }
                else { self.signalLost() }   // perte après coup → reconnexion
            case .cancelled:
                self.connected = false
                self.signalLost()
            case .waiting(let error):
                self.onStatus?("En attente réseau : \(error.localizedDescription)")
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    var framesDropped: Int { statsLock.lock(); defer { statsLock.unlock() }; return dropped }

    var throughputBps: Int {
        statsLock.lock(); defer { statsLock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now - windowStart
        if elapsed >= 1_000_000_000 {
            lastThroughput = Int(UInt64(windowBytes) * 8 * 1_000_000_000 / elapsed)
            windowBytes = 0
            windowStart = now
        }
        return lastThroughput
    }

    private func writeFrame(type: FrameType, flags: UInt16, ptsUs: Int64, payload: Data, droppable: Bool = false) {
        guard connected, let conn else { return }
        statsLock.lock()
        if droppable && pendingFrames >= Self.maxPendingFrames {
            dropped += 1
            statsLock.unlock()
            return
        }
        pendingFrames += 1
        let header = UndiProtocol.header(type: type, flags: flags, length: payload.count, ptsUs: ptsUs, sequence: sequence)
        sequence &+= 1
        statsLock.unlock()
        var frame = header
        frame.append(payload)
        let size = frame.count
        conn.send(content: frame, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.statsLock.lock()
            self.pendingFrames -= 1
            self.windowBytes += size
            self.statsLock.unlock()
        })
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
        writeFrame(type: .video, flags: flags, ptsUs: ptsUs, payload: annexB, droppable: !keyframe && !config)
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

    /// Réponse rapide du vidéaste → pont (trame REPLY).
    func sendReply(_ reply: Reply) { writeFrame(type: .reply, flags: 0, ptsUs: 0, payload: reply.encodePayload()) }

    /// Télémétrie batterie/thermique → pont (trame STATS).
    func sendStats(_ stats: DeviceStats) { writeFrame(type: .stats, flags: 0, ptsUs: 0, payload: stats.encodePayload()) }

    /// Écho de l'état RÉELLEMENT appliqué → pont (trame CONTROL) : il affiche la vérité, pas sa demande.
    func sendControl(_ cmd: CameraCommand) { writeFrame(type: .control, flags: 0, ptsUs: 0, payload: cmd.encodePayload()) }

    // MARK: - Réception du canal retour

    private func startReceive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.rxBuffer.append(data)
                self.parseFrames()
            }
            if isComplete || error != nil { return }
            self.startReceive()
        }
    }

    private func parseFrames() {
        func u32(_ off: Int) -> UInt32 {
            UInt32(rxBuffer[off]) | (UInt32(rxBuffer[off + 1]) << 8) |
            (UInt32(rxBuffer[off + 2]) << 16) | (UInt32(rxBuffer[off + 3]) << 24)
        }
        while rxBuffer.count >= 24 {
            if u32(0) != UndiProtocol.magic {
                rxBuffer = rxBuffer.subdata(in: 1..<rxBuffer.count)   // resynchronisation sur le MAGIC
                continue
            }
            let type = rxBuffer[5]
            let length = Int(Int32(bitPattern: u32(8)))
            if length < 0 || length > UndiProtocol.maxPayloadSize { rxBuffer.removeAll(); return }
            let total = 24 + length
            if rxBuffer.count < total { return }   // trame incomplète : on attend la suite
            let payload = length > 0 ? rxBuffer.subdata(in: 24..<total) : Data()
            dispatch(type: type, payload: payload)
            rxBuffer = rxBuffer.subdata(in: total..<rxBuffer.count)
        }
    }

    private func dispatch(type: UInt8, payload: Data) {
        switch type {
        case FrameType.tally.rawValue: onTally?(TallyState.decode(payload))
        case FrameType.control.rawValue: onCommand?(CameraCommand.decode(payload))
        case FrameType.cue.rawValue: onCue?(Cue.decode(payload))
        case FrameType.seen.rawValue: onSeen?()
        default: break   // type non exploité dans ce sens
        }
    }

    /// Signale UNE SEULE FOIS une perte involontaire du lien (ni pendant la connexion initiale, ni
    /// lors d'une fermeture volontaire). Le `didConnect = false` empêche les déclenchements multiples.
    private func signalLost() {
        guard didConnect, !closing else { return }
        didConnect = false
        onDisconnected?()
    }

    func close() {
        stopListening()
        closing = true
        didConnect = false
        conn?.cancel()
        conn = nil
        connected = false
    }
}
