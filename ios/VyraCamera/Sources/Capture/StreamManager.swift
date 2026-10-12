import Foundation
import AVFoundation
import Network
import UIKit

// Orchestrateur : relie capture caméra, encodeur H.264, audio et client réseau UNDI, et gère le
// CANAL RETOUR (tally, consignes CUE, commandes CONTROL) — parité avec l'app Android.
// Enchaînement du direct : connexion TCP → HELLO → STREAM_CONFIG → SPS/PPS → VIDEO (+ AUDIO + STATS).
@MainActor
final class StreamManager: ObservableObject {
    enum State: Equatable { case idle, connecting, streaming, failed(String) }

    // Drapeau de pause lu sur la file de capture (hors thread principal) : type référence partagé.
    private final class Flags { var paused = false }

    @Published private(set) var state: State = .idle
    @Published private(set) var status: String = "Prêt"
    @Published var deviceName: String = UIDevice.current.name
    @Published var micEnabled = true

    // Canal retour, pour le HUD.
    @Published private(set) var tally: TallyState = .off
    @Published private(set) var cue: Cue?
    @Published private(set) var replyStatus: String?
    @Published private(set) var replySeen = false
    // Télémétrie affichée.
    @Published private(set) var battery = -1
    @Published private(set) var charging = false
    @Published private(set) var thermal: ThermalLevel = .unknown

    // Paramètres de flux (modifiables à distance : débit, résolution).
    private var streamWidth = 1280, streamHeight = 720
    private let fps = 30
    private var currentBitrate = 4_000_000
    private var adaptiveBitrate = true
    private var audioMuted = false
    private var micGainDb = 0

    let capture = CameraCapture()
    private var encoder: H264Encoder?
    private let client = UndiClient()
    private let audio = AudioCapture()
    private let flags = Flags()

    private var previewStarted = false
    private var lastConnect: ((@escaping (Bool) -> Void) -> Void)?
    private var statsTimer: Timer?
    private var cueToken = 0
    private var replyToken = 0

    init() {
        client.onStatus = { [weak self] s in Task { @MainActor in self?.status = s } }
        client.onTally = { [weak self] t in Task { @MainActor in self?.tally = t } }
        client.onCue = { [weak self] c in Task { @MainActor in self?.showCue(c) } }
        client.onSeen = { [weak self] in Task { @MainActor in self?.markReplySeen() } }
        client.onCommand = { [weak self] cmd in Task { @MainActor in self?.apply(cmd) } }
    }

    var isStreaming: Bool { if case .streaming = state { return true }; return false }

    // MARK: - Aperçu caméra (avant le direct)

    func startPreview() {
        guard !previewStarted else { return }
        CameraCapture.requestAccess { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else { self.status = "Accès caméra refusé"; return }
                self.previewStarted = true
                self.capture.configure(height: self.streamHeight)
                self.capture.start()
            }
        }
    }

    // MARK: - Démarrage

    func startManual(host: String, port: UInt16) {
        beginConnect { completion in self.client.connect(host: host, port: port, completion: completion) }
    }

    func startDiscovered(_ found: Discovery.Found) {
        beginConnect { completion in self.client.connect(endpoint: found.endpoint, label: found.name, completion: completion) }
    }

    private func beginConnect(_ connect: @escaping (@escaping (Bool) -> Void) -> Void) {
        guard state == .idle else { return }
        lastConnect = connect
        state = .connecting
        status = "Connexion…"
        CameraCapture.requestAccess { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else { self.fail("Accès caméra refusé"); return }
                connect { ok in
                    Task { @MainActor in ok ? self.onConnected() : self.fail("Connexion impossible") }
                }
            }
        }
    }

    private func onConnected() {
        let client = self.client
        flags.paused = false
        client.sendHello(name: deviceName)
        client.sendStreamConfig(StreamConfig(codec: .h264, width: streamWidth, height: streamHeight, fps: fps, bitrateBps: currentBitrate))

        let enc = H264Encoder(width: streamWidth, height: streamHeight, fps: fps)
        enc.onConfig = { cfg in client.sendVideo(cfg, ptsUs: 0, keyframe: false, config: true) }
        enc.onFrame = { data, pts, key in client.sendVideo(data, ptsUs: pts, keyframe: key, config: false) }
        enc.start(bitrateBps: currentBitrate)
        encoder = enc

        // Boucle vidéo (file de capture, hors thread principal) ; `flags` partagé pour la pause.
        let flags = self.flags
        capture.onSample = { sample in
            if flags.paused { return }
            guard let pixel = CMSampleBufferGetImageBuffer(sample) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let ptsUs = Int64((CMTimeGetSeconds(pts) * 1_000_000).rounded())
            enc.encode(pixel, ptsUs: ptsUs)
        }

        if micEnabled && !audioMuted { startAudio() }

        startTelemetry()
        state = .streaming
        status = "En direct"
        echo()   // état initial vers le pont
    }

    private func startAudio() {
        let client = self.client
        audio.setGainDb(micGainDb)
        audio.onPCM = { pcm, sr, ch, pts in client.sendAudio(pcm, sampleRate: sr, channels: ch, ptsUs: pts) }
        audio.start()
    }

    // MARK: - Télémétrie (batterie / thermique), toutes les 5 s

    private func startTelemetry() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        statsTimer?.invalidate()
        reportStats()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reportStats() }
        }
    }

    private func reportStats() {
        let lvl = UIDevice.current.batteryLevel
        battery = lvl < 0 ? -1 : Int((lvl * 100).rounded())
        let st = UIDevice.current.batteryState
        charging = (st == .charging || st == .full)
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .warm
        case .serious: thermal = .hot
        case .critical: thermal = .critical
        @unknown default: thermal = .unknown
        }
        client.sendStats(DeviceStats(batteryPercent: battery, charging: charging, thermal: thermal))
    }

    // MARK: - Canal retour : CUE / REPLY

    private func showCue(_ c: Cue) {
        guard !c.text.isEmpty else { return }
        cue = c
        cueToken += 1
        let token = cueToken
        let delay = c.urgent ? 8.0 : 6.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.cueToken == token else { return }
            self.cue = nil
        }
    }

    func sendReply(_ text: String, alert: Bool = false) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        client.sendReply(Reply(text: t, alert: alert))
        replyStatus = t
        replySeen = false
        replyToken += 1
        let token = replyToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.replyToken == token else { return }
            self.replyStatus = nil
        }
    }

    private func markReplySeen() {
        guard replyStatus != nil, !replySeen else { return }
        replySeen = true
        replyToken += 1
        let token = replyToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.replyToken == token else { return }
            self.replyStatus = nil
        }
    }

    // MARK: - Application d'une consigne CONTROL (puis écho de l'état réel)

    private func apply(_ cmd: CameraCommand) {
        guard !cmd.isEmpty else { return }

        cmd.zoom.map { capture.setZoom($0) }
        cmd.torch.map { capture.setTorch($0) }
        cmd.paused.map { setPaused($0) }

        if let muted = cmd.audioMuted { setAudioMuted(muted) }
        if let gain = cmd.micGainDb { micGainDb = gain; audio.setGainDb(gain) }

        cmd.adaptiveBitrate.map { adaptiveBitrate = $0 }
        if let kbps = cmd.bitrateKbps {
            currentBitrate = kbps * 1000
            if !adaptiveBitrate { encoder?.setBitrate(currentBitrate) }
        }
        if let h = cmd.resolutionHeight { streamHeight = h; streamWidth = widthForHeight(h) }

        capture.applyExposure(auto: cmd.autoExposure, iso: cmd.iso, exposureNs: cmd.exposureTimeNs, bias: cmd.aeCompensation)
        capture.applyFocus(auto: cmd.autoFocus, distance: cmd.focusDistance)
        capture.applyWhiteBalance(manual: cmd.wbManual, kelvin: cmd.wbKelvin)

        if cmd.restartStream == true { restart() } else { echo() }
    }

    private func widthForHeight(_ h: Int) -> Int { h <= 720 ? 1280 : (h >= 2160 ? 3840 : 1920) }

    /// Coupe/relance l'envoi vidéo SANS fermer la connexion (le pont garde son canal de commande).
    private func setPaused(_ paused: Bool) {
        flags.paused = paused
        if !paused { encoder?.requestKeyframe() }   // sans image clé, le pont ne redécode pas
    }

    /// Coupe/rend le son : on LIBÈRE réellement le micro (indicateur système éteint), comme Android.
    private func setAudioMuted(_ muted: Bool) {
        audioMuted = muted
        if muted { audio.stop() }
        else if micEnabled && isStreaming { startAudio() }
    }

    /// Reconnecte le lien pour appliquer une nouvelle résolution en direct (comme Android).
    private func restart() {
        guard let connect = lastConnect else { echo(); return }
        stop()
        capture.setResolution(height: streamHeight)
        beginConnect(connect)
    }

    private func echo() {
        client.sendControl(CameraCommand(
            autoExposure: capture.isExposureAuto,
            iso: capture.currentISO,
            exposureTimeNs: capture.currentExposureNs,
            aeCompensation: nil,
            awbMode: nil,
            wbManual: capture.isWhiteBalanceManual,
            wbKelvin: nil,
            autoFocus: capture.isFocusAuto,
            focusDistance: nil,
            zoom: capture.currentZoom,
            paused: flags.paused,
            torch: capture.torchOn,
            audioMuted: audioMuted,
            micGainDb: micGainDb,
            adaptiveBitrate: adaptiveBitrate,
            bitrateKbps: currentBitrate / 1000,
            resolutionHeight: streamHeight,
            restartStream: nil))
    }

    // MARK: - Arrêt / erreur

    func stop() {
        statsTimer?.invalidate(); statsTimer = nil
        capture.onSample = nil
        audio.stop()
        encoder?.stop()
        encoder = nil
        client.close()
        tally = .off
        cue = nil
        state = .idle
        status = "Prêt"
    }

    func teardown() {
        stop()
        capture.stop()
        previewStarted = false
    }

    private func fail(_ message: String) {
        statsTimer?.invalidate(); statsTimer = nil
        capture.onSample = nil
        audio.stop()
        encoder?.stop(); encoder = nil
        client.close()
        state = .failed(message)
        status = message
    }
}
