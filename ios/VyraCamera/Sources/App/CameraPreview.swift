import SwiftUI
import AVFoundation
import CoreImage

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
        // Le simulateur n'a pas de caméra : on montre la mire de synthèse que reçoit l'encodeur
        // (une image sur trois, convertie en image fixe : suffisant pour un aperçu de test).
        let v = UIImageView()
        v.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
        v.clipsToBounds = true
        let ci = CIContext()
        let convert = DispatchQueue(label: "com.ndicam.simpreview", qos: .utility)
        var n = 0, busy = false   // `busy` : simple indicateur (au pire une image de plus sautée)
        capture.setSink("preview") { [weak v] sample in
            n += 1
            guard n % 3 == 0, !busy, let pixel = CMSampleBufferGetImageBuffer(sample) else { return }
            busy = true
            convert.async {
                let rect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
                let cg = ci.createCGImage(CIImage(cvPixelBuffer: pixel), from: rect)
                DispatchQueue.main.async {
                    if let cg { v?.image = UIImage(cgImage: cg) }
                    busy = false
                }
            }
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
        } else if let v = uiView as? UIImageView {
            v.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
