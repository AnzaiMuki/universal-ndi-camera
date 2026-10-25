import Foundation
import AVFoundation
import QuartzCore

// Capture vidéo de la caméra arrière (AVCaptureSession) + pilotage pro (zoom, torche, exposition, mise
// au point, balance des blancs, cadence, résolution, stabilisation), depuis l'écran ou depuis la régie.
// Les réglages sont BORNÉS aux capacités réelles du capteur, puis relus pour l'écho honnête vers le pont.
final class CameraCapture: NSObject {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.ndicam.capture")
    private var configured = false
    private(set) var device: AVCaptureDevice?

    // Appelée pour chaque image capturée (sur `queue`) : l'encodeur.
    var onSample: ((CMSampleBuffer) -> Void)?

    // Autres consommateurs des images brutes (sortie HDMI, aperçu du simulateur), par clé.
    // Posés depuis le thread principal, lus sur `queue` : protégés par un verrou.
    private let lock = NSLock()
    private var sinks: [String: (CMSampleBuffer) -> Void] = [:]

    // Analyse d'exposition (histogramme, zebras, peaking) : seulement si un outil la demande.
    private var analysisOn = false
    private var zebraLuma: Int?
    private var peaking = false
    private var lastAnalysis: CFTimeInterval = 0
    private static let analysisInterval: CFTimeInterval = 0.14
    var onAnalysis: ((ExposureAnalysis) -> Void)?   // appelée sur `queue`

    #if targetEnvironment(simulator)
    private let simulatorCamera = SimulatorCamera()   // mire de remplacement (le simulateur n'a pas de caméra)
    #endif

    static var isAuthorized: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        #endif
    }

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        #if targetEnvironment(simulator)
        done(true)   // mire de synthèse : aucune autorisation caméra à demander
        #else
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
        #endif
    }

    // MARK: - Consommateurs d'images

    func setSink(_ key: String, _ sink: ((CMSampleBuffer) -> Void)?) {
        lock.lock(); sinks[key] = sink; lock.unlock()
    }

    func hasSink(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sinks[key] != nil
    }

    func setAnalysis(enabled: Bool, zebraLuma: Int?, peaking: Bool) {
        lock.lock()
        analysisOn = enabled
        self.zebraLuma = enabled ? zebraLuma : nil
        self.peaking = enabled && peaking
        lock.unlock()
    }

    /// Distribue une image à l'encodeur, aux autres consommateurs et à l'analyse (sur `queue`).
    func deliver(_ sample: CMSampleBuffer) {
        onSample?(sample)
        lock.lock()
        let others = Array(sinks.values)
        let analyse = analysisOn, z = zebraLuma, p = peaking
        lock.unlock()
        others.forEach { $0(sample) }

        guard analyse, let pixel = CMSampleBufferGetImageBuffer(sample) else { return }
        let now = CACurrentMediaTime()
        guard now - lastAnalysis >= Self.analysisInterval else { return }
        lastAnalysis = now
        onAnalysis?(ExposureAnalysis.of(pixel, zebraLuma: z, peaking: p))
    }

    // MARK: - Session

    /// Configure la session sur la caméra arrière au format voulu. Idempotent.
    func configure(width: Int, height: Int, fps: Int) {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
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
        session.commitConfiguration()
        _ = setFormat(width: width, height: height, fps: fps)
        setStabilization(.off)   // défaut Android : trépied, pas de recadrage ni de latence EIS
    }

    func start() {
        #if targetEnvironment(simulator)
        simulatorCamera.start(on: queue) { [weak self] sample in self?.deliver(sample) }
        #endif
        guard !session.isRunning else { return }
        queue.async { [weak self] in self?.session.startRunning() }
    }

    func stop() {
        #if targetEnvironment(simulator)
        simulatorCamera.stop()
        #endif
        guard session.isRunning else { return }
        queue.async { [weak self] in self?.session.stopRunning() }
    }

    // MARK: - Format (résolution + cadence)

    private func formats(width: Int, height: Int) -> [AVCaptureDevice.Format] {
        (device?.formats ?? []).filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return Int(d.width) == width && Int(d.height) == height
        }
    }

    private func format(width: Int, height: Int, fps: Int) -> AVCaptureDevice.Format? {
        formats(width: width, height: height).first { f in
            f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(fps) && Double(fps) <= $0.maxFrameRate }
        }
    }

    /// Choisit le format capteur exact et fixe la cadence. Faux si l'appareil ne le sait pas.
    @discardableResult
    func setFormat(width: Int, height: Int, fps: Int) -> Bool {
        guard let device, let f = format(width: width, height: height, fps: fps) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        do {
            try device.lockForConfiguration()
            device.activeFormat = f
            let d = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = d
            device.activeVideoMaxFrameDuration = d
            device.unlockForConfiguration()
        } catch {}
        if let conn = output.connection(with: .video), conn.isVideoOrientationSupported {
            conn.videoOrientation = .landscapeRight
        }
        session.commitConfiguration()
        return true
    }

    /// Résolutions que cet appareil sait produire à cette cadence (sinon 720p par défaut).
    func supportedFormats(fps: Int) -> [VideoFormat] {
        let list = VideoFormat.candidates.filter { format(width: $0.width, height: $0.height, fps: fps) != nil }
        return list.isEmpty ? [.p720] : list
    }

    // MARK: - Capacités

    func capabilities(height: Int) -> CameraCapabilities {
        var caps = CameraCapabilities()
        guard let d = device else { return caps }
        let f = d.activeFormat
        caps.maxZoom = Float(min(d.maxAvailableVideoZoomFactor, 16))
        caps.isoRange = Int(f.minISO.rounded(.up))...Int(f.maxISO)
        let minNs = Int64(CMTimeGetSeconds(f.minExposureDuration) * 1e9)
        let maxNs = Int64(CMTimeGetSeconds(f.maxExposureDuration) * 1e9)
        if minNs > 0, maxNs > minNs { caps.exposureTimeRange = minNs...maxNs }
        let step = caps.aeCompStep
        let aeLo = Int((d.minExposureTargetBias / step).rounded(.up)), aeHi = Int((d.maxExposureTargetBias / step).rounded(.down))
        if aeLo <= aeHi { caps.aeCompRange = aeLo...aeHi }
        caps.manualWhiteBalance = d.isWhiteBalanceModeSupported(.locked)
        caps.supportsManualFocus = d.isLockingFocusWithCustomLensPositionSupported
        caps.hasFlash = d.hasTorch
        caps.hasElectronicStabilization = f.isVideoStabilizationModeSupported(.standard)
        let width = VideoFormat.candidates.first { $0.height == height }?.width ?? 1280
        caps.constantFps = [24, 25, 30, 50, 60].filter { format(width: width, height: height, fps: $0) != nil }
        return caps
    }

    // MARK: - Pilotage (borné aux capacités du capteur)

    private func lock(_ body: (AVCaptureDevice) -> Void) {
        guard let d = device else { return }
        do { try d.lockForConfiguration(); body(d); d.unlockForConfiguration() } catch { /* capteur occupé : on ignore */ }
    }

    /// Applique les réglages qui ont changé par rapport à `old` (le zoom est piloté à part).
    func apply(_ c: CameraControls, old: CameraControls?, caps: CameraCapabilities) {
        if old == nil || c.torch != old?.torch { setTorch(c.torch) }
        if old == nil || c.autoExposure != old?.autoExposure || c.iso != old?.iso
            || c.exposureTimeNs != old?.exposureTimeNs || c.aeCompensation != old?.aeCompensation {
            applyExposure(c, step: caps.aeCompStep)
        }
        if old == nil || c.wbManual != old?.wbManual || c.wbKelvin != old?.wbKelvin {
            applyWhiteBalance(manual: c.wbManual, kelvin: c.wbKelvin)
        }
        if old == nil || c.autoFocus != old?.autoFocus || c.focusPosition != old?.focusPosition {
            applyFocus(auto: c.autoFocus, position: c.focusPosition)
        }
        if old == nil || c.stabilization != old?.stabilization { setStabilization(c.stabilization) }
    }

    /// Zoom immédiat (pincement : le doigt prime sur une transition en cours).
    func setZoom(_ factor: Float) {
        lock { d in
            if d.isRampingVideoZoom { d.cancelVideoZoomRamp() }
            d.videoZoomFactor = CGFloat(factor).clamped(1, d.maxAvailableVideoZoomFactor)
        }
    }

    /// Transition de zoom : progression géométrique (l'œil perçoit le zoom en rapports), ~0,42 s.
    func zoomTo(_ factor: Float) {
        lock { d in
            let start = max(d.videoZoomFactor, 1)
            let end = CGFloat(factor).clamped(1, d.maxAvailableVideoZoomFactor)
            let rate = Float(abs(log2(end / start)) / 0.42)
            if rate < 0.05 { d.videoZoomFactor = end } else { d.ramp(toVideoZoomFactor: end, withRate: rate) }
        }
    }

    private func setTorch(_ on: Bool) {
        lock { d in
            guard d.hasTorch, d.isTorchModeSupported(on ? .on : .off) else { return }
            d.torchMode = on ? .on : .off
        }
    }

    private func applyExposure(_ c: CameraControls, step: Float) {
        lock { d in
            if c.autoExposure {
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                let bias = (Float(c.aeCompensation) * step).clamped(d.minExposureTargetBias, d.maxExposureTargetBias)
                d.setExposureTargetBias(bias, completionHandler: nil)
            } else if d.isExposureModeSupported(.custom) {
                let fmt = d.activeFormat
                let rawDur = c.exposureTimeNs.map { CMTime(value: $0, timescale: 1_000_000_000) } ?? d.exposureDuration
                let dur = CMTimeClampToRange(rawDur, range: CMTimeRange(start: fmt.minExposureDuration,
                                                                        duration: CMTimeSubtract(fmt.maxExposureDuration, fmt.minExposureDuration)))
                let iso = (c.iso.map { Float($0) } ?? d.iso).clamped(fmt.minISO, fmt.maxISO)
                d.setExposureModeCustom(duration: dur, iso: iso, completionHandler: nil)
            }
        }
    }

    private func applyFocus(auto: Bool, position: Float) {
        lock { d in
            if auto {
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            } else if d.isLockingFocusWithCustomLensPositionSupported {
                d.setFocusModeLocked(lensPosition: position.clamped(0, 1), completionHandler: nil)
            }
        }
    }

    private func applyWhiteBalance(manual: Bool, kelvin: Int) {
        lock { d in
            if !manual {
                if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
            } else if d.isWhiteBalanceModeSupported(.locked) {
                let k = Float(kelvin).clamped(2300, 7500)
                var gains = d.deviceWhiteBalanceGains(for: .init(temperature: k, tint: 0))
                let maxG = d.maxWhiteBalanceGain
                gains.redGain = gains.redGain.clamped(1, maxG)
                gains.greenGain = gains.greenGain.clamped(1, maxG)
                gains.blueGain = gains.blueGain.clamped(1, maxG)
                d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            }
        }
    }

    private func setStabilization(_ mode: StabilizationMode) {
        guard let conn = output.connection(with: .video), conn.isVideoStabilizationSupported else { return }
        conn.preferredVideoStabilizationMode = mode == .electronic ? .standard : .off
    }

    /// Appui sur l'image : point + mesure d'exposition sur ce point (coordonnées capteur 0…1).
    func focusAndMeter(at point: CGPoint) {
        lock { d in
            if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.autoFocus) {
                d.focusPointOfInterest = point
                d.focusMode = .autoFocus
            }
            if d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.continuousAutoExposure),
               d.exposureMode != .custom {
                d.exposurePointOfInterest = point
                d.exposureMode = .continuousAutoExposure
            }
        }
    }

    /// Relâche le point touché : retour au suivi continu, mesure recentrée.
    func clearTapFocus() {
        lock { d in
            let center = CGPoint(x: 0.5, y: 0.5)
            if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = center }
            if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            if d.isExposurePointOfInterestSupported, d.exposureMode != .custom { d.exposurePointOfInterest = center }
        }
    }

    // MARK: - Relecture pour l'écho honnête vers le pont

    var currentZoom: Float { Float(device?.videoZoomFactor ?? 1) }
    var torchOn: Bool { device?.torchMode == .on }
    var isExposureAuto: Bool { device.map { $0.exposureMode != .custom } ?? true }
    var currentISO: Int? { device.map { Int($0.iso) } }
    var currentExposureNs: Int64? {
        guard let d = device else { return nil }
        let s = CMTimeGetSeconds(d.exposureDuration)
        return s.isFinite && s > 0 ? Int64(s * 1_000_000_000) : nil
    }
    var isFocusAuto: Bool { device?.focusMode != .locked }
    var isWhiteBalanceManual: Bool { device?.whiteBalanceMode == .locked }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        deliver(sampleBuffer)
    }
}

// Bornage générique (évite de répéter min/max partout).
extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { Swift.min(Swift.max(self, lo), hi) }
}
