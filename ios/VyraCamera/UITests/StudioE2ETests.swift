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
        XCUIDevice.shared.orientation = .landscapeLeft   // paysage, encoche à gauche (comme l'Android)
        app = XCUIApplication()
        app.launchArguments = ["-vyra_mic", "NO"]          // pas de demande d'autorisation micro pendant le test
        app.launch()
    }

    func testUsbLiveSessionWithStudio() throws {
        // Lancement animé, puis conditions d'utilisation au premier lancement.
        let accept = app.buttons["J'accepte"]
        XCTAssertTrue(accept.waitForExistence(timeout: 10), "CLUF absent")
        shot("01-conditions")
        accept.tap()

        let live = app.buttons["live"]
        XCTAssertTrue(live.waitForExistence(timeout: 10), "viseur absent")
        sleep(1)
        shot("02-viseur")

        // Outils : exposition avec histogramme et zebras, puis repères avec niveau.
        app.buttons["tool-exposure"].tap()
        app.buttons["Histo."].tap()
        app.buttons["95%"].tap()
        sleep(1)
        shot("03-outil-exposition")
        app.buttons["tool-grid"].tap()
        app.buttons["Niveau"].tap()
        shot("04-outil-reperes")
        app.buttons["Niveau"].tap()
        app.buttons["tool-camera"].tap()

        // Réglages ▸ Réseau : câble USB.
        app.buttons["settings"].tap()
        XCTAssertTrue(app.staticTexts["Réglages"].waitForExistence(timeout: 5))
        app.buttons["USB (câble)"].tap()
        shot("05-reglages")
        app.buttons["Terminé"].tap()
        XCTAssertTrue(app.staticTexts["MODE CÂBLE USB"].waitForExistence(timeout: 5))

        // Bouton rouge : l'iPhone attend VYRA Studio par le câble.
        live.tap()
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

        // Vidéo : SPS/PPS, image clé, puis 45 images (le démarrage de l'encodeur peut prendre
        // plusieurs secondes dans le simulateur : on l'attend jusqu'à 20 s).
        var video = Data()
        var frames = 0, sawConfig = false, sawKey = false
        var nalTypes = Set<UInt8>()   // types NAL vus (5 = IDR, 1 = P, 7/8 = SPS/PPS) : diagnostic
        var firstFrameAt: Date?
        let deadline = Date().addingTimeInterval(20)
        while frames < 45, Date() < deadline {
            let f = try studio.next(.video)
            if f.flags & UndiProtocol.flagConfig != 0 { sawConfig = true } else {
                frames += 1
                if firstFrameAt == nil { firstFrameAt = Date() }
            }
            if f.flags & UndiProtocol.flagKeyframe != 0 { sawKey = true }
            let b = [UInt8](f.payload)
            for k in 0..<max(0, b.count - 4) where b[k] == 0 && b[k + 1] == 0 && b[k + 2] == 0 && b[k + 3] == 1 {
                nalTypes.insert(b[k + 4] & 0x1F)
            }
            video.append(f.payload)
        }
        let fps = firstFrameAt.map { Double(max(frames - 1, 0)) / max(Date().timeIntervalSince($0), 0.001) } ?? 0
        let report = "images=\(frames) cadence=\(String(format: "%.1f", fps)) i/s types_nal=\(nalTypes.sorted())\n"
        save(Data(report.utf8), "video.txt")
        save(video, "flux.h264")
        XCTAssertTrue(sawConfig, "SPS/PPS jamais envoyés")
        XCTAssertTrue(sawKey, "aucune image clé (\(frames) images, types NAL \(nalTypes.sorted()))")
        XCTAssertEqual(frames, 45, "flux interrompu : \(frames) images en 20 s")
        XCTAssertGreaterThanOrEqual(fps, 15, "cadence trop basse : \(fps) i/s")
        XCTAssertTrue(app.staticTexts["EN DIRECT · NDI"].waitForExistence(timeout: 5))
        shot("06-en-direct")

        // Tally « à l'antenne ».
        studio.send(.tally, Data([UInt8(TallyState.bitProgram)]))
        XCTAssertTrue(app.staticTexts["À L'ANTENNE"].waitForExistence(timeout: 5))
        shot("07-antenne")

        // Consigne urgente de la régie.
        studio.send(.cue, Data([1]) + Data("Plan large".utf8))
        XCTAssertTrue(app.staticTexts["PLAN LARGE"].waitForExistence(timeout: 5))
        shot("08-consigne")
        assertApart(app.staticTexts["PLAN LARGE"], app.staticTexts["EN DIRECT · NDI"])
        assertApart(app.staticTexts["PLAN LARGE"], app.staticTexts["WB"])

        // Pilotage : la caméra renvoie l'état réellement appliqué (écho CONTROL).
        var cmd = CameraCommand()
        cmd.zoom = 2
        studio.send(.control, cmd.encodePayload())
        let echo = try studio.next(.control)
        XCTAssertNotNil(CameraCommand.decode(echo.payload).zoom, "écho CONTROL sans état de zoom")

        // Messagerie : réponse rapide du vidéaste, puis accusé « vu » de la régie.
        app.buttons["messages"].tap()
        let compris = app.buttons["Compris ✓"]
        XCTAssertTrue(compris.waitForExistence(timeout: 5))
        shot("09-messagerie")
        for other in [app.staticTexts["AUDIO"], app.staticTexts["LUMINANCE"], app.staticTexts["PLAN LARGE"]] {
            assertApart(app.buttons["Prêt"], other)
            assertApart(app.buttons["Compris ✓"], other)
            assertApart(app.buttons["Envoyer"], other)
        }
        compris.tap()
        let reply = try studio.next(.reply)
        XCTAssertEqual(reply.payload.first, 0)
        XCTAssertEqual(String(decoding: reply.payload.dropFirst(), as: UTF8.self), "Compris ✓")
        studio.send(.seen, Data())
        XCTAssertTrue(app.staticTexts["Vu par la régie ✓✓"].waitForExistence(timeout: 5))
        shot("10-vu-par-la-regie")
        assertApart(app.staticTexts["Vu par la régie ✓✓"], app.staticTexts["À L'ANTENNE"])
        assertApart(app.staticTexts["Vu par la régie ✓✓"], app.staticTexts["AUDIO"])

        XCTAssertTrue(studio.received(.stats), "télémétrie batterie/thermique jamais reçue")
        XCTAssertFalse(app.staticTexts["00:00:00"].exists, "le timecode du direct n'avance pas")

        live.tap()
        XCTAssertTrue(app.staticTexts["MODE CÂBLE USB"].waitForExistence(timeout: 5))
    }

    // MARK: - Mise en page

    /// Deux éléments affichés ne doivent jamais se recouvrir (ergonomie : aucune pastille dans l'autre).
    private func assertApart(_ a: XCUIElement, _ b: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        guard a.exists, b.exists else { return }
        XCTAssertFalse(a.frame.intersects(b.frame),
                       "chevauchement : « \(a.label) » \(a.frame) / « \(b.label) » \(b.frame)", file: file, line: line)
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
