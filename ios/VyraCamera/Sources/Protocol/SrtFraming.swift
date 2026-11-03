import Foundation

// Paquetisation d'une trame UNDI pour SRT « live » (transport à MESSAGES qui peut perdre/réordonner).
// Chaque message devient un FRAGMENT auto-descriptif. Port FIDÈLE de SrtPacket.kt / SrtReassembler.kt
// (source de vérité). En-tête de fragment (12 o, petit-boutiste) :
//   0 u8 version(1) | 1 u8 réservé | 2 u16 nb fragments | 4 u32 frameId | 8 u16 index | 10 u16 longueur
enum SrtPacket {
    static let header = 12
    static let version: UInt8 = 1
    static let maxFrag = 1200   // sous la limite d'un message SRT live (1316 o) avec marge

    static func packetize(_ frame: Data, frameId: UInt32) -> [Data] {
        let total = frame.count
        let n = total == 0 ? 1 : (total + maxFrag - 1) / maxFrag
        var out: [Data] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let start = i * maxFrag
            let len = max(0, min(maxFrag, total - start))
            var pkt = Data(capacity: header + len)
            pkt.append(version)
            pkt.append(0)
            appendLE16(&pkt, UInt16(n))
            appendLE32(&pkt, frameId)
            appendLE16(&pkt, UInt16(i))
            appendLE16(&pkt, UInt16(len))
            if len > 0 { pkt.append(frame.subdata(in: (frame.startIndex + start)..<(frame.startIndex + start + len))) }
            out.append(pkt)
        }
        return out
    }

    private static func appendLE16(_ d: inout Data, _ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
    private static func appendLE32(_ d: inout Data, _ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
}

// Réassemble les trames UNDI à partir des fragments reçus (SRT live). Émet une trame COMPLÈTE et
// INTACTE, en ORDRE de frameId ; abandonne proprement une trame incomplète (pas de désynchronisation).
// `onFrame` reçoit les octets COMPLETS (en-tête UNDI 24 o + charge) — à dispatcher comme en TCP.
final class SrtReassembler {
    private let onFrame: (Data) -> Void
    private let window: Int
    private var pending: [UInt32: [Data?]] = [:]
    private var counts: [UInt32: Int] = [:]
    private var next: UInt32 = 0
    private var maxSeen: Int64 = -1
    private(set) var emitted = 0
    private(set) var dropped = 0

    init(window: Int = 64, onFrame: @escaping (Data) -> Void) {
        self.window = window
        self.onFrame = onFrame
    }

    func offer(_ pkt: Data) {
        guard pkt.count >= SrtPacket.header else { return }
        let b = [UInt8](pkt)
        func u16(_ o: Int) -> Int { Int(b[o]) | (Int(b[o + 1]) << 8) }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24) }
        let count = u16(2)
        let frameId = u32(4)
        let index = u16(8)
        let len = u16(10)
        if count <= 0 || count > 8192 || index >= count || SrtPacket.header + len > pkt.count { return }
        if frameId < next { return }   // trame déjà émise ou abandonnée
        if Int64(frameId) > maxSeen { maxSeen = Int64(frameId) }

        if pending[frameId] == nil { pending[frameId] = Array(repeating: nil, count: count); counts[frameId] = count }
        guard var frags = pending[frameId], frags.count == count, frags[index] == nil else { drain(); return }
        frags[index] = pkt.subdata(in: (pkt.startIndex + SrtPacket.header)..<(pkt.startIndex + SrtPacket.header + len))
        pending[frameId] = frags
        drain()
    }

    func flush() {
        for id in pending.keys.filter({ $0 >= next }).sorted() { tryEmit(id, force: true) }
        pending.removeAll(); counts.removeAll()
        if maxSeen >= 0 { next = UInt32(maxSeen) &+ 1 }
    }

    private func drain() {
        // 1) Fenêtre dure (borne mémoire) : trop de retard → on force l'avancée.
        while maxSeen - Int64(next) >= Int64(window) {
            tryEmit(next, force: true); next &+= 1
        }
        // 2) Émission EN ORDRE tant que la trame attendue est complète.
        while let frags = pending[next], isComplete(next, frags) {
            tryEmit(next, force: true); next &+= 1
        }
    }

    private func isComplete(_ id: UInt32, _ frags: [Data?]) -> Bool {
        guard let c = counts[id] else { return false }
        return frags.compactMap { $0 }.count == c
    }

    /// Émet la trame si complète, sinon l'abandonne (si `force`). Retire l'entrée.
    private func tryEmit(_ id: UInt32, force: Bool) {
        guard let frags = pending[id], let c = counts[id] else { if force { dropped += 1 }; return }
        pending[id] = nil; counts[id] = nil
        guard frags.compactMap({ $0 }).count == c else { dropped += 1; return }
        var bytes = Data()
        for fr in frags { if let fr { bytes.append(fr) } }
        // Intégrité : en-tête UNDI complet + longueur annoncée cohérente.
        guard bytes.count >= 24 else { dropped += 1; return }
        let bb = [UInt8](bytes)
        let length = Int(UInt32(bb[8]) | (UInt32(bb[9]) << 8) | (UInt32(bb[10]) << 16) | (UInt32(bb[11]) << 24))
        guard bytes.count == 24 + length else { dropped += 1; return }
        emitted += 1
        onFrame(bytes)
    }
}
