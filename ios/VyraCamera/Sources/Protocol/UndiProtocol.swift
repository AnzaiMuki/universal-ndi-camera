import Foundation

// Port fidèle du protocole UNDI (source de vérité : core/protocol/UndiFrame.kt côté Android/Studio).
// En-tête fixe 24 octets, petit-boutiste, suivi de la charge utile. L'iPhone doit produire EXACTEMENT
// le même format pour que VYRA Studio le reconnaisse comme une caméra.

enum FrameType: UInt8 {
    case hello = 0x01
    case streamConfig = 0x02
    case video = 0x03
    case audio = 0x04
    case control = 0x05
    case tally = 0x06
    case heartbeat = 0x07
    case stats = 0x08
    case cue = 0x0D
    case reply = 0x0E
    case seen = 0x0F
}

enum UndiProtocol {
    static let magic: UInt32 = 0x4944_4E55   // « UNDI » en petit-boutiste (U=0x55 N=0x4E D=0x44 I=0x49)
    static let version: UInt8 = 7
    static let headerSize = 24
    static let flagKeyframe: UInt16 = 0x0001
    static let flagConfig: UInt16 = 0x0002
    static let maxPayloadSize = 8 * 1024 * 1024

    /// Sérialise l'en-tête 24 octets (petit-boutiste). `sequence` = compteur croissant.
    static func header(type: FrameType, flags: UInt16, length: Int, ptsUs: Int64, sequence: UInt32) -> Data {
        var d = Data()
        d.reserveCapacity(headerSize)
        func put32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
        func put64(_ v: Int64)  { var le = v.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
        put32(magic)                       // offset 0
        d.append(version)                  // offset 4
        d.append(type.rawValue)            // offset 5
        put16(flags)                       // offset 6
        put32(UInt32(truncatingIfNeeded: length)) // offset 8
        put64(ptsUs)                       // offset 12
        put32(sequence)                    // offset 20
        return d
    }
}

// Paramètres de flux, envoyés en trame STREAM_CONFIG. 17 octets, petit-boutiste.
struct StreamConfig {
    enum Codec: UInt8 { case h264 = 0, hevc = 1 }
    var codec: Codec = .h264
    var width: Int
    var height: Int
    var fps: Int
    var bitrateBps: Int

    func encodePayload() -> Data {
        var d = Data()
        d.reserveCapacity(17)
        d.append(codec.rawValue)
        func put32(_ v: Int32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
        put32(Int32(width)); put32(Int32(height)); put32(Int32(fps)); put32(Int32(bitrateBps))
        return d
    }
}

// HELLO = nom de l'appareil en UTF-8 (nettoyé des retours à la ligne, borné). Le pont retombe sur
// « Téléphone » si le nom est vide (cf. DeviceInfo.decodePayload côté Kotlin).
enum DeviceInfo {
    static func encodePayload(name: String) -> Data {
        let clean = name
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return Data(String(clean.prefix(64)).utf8)
    }
}
