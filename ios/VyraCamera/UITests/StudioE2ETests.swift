import XCTest
import Darwin

// Test de bout en bout dans le simulateur : le test joue VYRA Studio. L'app passe en « USB (câble) » ;
// le simulateur partageant le réseau du Mac, le test la rejoint sur 127.0.0.1:6789 exactement comme
// Studio via usbmuxd. Il vérifie le direct (HELLO, config, H.264 décodable) et le canal retour (tally,
// consigne, pilotage, réponse, « vu »). La caméra est la mire de synthèse du simulateur.
//
// Captures d'écran et flux reçu : écrits dans $E2E_OUT (passé par le CI) et joints au rapport.
final class StudioE2ETests: XCTestCase {
    private var app: XCUIApplication!
    private let outDir = ProcessInfo.processInfo.environment["E2E_OUT"].map { URL(fileURLWithPath: $0) }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testUsbLiveSessionWithStudio() throws {
        XCTAssertTrue(app.buttons["Passer en direct"].waitForExistence(timeout: 10))
        shot("1-accueil")

        app.buttons["USB (câble)"].tap()
        let mic = app.switches["Micro"]
        if mic.exists, (mic.value as? String) == "1" {
            // Micro coupé : pas de demande d'autorisation système pendant le test.
            mic.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        shot("2-mode-usb")
        app.buttons["Passer en direct"].tap()

        let studio = try StudioMock.connect(port: 6789, timeout: 15)
        defer { studio.close() }

        // Présentation de la caméra.
        let hello = try studio.next(.hello)
        XCTAssertFalse(hello.payload.isEmpty, "HELLO sans nom d'appareil")
        let cfg = try studio.next(.streamConfig)
        XCTAssertEqual(cfg.payload.count, 17)
        XCTAssertEqual(u32(cfg.payload, 1), 1280)
        XCTAssertEqual(u32(cfg.payload, 5), 720)
        XCTAssertEqual(u32(cfg.payload, 9), 30)

        // Vidéo pendant 3 s : SPS/PPS, image clé, cadence.
        var video = Data()
        var frames = 0, sawConfig = false, sawKey = false
        var nalTypes = Set<UInt8>()   // types NAL vus (5 = IDR, 1 = P, 7/8 = SPS/PPS) : diagnostic
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            let f = try studio.next(.video)
            if f.flags & UndiProtocol.flagConfig != 0 { sawConfig = true } else { frames += 1 }
            if f.flags & UndiProtocol.flagKeyframe != 0 { sawKey = true }
            let b = [UInt8](f.payload)
            for k in 0..<max(0, b.count - 4) where b[k] == 0 && b[k + 1] == 0 && b[k + 2] == 0 && b[k + 3] == 1 {
                nalTypes.insert(b[k + 4] & 0x1F)
            }
            video.append(f.payload)
        }
        save(video, "flux.h264")
        XCTAssertTrue(sawConfig, "SPS/PPS jamais envoyés")
        XCTAssertTrue(sawKey, "aucune image clé (\(frames) images, types NAL \(nalTypes.sorted()))")
        XCTAssertGreaterThanOrEqual(frames, 20, "cadence trop basse : \(frames) images en 3 s")
        XCTAssertTrue(app.buttons["Arrêter le direct"].exists)
        shot("3-en-direct")

        // Tally « à l'antenne ».
        studio.send(.tally, Data([UInt8(TallyState.bitProgram)]))
        XCTAssertTrue(app.staticTexts["À L'ANTENNE"].waitForExistence(timeout: 5))
        shot("4-antenne")

        // Consigne urgente de la régie.
        studio.send(.cue, Data([1]) + Data("Plan large".utf8))
        XCTAssertTrue(app.staticTexts["Plan large"].waitForExistence(timeout: 5))
        shot("5-consigne")

        // Pilotage : la caméra renvoie l'état réellement appliqué (écho CONTROL).
        var cmd = CameraCommand()
        cmd.zoom = 2
        studio.send(.control, cmd.encodePayload())
        let echo = try studio.next(.control)
        XCTAssertNotNil(CameraCommand.decode(echo.payload).zoom, "écho CONTROL sans état de zoom")

        // Réponse rapide du vidéaste, puis accusé « vu » de la régie.
        app.buttons["Compris"].tap()
        let reply = try studio.next(.reply)
        XCTAssertEqual(reply.payload.first, 0)
        XCTAssertEqual(String(decoding: reply.payload.dropFirst(), as: UTF8.self), "Compris")
        studio.send(.seen, Data())
        XCTAssertTrue(app.staticTexts["Vu par la régie"].waitForExistence(timeout: 5))
        shot("6-vu-par-la-regie")

        XCTAssertTrue(studio.received(.stats), "télémétrie batterie/thermique jamais reçue")

        app.buttons["Arrêter le direct"].tap()
        XCTAssertTrue(app.buttons["Passer en direct"].waitForExistence(timeout: 5))
    }

    // MARK: - Pièces jointes

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        save(png, "\(name).png")
    }

    private func save(_ data: Data, _ name: String) {
        let a = XCTAttachment(data: data, uniformTypeIdentifier: name.hasSuffix(".png") ? "public.png" : "public.data")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let outDir { try? data.write(to: outDir.appendingPathComponent(name)) }
    }

    private func u32(_ d: Data, _ o: Int) -> Int {
        let b = [UInt8](d)
        return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }
}

// MARK: - VYRA Studio simulé (client TCP bloquant, lit et écrit des trames UNDI)

struct E2EError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

final class StudioMock {
    struct Frame { let type: UInt8; let flags: UInt16; let payload: Data }

    private let fd: Int32
    private var buf = [UInt8]()
    private var seenTypes = Set<UInt8>()
    private var sequence: UInt32 = 0

    private init(fd: Int32) { self.fd = fd }

    /// Se connecte à l'app (qui écoute en mode câble), en réessayant jusqu'à `timeout`.
    static func connect(port: UInt16, timeout: TimeInterval) throws -> StudioMock {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            } == 0
            if ok {
                var tv = timeval(tv_sec: 10, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                return StudioMock(fd: fd)
            }
            Darwin.close(fd)
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        throw E2EError("l'app n'écoute pas sur 127.0.0.1:\(port) (mode câble USB)")
    }

    /// Prochaine trame du type voulu ; les autres sont lues et notées (voir `received`).
    func next(_ type: FrameType) throws -> Frame {
        while true {
            let f = try readFrame()
            seenTypes.insert(f.type)
            if f.type == type.rawValue { return f }
        }
    }

    func received(_ type: FrameType) -> Bool { seenTypes.contains(type.rawValue) }

    func send(_ type: FrameType, _ payload: Data) {
        var frame = UndiProtocol.header(type: type, flags: 0, length: payload.count, ptsUs: 0, sequence: sequence)
        sequence &+= 1
        frame.append(payload)
        let bytes = [UInt8](frame)
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { return }
            off += n
        }
    }

    func close() { Darwin.close(fd) }

    private func readFrame() throws -> Frame {
        try fill(UndiProtocol.headerSize)
        let magic = UInt32(buf[0]) | UInt32(buf[1]) << 8 | UInt32(buf[2]) << 16 | UInt32(buf[3]) << 24
        guard magic == UndiProtocol.magic else { throw E2EError("MAGIC UNDI invalide") }
        let length = Int(UInt32(buf[8]) | UInt32(buf[9]) << 8 | UInt32(buf[10]) << 16 | UInt32(buf[11]) << 24)
        guard length <= UndiProtocol.maxPayloadSize else { throw E2EError("trame trop grande : \(length)") }
        try fill(UndiProtocol.headerSize + length)
        let frame = Frame(type: buf[5], flags: UInt16(buf[6]) | UInt16(buf[7]) << 8,
                          payload: Data(buf[UndiProtocol.headerSize..<(UndiProtocol.headerSize + length)]))
        buf.removeFirst(UndiProtocol.headerSize + length)
        return frame
    }

    private func fill(_ count: Int) throws {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while buf.count < count {
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { throw E2EError("connexion fermée ou muette (recv=\(n))") }
            buf.append(contentsOf: chunk[0..<n])
        }
    }
}
