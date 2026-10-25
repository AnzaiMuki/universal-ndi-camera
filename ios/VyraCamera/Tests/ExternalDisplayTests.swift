import XCTest
import AVFoundation
@testable import VyraCamera

// Sortie HDMI : les images caméra n'atteignent l'écran externe qu'en « Caméra seule », et une vraie
// image (mire du simulateur) y passe sans erreur. La scène d'écran externe elle-même ne se crée que
// sur un appareil branché.
final class ExternalDisplayTests: XCTestCase {

    @MainActor
    func testFramesReachExternalScreenOnlyInCleanMode() throws {
        let ext = ExternalDisplay.shared
        let capture = CameraCapture()
        let layer = AVSampleBufferDisplayLayer()
        ext.capture = capture
        ext.clean = true

        ext.attach(layer)
        XCTAssertTrue(ext.connected)
        XCTAssertTrue(capture.hasExternalSink)

        let sample = try XCTUnwrap(SimulatorCamera.frame(index: 0))
        capture.deliver(sample)
        XCTAssertNotEqual(layer.status, .failed)

        ext.clean = false   // « Copie d'écran » : plus rien n'est envoyé à l'écran externe
        XCTAssertFalse(capture.hasExternalSink)

        ext.clean = true
        ext.attach(nil)     // écran débranché
        XCTAssertFalse(ext.connected)
        XCTAssertFalse(capture.hasExternalSink)
    }
}
