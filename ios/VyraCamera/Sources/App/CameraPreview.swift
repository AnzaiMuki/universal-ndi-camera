import SwiftUI
import AVFoundation

/// Accès à la couche d'aperçu pour convertir un point touché en coordonnées capteur.
final class PreviewHandle {
    fileprivate weak var layer: AVCaptureVideoPreviewLayer?

    /// Point de la vue → point d'intérêt capteur (0…1). Sans couche (simulateur), fraction de la vue.
    func devicePoint(_ p: CGPoint, in size: CGSize) -> CGPoint {
        if let layer { return layer.captureDevicePointConverted(fromLayerPoint: p) }
        return CGPoint(x: p.x / max(size.width, 1), y: p.y / max(size.height, 1))
    }
}

// Aperçu caméra : AVCaptureVideoPreviewLayer dans SwiftUI. `fill` = plein écran (aspect fill),
// sinon l'image entière (la zone est déjà bornée au 16:9 par l'écran).
struct CameraPreview: UIViewRepresentable {
    let capture: CameraCapture
    let handle: PreviewHandle
    let fill: Bool

    func makeUIView(context: Context) -> UIView {
        #if targetEnvironment(simulator)
        // Le simulateur n'a pas de caméra : on montre la mire de synthèse que reçoit l'encodeur.
        let v = SampleView()
        let display = v.display   // couche saisie ici : la vue n'est pas touchée hors du fil principal
        capture.setSink("preview") { [weak display] sample in
            guard let display else { return }
            if display.status == .failed { display.flush() }
            ExternalDisplay.markDisplayImmediately(sample)
            display.enqueue(sample)
        }
        return v
        #else
        let v = PreviewView()
        v.videoPreviewLayer.session = capture.session
        v.videoPreviewLayer.connection?.videoOrientation = .landscapeRight
        handle.layer = v.videoPreviewLayer
        return v
        #endif
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        if let v = uiView as? PreviewView {
            v.videoPreviewLayer.videoGravity = gravity
            if v.videoPreviewLayer.connection?.videoOrientation != .landscapeRight {
                v.videoPreviewLayer.connection?.videoOrientation = .landscapeRight
            }
        } else if let v = uiView as? SampleView {
            v.display.videoGravity = gravity
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class SampleView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var display: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }
}
