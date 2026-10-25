import XCTest
@testable import VyraCamera

// Vérifie que la paquetisation/réassemblage SRT reconstruit EXACTEMENT les trames UNDI, y compris
// en cas de fragments réordonnés, et abandonne proprement une trame incomplète sans tout désynchroniser.
final class SrtFramingTests: XCTestCase {

    private func frame(_ payloadLen: Int, seq: UInt32) -> Data {
        let payload = Data((0..<payloadLen).map { UInt8($0 & 0xFF) })
        var f = UndiProtocol.header(type: .video, flags: 0, length: payloadLen, ptsUs: 1_000, sequence: seq)
        f.append(payload)
        return f
    }

    func testRoundTripSingleFragment() {
        let f = frame(10, seq: 0)
        var got: [Data] = []
        let r = SrtReassembler { got.append($0) }
        SrtPacket.packetize(f, frameId: 0).forEach { r.offer($0) }
        XCTAssertEqual(got, [f])
    }

    func testRoundTripMultiFragment() {
        let f = frame(3_000, seq: 0)               // 24+3000 = 3024 o → 3 fragments (max 1200)
        let pkts = SrtPacket.packetize(f, frameId: 0)
        XCTAssertEqual(pkts.count, 3)
        var got: [Data] = []
        let r = SrtReassembler { got.append($0) }
        pkts.forEach { r.offer($0) }
        XCTAssertEqual(got, [f])
    }

    func testReorderedFragments() {
        let f = frame(3_000, seq: 7)
        var got: [Data] = []
        let r = SrtReassembler { got.append($0) }
        SrtPacket.packetize(f, frameId: 0).reversed().forEach { r.offer($0) }
        XCTAssertEqual(got, [f])
    }

    func testDroppedFragmentIsAbandonedWindowAdvances() {
        let f0 = frame(3_000, seq: 0)   // multi-fragments
        let f1 = frame(10, seq: 1)
        var got: [Data] = []
        let r = SrtReassembler(window: 1) { got.append($0) }   // fenêtre serrée pour forcer l'avancée
        SrtPacket.packetize(f0, frameId: 0).dropFirst().forEach { r.offer($0) }   // f0 : 1 fragment manquant
        SrtPacket.packetize(f1, frameId: 1).forEach { r.offer($0) }               // force l'abandon de f0
        XCTAssertEqual(got, [f1])
        XCTAssertEqual(r.emitted, 1)
        XCTAssertEqual(r.dropped, 1)
    }
}
