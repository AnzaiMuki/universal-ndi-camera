import XCTest
@testable import VyraCamera

// Tests des formats FILAIRES UNDI : ils vérifient octet par octet que l'iPhone produit exactement
// ce que VYRA Studio (et l'app Android) attend. Purs et déterministes → exécutables gratuitement
// dans le CI sur simulateur, sans appareil ni caméra. C'est la vérification « de A à Z » du protocole.
final class UndiProtocolTests: XCTestCase {

    private func u16(_ d: Data, _ o: Int) -> Int { Int(d[o]) | (Int(d[o + 1]) << 8) }
    private func u32(_ d: Data, _ o: Int) -> Int { Int(d[o]) | (Int(d[o + 1]) << 8) | (Int(d[o + 2]) << 16) | (Int(d[o + 3]) << 24) }

    func testHeaderLayout() {
        let h = UndiProtocol.header(type: .video, flags: 0x0001, length: 100, ptsUs: 1_234_567, sequence: 42)
        XCTAssertEqual(h.count, 24)
        XCTAssertEqual(Array(h[0..<4]), [0x55, 0x4E, 0x44, 0x49])   // « UNDI » petit-boutiste
        XCTAssertEqual(h[4], 7)                                     // version
        XCTAssertEqual(h[5], FrameType.video.rawValue)             // type
        XCTAssertEqual(u16(h, 6), 0x0001)                          // flags (keyframe)
        XCTAssertEqual(u32(h, 8), 100)                             // length
        XCTAssertEqual(u32(h, 20), 42)                             // sequence (bits bas)
    }

    func testStreamConfigPayload() {
        let p = StreamConfig(codec: .h264, width: 1280, height: 720, fps: 30, bitrateBps: 4_000_000).encodePayload()
        XCTAssertEqual(p.count, 17)
        XCTAssertEqual(p[0], 0)                 // codec H264
        XCTAssertEqual(u32(p, 1), 1280)
        XCTAssertEqual(u32(p, 5), 720)
        XCTAssertEqual(u32(p, 9), 30)
        XCTAssertEqual(u32(p, 13), 4_000_000)
    }

    func testDeviceInfoSanitizesAndBounds() {
        XCTAssertEqual(String(decoding: DeviceInfo.encodePayload(name: "iPhone de Godwill"), as: UTF8.self), "iPhone de Godwill")
        let long = DeviceInfo.encodePayload(name: String(repeating: "a", count: 200))
        XCTAssertLessThanOrEqual(long.count, 64)
    }

    func testTallyDecode() {
        XCTAssertEqual(TallyState.decode(Data([0x01])), TallyState(program: true, preview: false))
        XCTAssertEqual(TallyState.decode(Data([0x02])), TallyState(program: false, preview: true))
        XCTAssertEqual(TallyState.decode(Data([0x03])), TallyState(program: true, preview: true))
    }

    func testCueDecode() {
        let c = Cue.decode(Data([1]) + Data("Resserre".utf8))
        XCTAssertTrue(c.urgent)
        XCTAssertEqual(c.text, "Resserre")
    }

    func testReplyEncode() {
        let p = Reply(text: "Prêt", alert: true).encodePayload()
        XCTAssertEqual(p[0], 1)
        XCTAssertEqual(String(decoding: p.dropFirst(), as: UTF8.self), "Prêt")
    }

    func testDeviceStatsPayload() {
        let p = DeviceStats(batteryPercent: 55, charging: true, thermal: .warm).encodePayload()
        XCTAssertEqual(Array(p), [55, 1, 2])
        // Batterie inconnue → 0xFF
        XCTAssertEqual(DeviceStats(batteryPercent: -1).encodePayload()[0], 0xFF)
    }

    func testCameraCommandRoundTrip() {
        let cmd = CameraCommand(iso: 400, zoom: 2.0, paused: false, torch: true, micGainDb: 6, bitrateKbps: 3500, resolutionHeight: 1080)
        let decoded = CameraCommand.decode(cmd.encodePayload())
        XCTAssertEqual(decoded.iso, 400)
        XCTAssertEqual(decoded.zoom, 2.0)
        XCTAssertEqual(decoded.paused, false)
        XCTAssertEqual(decoded.torch, true)
        XCTAssertEqual(decoded.micGainDb, 6)
        XCTAssertEqual(decoded.bitrateKbps, 3500)
        XCTAssertEqual(decoded.resolutionHeight, 1080)
        XCTAssertNil(decoded.awbMode)   // champ absent = inchangé
    }

    func testCameraCommandIgnoresPropertiesComment() {
        // java.util.Properties (côté pont) écrit une ligne de commentaire « #date » en tête.
        let payload = Data("#Mon Oct 13 00:00:00 GMT 2026\nzoom=3.0\ntorch=false\n".utf8)
        let cmd = CameraCommand.decode(payload)
        XCTAssertEqual(cmd.zoom, 3.0)
        XCTAssertEqual(cmd.torch, false)
    }
}
