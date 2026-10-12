import Foundation
import AVFoundation

// Capture vidéo de la caméra arrière (AVCaptureSession) + pilotage (zoom, torche, exposition, mise
// au point, balance des blancs, résolution), piloté à distance depuis la régie via les trames CONTROL.
// Les réglages sont BORNÉS aux capacités réelles du capteur, puis relus pour l'écho honnête vers le pont.
final class CameraCapture: NSObject {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.ndicam.capture")
    private var configured = false
    private(set) var device: AVCaptureDevice?

    // Appelée pour chaque image capturée (sur `queue`).
    var onSample: ((CMSampleBuffer) -> Void)?

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    /// Configure la session sur la caméra arrière à la résolution voulue. Idempotent.
    func configure(height: Int = 720) {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = preset(for: height)

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            self.device = device
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

    private func preset(for height: Int) -> AVCaptureSession.Preset {
        let wanted: AVCaptureSession.Preset = height >= 2160 ? .hd4K3840x2160 : (height >= 1080 ? .hd1920x1080 : .hd1280x720)
        return session.canSetSessionPreset(wanted) ? wanted : .hd1280x720
    }

    // MARK: - Pilotage (borné aux capacités du capteur)

    private func lock(_ body: (AVCaptureDevice) -> Void) {
        guard let d = device else { return }
        do { try d.lockForConfiguration(); body(d); d.unlockForConfiguration() } catch { /* capteur occupé : on ignore */ }
    }

    /// Change la résolution (720 / 1080 / 2160). À faire hors diffusion (voir StreamManager.restart).
    func setResolution(height: Int) {
        session.beginConfiguration()
        session.sessionPreset = preset(for: height)
        session.commitConfiguration()
    }

    /// Zoom animé (comme un pincement) : l'œil perçoit le zoom en rapports, une transition douce évite le saut.
    func setZoom(_ factor: Float) {
        lock { d in
            let clamped = CGFloat(max(1, factor)).clamped(1, d.maxAvailableVideoZoomFactor)
            d.ramp(toVideoZoomFactor: clamped, withRate: 3.0)
        }
    }

    func setTorch(_ on: Bool) {
        lock { d in
            guard d.hasTorch, d.isTorchModeSupported(on ? .on : .off) else { return }
            d.torchMode = on ? .on : .off
        }
    }

    /// Exposition : auto (continue) OU manuelle (ISO + durée), + compensation EV (en mode auto).
    func applyExposure(auto: Bool?, iso: Int?, exposureNs: Int64?, bias: Int?) {
        lock { d in
            if let bias {
                let b = Float(bias).clamped(d.minExposureTargetBias, d.maxExposureTargetBias)
                d.setExposureTargetBias(b, completionHandler: nil)
            }
            if auto == true {
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            } else if (auto == false || iso != nil || exposureNs != nil), d.isExposureModeSupported(.custom) {
                let fmt = d.activeFormat
                let rawDur = exposureNs.map { CMTime(value: $0, timescale: 1_000_000_000) } ?? d.exposureDuration
                let dur = CMTimeClampToRange(rawDur, range: CMTimeRange(start: fmt.minExposureDuration,
                                                                        duration: CMTimeSubtract(fmt.maxExposureDuration, fmt.minExposureDuration)))
                let isoVal = (iso.map { Float($0) } ?? d.iso).clamped(fmt.minISO, fmt.maxISO)
                d.setExposureModeCustom(duration: dur, iso: isoVal, completionHandler: nil)
            }
        }
    }

    /// Mise au point : auto (continue) OU verrouillée à une position d'objectif (0..1).
    func applyFocus(auto: Bool?, distance: Float?) {
        lock { d in
            if auto == true {
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            } else if auto == false || distance != nil {
                if let distance, d.isLockingFocusWithCustomLensPositionSupported {
                    d.setFocusModeLockedWithLensPosition(distance.clamped(0, 1), completionHandler: nil)
                } else if d.isFocusModeSupported(.locked) {
                    d.focusMode = .locked
                }
            }
        }
    }

    /// Balance des blancs : auto (continue) OU verrouillée à une température (Kelvin).
    func applyWhiteBalance(manual: Bool?, kelvin: Int?) {
        lock { d in
            if manual == false {
                if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
            } else if (manual == true || kelvin != nil), d.isWhiteBalanceModeSupported(.locked) {
                let k = Float(kelvin ?? 5000).clamped(2300, 7500)
                var gains = d.deviceWhiteBalanceGains(for: .init(temperature: k, tint: 0))
                let maxG = d.maxWhiteBalanceGain
                gains.redGain = gains.redGain.clamped(1, maxG)
                gains.greenGain = gains.greenGain.clamped(1, maxG)
                gains.blueGain = gains.blueGain.clamped(1, maxG)
                d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            }
        }
    }

    // MARK: - Relecture pour l'écho honnête vers le pont

    var currentZoom: Float { Float(device?.videoZoomFactor ?? 1) }
    var torchOn: Bool { device?.torchMode == .on }
    var isExposureAuto: Bool { device?.exposureMode == .continuousAutoExposure }
    var currentISO: Int? { device.map { Int($0.iso) } }
    var currentExposureNs: Int64? {
        guard let d = device else { return nil }
        let s = CMTimeGetSeconds(d.exposureDuration)
        return s.isFinite && s > 0 ? Int64(s * 1_000_000_000) : nil
    }
    var isFocusAuto: Bool { device?.focusMode == .continuousAutoFocus }
    var isWhiteBalanceManual: Bool { device?.whiteBalanceMode == .locked }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onSample?(sampleBuffer)
    }
}

// Bornage générique (évite de répéter min/max partout).
private extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { Swift.min(Swift.max(self, lo), hi) }
}
