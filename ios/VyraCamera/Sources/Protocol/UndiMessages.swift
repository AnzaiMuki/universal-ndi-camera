import Foundation

// Messages UNDI du canal retour et de la télémétrie. Formats EXACTS (source de vérité côté Kotlin :
// Tally.kt, Cue.kt, Reply.kt, DeviceTelemetry.kt, CameraCommand.kt). Toute divergence casse le pont.

// TALLY (pont → téléphone) : 1 octet. bit0 = antenne (program), bit1 = préparation (preview).
struct TallyState: Equatable {
    var program = false
    var preview = false
    static let off = TallyState()
    static let bitProgram = 0x01
    static let bitPreview = 0x02

    static func decode(_ payload: Data) -> TallyState {
        let bits = Int(payload.first ?? 0)
        return TallyState(program: bits & bitProgram != 0, preview: bits & bitPreview != 0)
    }
}

// CUE (pont → téléphone) : urgence(1 octet 0/1) | texte UTF-8. Affiché en bannière sur le HUD.
struct Cue: Equatable {
    var text: String
    var urgent = false
    static let maxLen = 40

    static func decode(_ bytes: Data) -> Cue {
        guard let first = bytes.first else { return Cue(text: "") }
        let urgent = first != 0
        let raw = bytes.count > 1 ? Data(bytes.dropFirst()) : Data()
        let text = sanitize(String(decoding: raw, as: UTF8.self), maxLen: maxLen)
        return Cue(text: text, urgent: urgent)
    }
}

// REPLY (téléphone → pont) : alerte(1 octet 0/1) | texte UTF-8. Réponse rapide du vidéaste.
struct Reply {
    var text: String
    var alert = false
    static let maxLen = 60

    func encodePayload() -> Data {
        let t = Array(UndiText.sanitize(text, maxLen: Reply.maxLen).utf8)
        var d = Data([alert ? 1 : 0])
        d.append(contentsOf: t)
        return d
    }
}

// Télémétrie périodique (téléphone → pont, trame STATS) : batterie u8 (0..100 ou 0xFF) | charge u8 | thermique u8.
enum ThermalLevel: Int {
    case unknown = 0, nominal = 1, warm = 2, hot = 3, critical = 4
}

struct DeviceStats {
    var batteryPercent: Int = -1   // -1 = inconnu
    var charging = false
    var thermal: ThermalLevel = .unknown
    static let unknownBattery = 0xFF

    func encodePayload() -> Data {
        let battery = (batteryPercent >= 0 && batteryPercent <= 100) ? batteryPercent : DeviceStats.unknownBattery
        return Data([UInt8(battery), charging ? 1 : 0, UInt8(thermal.rawValue)])
    }
}

// CONTROL (pont ↔ téléphone) : consigne de réglage caméra. Champs nuls = « ne change pas ».
// Format = lignes `clé=valeur` (compatible java.util.Properties : les lignes `#...` / `!...` sont
// des commentaires). Le même type sert à recevoir une consigne et à renvoyer l'état appliqué.
struct CameraCommand {
    var autoExposure: Bool?
    var iso: Int?
    var exposureTimeNs: Int64?
    var aeCompensation: Int?
    var awbMode: Int?
    var wbManual: Bool?
    var wbKelvin: Int?
    var autoFocus: Bool?
    var focusDistance: Float?
    var zoom: Float?
    var paused: Bool?
    var torch: Bool?
    var audioMuted: Bool?
    var micGainDb: Int?
    var adaptiveBitrate: Bool?
    var bitrateKbps: Int?
    var resolutionHeight: Int?
    var restartStream: Bool?

    var isEmpty: Bool {
        autoExposure == nil && iso == nil && exposureTimeNs == nil && aeCompensation == nil &&
        awbMode == nil && wbManual == nil && wbKelvin == nil && autoFocus == nil &&
        focusDistance == nil && zoom == nil && paused == nil && torch == nil && audioMuted == nil &&
        micGainDb == nil && adaptiveBitrate == nil && bitrateKbps == nil && resolutionHeight == nil &&
        restartStream == nil
    }

    func encodePayload() -> Data {
        var lines: [String] = []
        func put(_ k: String, _ v: String?) { if let v { lines.append("\(k)=\(v)") } }
        put("autoExposure", autoExposure.map(String.init))
        put("iso", iso.map(String.init))
        put("exposureTimeNs", exposureTimeNs.map(String.init))
        put("aeCompensation", aeCompensation.map(String.init))
        put("awbMode", awbMode.map(String.init))
        put("wbManual", wbManual.map(String.init))
        put("wbKelvin", wbKelvin.map(String.init))
        put("autoFocus", autoFocus.map(String.init))
        put("focusDistance", focusDistance.map { String($0) })
        put("zoom", zoom.map { String($0) })
        put("paused", paused.map(String.init))
        put("torch", torch.map(String.init))
        put("audioMuted", audioMuted.map(String.init))
        put("micGainDb", micGainDb.map(String.init))
        put("adaptiveBitrate", adaptiveBitrate.map(String.init))
        put("bitrateKbps", bitrateKbps.map(String.init))
        put("resolutionHeight", resolutionHeight.map(String.init))
        put("restartStream", restartStream.map(String.init))
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func decode(_ payload: Data) -> CameraCommand {
        var map: [String: String] = [:]
        let text = String(decoding: payload, as: UTF8.self)
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!") { continue }
            guard let sep = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
            let key = String(line[line.startIndex..<sep]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { map[key] = value }
        }
        func b(_ k: String) -> Bool? { map[k].flatMap { $0 == "true" ? true : ($0 == "false" ? false : nil) } }
        func i(_ k: String) -> Int? { map[k].flatMap(Int.init) }
        func l(_ k: String) -> Int64? { map[k].flatMap(Int64.init) }
        func f(_ k: String) -> Float? { map[k].flatMap(Float.init) }
        return CameraCommand(
            autoExposure: b("autoExposure"), iso: i("iso"), exposureTimeNs: l("exposureTimeNs"),
            aeCompensation: i("aeCompensation"), awbMode: i("awbMode"), wbManual: b("wbManual"),
            wbKelvin: i("wbKelvin"), autoFocus: b("autoFocus"), focusDistance: f("focusDistance"),
            zoom: f("zoom"), paused: b("paused"), torch: b("torch"), audioMuted: b("audioMuted"),
            micGainDb: i("micGainDb"), adaptiveBitrate: b("adaptiveBitrate"), bitrateKbps: i("bitrateKbps"),
            resolutionHeight: i("resolutionHeight"), restartStream: b("restartStream"))
    }
}

// Nettoyage commun des textes venus du réseau (retire les caractères de contrôle, borne la longueur).
enum UndiText {
    static func sanitize(_ s: String, maxLen: Int) -> String {
        let cleaned = s.unicodeScalars.filter { !($0.value < 0x20 || $0.value == 0x7F) }
        return String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces).prefix(maxLen).description
    }
}

// Raccourci pour les structs ci-dessus.
private extension Cue { static func sanitize(_ s: String, maxLen: Int) -> String { UndiText.sanitize(s, maxLen: maxLen) } }
