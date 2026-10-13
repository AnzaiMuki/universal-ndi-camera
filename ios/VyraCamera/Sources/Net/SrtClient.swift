#if SRT_ENABLED
import Foundation
import Darwin
import CSrt

// Transport SRT « live » vers VYRA Studio (libsrt natif, compilé dans le CI). Même protocole UNDI
// que le TCP, mais chaque trame est PAQUETISÉE (SrtPacket) en messages SRT ; au retour, SrtReassembler
// reconstitue les trames intactes. Options calquées sur SrtSink.kt (TRANSTYPE LIVE, PAYLOADSIZE 1316).
final class SrtClient: Uplink {
    private var sock: SRTSOCKET = SRT_INVALID_SOCK
    private let sendQueue = DispatchQueue(label: "com.ndicam.srt.send")   // sérialise les envois (ordre + sûreté)
    private let recvQueue = DispatchQueue(label: "com.ndicam.srt.recv")
    private var frameId: UInt32 = 0
    private var running = false
    private var reassembler: SrtReassembler!

    var onStatus: ((String) -> Void)?
    var onTally: ((TallyState) -> Void)?
    var onCommand: ((CameraCommand) -> Void)?
    var onCue: ((Cue) -> Void)?
    var onSeen: (() -> Void)?
    var onDisconnected: (() -> Void)?

    init() {
        srt_startup()
        reassembler = SrtReassembler { [weak self] frame in self?.dispatchFrame(frame) }
    }

    func connect(host: String, port: UInt16, completion: @escaping (Bool) -> Void) {
        sendQueue.async { [weak self] in
            guard let self else { completion(false); return }
            let s = srt_create_socket()
            guard s != SRT_INVALID_SOCK else { self.onStatus?("Socket SRT indisponible"); completion(false); return }

            var live: Int32 = 0           // SRTT_LIVE
            srt_setsockflag(s, SRTO_TRANSTYPE, &live, Int32(MemoryLayout<Int32>.size))
            var payload: Int32 = 1316
            srt_setsockflag(s, SRTO_PAYLOADSIZE, &payload, Int32(MemoryLayout<Int32>.size))
            var lat: Int32 = 120
            srt_setsockflag(s, SRTO_RCVLATENCY, &lat, Int32(MemoryLayout<Int32>.size))
            var peer: Int32 = 20
            srt_setsockflag(s, SRTO_PEERLATENCY, &peer, Int32(MemoryLayout<Int32>.size))

            var sa = sockaddr_in()
            sa.sin_family = sa_family_t(AF_INET)
            sa.sin_port = in_port_t(port).bigEndian
            guard inet_pton(AF_INET, host, &sa.sin_addr) == 1 else {
                srt_close(s); self.onStatus?("Adresse invalide"); completion(false); return
            }
            let rc = withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    srt_connect(s, $0, Int32(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard rc != SRT_ERROR else {
                srt_close(s); self.onStatus?("Connexion SRT impossible"); completion(false); return
            }
            self.sock = s
            self.running = true
            self.onStatus?("Connecté (SRT) à \(host):\(port)")
            self.startReceive()
            completion(true)
        }
    }

    private func writeFrame(type: FrameType, flags: UInt16, ptsUs: Int64, payload: Data) {
        sendQueue.async { [weak self] in
            guard let self, self.running, self.sock != SRT_INVALID_SOCK else { return }
            let id = self.frameId; self.frameId &+= 1
            var frame = UndiProtocol.header(type: type, flags: flags, length: payload.count, ptsUs: ptsUs, sequence: id)
            frame.append(payload)
            for frag in SrtPacket.packetize(frame, frameId: id) {
                frag.withUnsafeBytes { raw in
                    _ = srt_send(self.sock, raw.bindMemory(to: CChar.self).baseAddress, Int32(frag.count))
                }
            }
        }
    }

    func sendHello(name: String) { writeFrame(type: .hello, flags: 0, ptsUs: 0, payload: DeviceInfo.encodePayload(name: name)) }
    func sendStreamConfig(_ cfg: StreamConfig) { writeFrame(type: .streamConfig, flags: 0, ptsUs: 0, payload: cfg.encodePayload()) }

    func sendVideo(_ annexB: Data, ptsUs: Int64, keyframe: Bool, config: Bool) {
        var flags: UInt16 = 0
        if keyframe { flags |= UndiProtocol.flagKeyframe }
        if config { flags |= UndiProtocol.flagConfig }
        writeFrame(type: .video, flags: flags, ptsUs: ptsUs, payload: annexB)
    }

    func sendAudio(_ pcm: Data, sampleRate: Int, channels: Int, ptsUs: Int64) {
        var payload = Data(); payload.reserveCapacity(6 + pcm.count)
        var sr = UInt32(sampleRate).littleEndian; withUnsafeBytes(of: &sr) { payload.append(contentsOf: $0) }
        var ch = UInt16(channels).littleEndian; withUnsafeBytes(of: &ch) { payload.append(contentsOf: $0) }
        payload.append(pcm)
        writeFrame(type: .audio, flags: 0, ptsUs: ptsUs, payload: payload)
    }

    func sendReply(_ reply: Reply) { writeFrame(type: .reply, flags: 0, ptsUs: 0, payload: reply.encodePayload()) }
    func sendStats(_ stats: DeviceStats) { writeFrame(type: .stats, flags: 0, ptsUs: 0, payload: stats.encodePayload()) }
    func sendControl(_ cmd: CameraCommand) { writeFrame(type: .control, flags: 0, ptsUs: 0, payload: cmd.encodePayload()) }

    // MARK: - Réception (voie retour)

    private func startReceive() {
        recvQueue.async { [weak self] in
            guard let self else { return }
            let cap = 1500
            var buf = [CChar](repeating: 0, count: cap)
            while self.running {
                let n = srt_recvmsg(self.sock, &buf, Int32(cap))
                if n <= 0 { break }   // lien rompu / erreur
                let data = buf.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: Int(n)) }
                self.reassembler.offer(data)
            }
            if self.running { self.running = false; self.onDisconnected?() }
        }
    }

    private func dispatchFrame(_ frame: Data) {
        guard frame.count >= 24 else { return }
        let type = frame[frame.startIndex + 5]
        let payload = frame.subdata(in: (frame.startIndex + 24)..<frame.endIndex)
        switch type {
        case FrameType.tally.rawValue: onTally?(TallyState.decode(payload))
        case FrameType.control.rawValue: onCommand?(CameraCommand.decode(payload))
        case FrameType.cue.rawValue: onCue?(Cue.decode(payload))
        case FrameType.seen.rawValue: onSeen?()
        default: break
        }
    }

    func close() {
        running = false
        sendQueue.async { [weak self] in
            guard let self, self.sock != SRT_INVALID_SOCK else { return }
            srt_close(self.sock)
            self.sock = SRT_INVALID_SOCK
        }
    }
}
#endif
