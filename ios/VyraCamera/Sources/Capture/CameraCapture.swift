import Foundation
import AVFoundation

// Capture vidéo de la caméra arrière (AVCaptureSession). Sort des CMSampleBuffer 1280×720 que
// l'orchestrateur transmet à l'encodeur H.264. Version minimale : caméra arrière, 720p30, pas d'audio.
final class CameraCapture: NSObject {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.ndicam.capture")
    private var configured = false

    // Appelée pour chaque image capturée (sur `queue`).
    var onSample: ((CMSampleBuffer) -> Void)?

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    /// Configure la session en 720p sur la caméra arrière. Idempotent.
    func configure() {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }

        if let conn = output.connection(with: .video) {
            if conn.isVideoOrientationSupported { conn.videoOrientation = .landscapeRight }
            if conn.isVideoStabilizationSupported { conn.preferredVideoStabilizationMode = .auto }
        }
        session.commitConfiguration()
    }

    func start() {
        guard !session.isRunning else { return }
        queue.async { [weak self] in self?.session.startRunning() }
    }

    func stop() {
        guard session.isRunning else { return }
        queue.async { [weak self] in self?.session.stopRunning() }
    }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onSample?(sampleBuffer)
    }
}
