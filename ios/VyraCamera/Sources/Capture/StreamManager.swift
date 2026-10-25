import Foundation
import AVFoundation
import Combine
import Network
import UIKit

/// Statut du dernier message envoyé à la régie (« envoyé » puis « Vu par la régie »).
struct ReplyStatus: Equatable {
    var text: String
    var seen = false
}

// Orchestrateur, pendant du StreamViewModel + CaptureController Android : relie capture caméra,
// encodeur H.264, audio et client réseau UNDI, porte l'état affiché par l'écran et gère le CANAL
// RETOUR (tally, consignes CUE, commandes CONTROL).
// Enchaînement du direct : connexion → HELLO → STREAM_CONFIG → SPS/PPS → VIDEO (+ AUDIO + STATS).
@MainActor
final class StreamManager: ObservableObject {
    enum State: Equatable { case idle, connecting, streaming, failed(String) }
    enum Transport: String { case tcp, srt }   // Wi-Fi : TCP (défaut, fluide) ou SRT (anti-perte)
    enum Link: String { case wifi, usb }       // réseau (défaut) ou câble USB (toujours en TCP)

    // Drapeau de pause lu sur la file de capture (hors thread principal) : type référence partagé.
    private final class Flags { var paused = false }

    @Published private(set) var state: State = .idle
    @Published private(set) var status: String = "Prêt"
    @Published private(set) var previewReady = false
    /// Début du direct en cours : base du timecode affiché.
    @Published private(set) var liveSince: Date?
    @Published var deviceName: String = UIDevice.current.name

    // Connexion, mémorisée entre les sessions (comme ConnectionPrefs côté Android).
    @Published var link: Link = Link(rawValue: UserDefaults.standard.string(forKey: "vyra_link") ?? "") ?? .wifi {
        didSet { UserDefaults.standard.set(link.rawValue, forKey: "vyra_link") }
    }
    @Published var transport: Transport = Transport(rawValue: UserDefaults.standard.string(forKey: "vyra_wifi_transport") ?? "") ?? .tcp {
        didSet { UserDefaults.standard.set(transport.rawValue, forKey: "vyra_wifi_transport") }
    }
    /// Pont trouvé sur le Wi-Fi (Bonjour) ou relié par câble.
    @Published private(set) var bridgeName: String?
    private var discovered: Discovery.Found?

    // Canal retour.
    @Published private(set) var tally: TallyState = .off
    @Published private(set) var cue: Cue?
    @Published private(set) var replyStatus: ReplyStatus?
    @Published private(set) var paused = false

    // Télémétrie.
    @Published private(set) var battery = -1
    @Published private(set) var charging = false
    @Published private(set) var thermal: ThermalLevel = .unknown
    @Published private(set) var throughputBps = 0

    // Caméra.
    @Published private(set) var controls = CameraControls()
    @Published private(set) var caps = CameraCapabilities()
    @Published private(set) var analysis = ExposureAnalysis.empty
    @Published private(set) var fps = 30
    @Published private(set) var format = VideoFormat.p720
    @Published private(set) var adaptiveBitrate = true

    // Audio.
    @Published private(set) var micEnabled = UserDefaults.standard.object(forKey: "vyra_mic") == nil ? true : UserDefaults.standard.bool(forKey: "vyra_mic")
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var audioFailure: String?

    private var currentBitrate = VideoFormat.p720.bitrateBps
    private var manualBitrate: Int?
    private var audioMuted = false
    private var micGainDb = 0

    let capture = CameraCapture()
    let discovery = Discovery()
    private var encoder: H264Encoder?
    private var client: Uplink = UndiClient()
    private let audio = AudioCapture()
    private let flags = Flags()
    private var subscriptions = Set<AnyCancellable>()

    private var previewStarted = false
    private var lastConnect: ((@escaping (Bool) -> Void) -> Void)?
    private var statsTimer: Timer?
    private var adaptTimer: Timer?
    private var lastDropped = 0
    private var cueToken = 0
    private var replyToken = 0
    private var reconnecting = false
    private var reconnectDeadline: Date?
    private let maxReconnect: TimeInterval = 90   // reprise bornée (comme Android) puis abandon
    private static let port: UInt16 = 6789
    private static let usbWait: TimeInterval = 30 // attente du pont par câble avant d'abandonner

    init() {
        wireCallbacks()
        discovery.$services
            .receive(on: DispatchQueue.main)
            .sink { [weak self] found in
                guard let self else { return }
                self.discovered = found.first
                if !self.isLive { self.bridgeName = self.link == .wifi ? found.first?.name : nil }
            }
            .store(in: &subscriptions)
        capture.onAnalysis = { [weak self] a in Task { @MainActor in self?.analysis = a } }
        audio.onLevel = { [weak self] l in Task { @MainActor in self?.audioLevel = l } }
        audio.onFailure = { [weak self] f in Task { @MainActor in self?.audioFailure = f } }
    }

    /// (Re)câble les callbacks sur le transport courant — à rappeler après un changement de transport.
    private func wireCallbacks() {
        client.onStatus = { [weak self] s in Task { @MainActor in self?.status = s } }
        client.onTally = { [weak self] t in Task { @MainActor in self?.tally = t } }
        client.onCue = { [weak self] c in Task { @MainActor in self?.showCue(c) } }
        client.onSeen = { [weak self] in Task { @MainActor in self?.markReplySeen() } }
        client.onCommand = { [weak self] cmd in Task { @MainActor in self?.apply(cmd) } }
        client.onDisconnected = { [weak self] in Task { @MainActor in self?.handleDisconnect() } }
    }

    private func selectTransport(srt: Bool) {
        #if SRT_ENABLED
        if srt { client = SrtClient(); wireCallbacks(); return }
        #endif
        client = UndiClient(); wireCallbacks()
    }

    var isStreaming: Bool { if case .streaming = state { return true }; return false }
    var isLive: Bool { isStreaming || state == .connecting }

    // MARK: - Aperçu caméra (avant le direct)

    func startPreview() {
        guard !previewStarted else { return }
        UIApplication.shared.isIdleTimerDisabled = true   // un viseur ne s'éteint pas
        discovery.start()
        CameraCapture.requestAccess { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else { self.status = "Accès caméra refusé"; return }
                self.previewStarted = true
                self.capture.configure(width: self.format.width, height: self.format.height, fps: self.fps)
                self.refreshCaps()
                self.capture.apply(self.controls, old: nil, caps: self.caps)
                self.capture.start()
                self.previewReady = true
                self.startTelemetry()
            }
        }
    }

    private func refreshCaps() {
        caps = capture.capabilities(height: format.height)
        if !caps.constantFps.contains(fps), let near = caps.constantFps.min(by: { abs($0 - 30) < abs($1 - 30) }) {
            fps = near
        }
    }

    // MARK: - Bouton rouge (SEUL déclencheur du passage à l'antenne)

    /// Sans pont découvert en Wi-Fi, l'appui ne fait rien : l'écran affiche déjà « RECHERCHE DU PONT… ».
    func toggleLive() {
        if isLive { stop(); return }
        if link == .usb { startUsb() }
        else if let found = discovered { startDiscovered(found) }
    }

    /// Connexion manuelle par IP (secours).
    func goLiveManual(_ host: String) {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, !isLive else { return }
        startManual(host: h, port: Self.port)
    }

    func startManual(host: String, port: UInt16) {
        selectTransport(srt: transport == .srt)
        beginConnect(label: host) { completion in self.client.connect(host: host, port: port, completion: completion) }
    }

    func startDiscovered(_ found: Discovery.Found) {
        // La découverte Bonjour vise le TCP du pont ; SRT passe par l'adresse saisie.
        selectTransport(srt: false)
        guard let tcp = client as? UndiClient else { return }
        beginConnect(label: found.name) { completion in tcp.connect(endpoint: found.endpoint, label: found.name, completion: completion) }
    }

    /// Câble USB : l'iPhone attend que VYRA Studio le rejoigne par le câble (voir UndiClient.accept).
    func startUsb() {
        selectTransport(srt: false)   // SRT/UDP ne traverse pas le tunnel USB
        guard let tcp = client as? UndiClient else { return }
        beginConnect(label: "USB (câble)", failure: "VYRA Studio introuvable par câble") { completion in
            tcp.accept(port: Self.port, timeout: Self.usbWait, completion: completion)
        }
    }

    private func beginConnect(label: String, failure: String = "Connexion impossible",
                              _ connect: @escaping (@escaping (Bool) -> Void) -> Void) {
        if isLive { return }   // un échec précédent n'empêche pas de réessayer
        lastConnect = connect
        state = .connecting
        status = "Connexion…"
        CameraCapture.requestAccess { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else { self.fail("Accès caméra refusé"); return }
                connect { ok in
                    Task { @MainActor in
                        guard self.state == .connecting else { return }   // annulé entre-temps
                        if ok { self.bridgeName = label; self.onConnected() } else { self.fail(failure) }
                    }
                }
            }
        }
    }

    private func onConnected() {
        let client = self.client
        flags.paused = false
        paused = false
        client.sendHello(name: deviceName)
        client.sendStreamConfig(StreamConfig(codec: .h264, width: format.width, height: format.height, fps: fps, bitrateBps: currentBitrate))

        let enc = H264Encoder(width: format.width, height: format.height, fps: fps)
        enc.onConfig = { cfg in client.sendVideo(cfg, ptsUs: 0, keyframe: false, config: true) }
        enc.onFrame = { data, pts, key in client.sendVideo(data, ptsUs: pts, keyframe: key, config: false) }
        currentBitrate = format.bitrateBps
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

        reportStats()
        startAdaptiveBitrate()
        state = .streaming
        status = "En direct"
        liveSince = Date()
        echo()   // état initial vers le pont
    }

    // MARK: - Micro

    /// Le micro est demandé AU MOMENT DE L'USAGE ; son refus n'empêche pas la vidéo.
    func setMicEnabled(_ on: Bool) {
        guard on else { applyMic(false); return }
        AudioCapture.requestAccess { [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                if ok { self.applyMic(true) } else { self.audioFailure = "Micro non autorisé" }
            }
        }
    }

    private func applyMic(_ on: Bool) {
        micEnabled = on
        UserDefaults.standard.set(on, forKey: "vyra_mic")
        audioFailure = nil
        if on, isStreaming, !audioMuted { startAudio() } else if !on { audio.stop() }
        if isStreaming { echo() }
    }

    private func startAudio() {
        let client = self.client
        audio.setGainDb(micGainDb)
        audio.onPCM = { pcm, sr, ch, pts in client.sendAudio(pcm, sampleRate: sr, channels: ch, ptsUs: pts) }
        AudioCapture.requestAccess { [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                if ok { self.audio.start() } else { self.audioFailure = "Micro non autorisé" }
            }
        }
    }

    // MARK: - Réglages caméra (écran ET régie passent par ici)

    func setControls(_ c: CameraControls) {
        let old = controls
        controls = c
        capture.apply(c, old: old, caps: caps)
        if isStreaming { echo() }
    }

    /// Pincement : valeur immédiate, le doigt prime sur une transition en cours.
    func setZoom(_ z: Float) {
        controls.zoom = min(max(z, 1), caps.maxZoom)
        capture.setZoom(controls.zoom)
        if isStreaming { echo() }
    }

    /// Palier de zoom : transition progressive (un saut de focale est violent à l'antenne).
    func zoomTo(_ z: Float) {
        controls.zoom = min(max(z, 1), caps.maxZoom)
        capture.zoomTo(controls.zoom)
        if isStreaming { echo() }
    }

    /// Appui sur l'image : point + mesure sur ce point. En point manuel, l'appui repasse en auto.
    func focusAt(_ devicePoint: CGPoint) {
        if !controls.autoFocus { setControls(with(controls) { $0.autoFocus = true }) }
        capture.focusAndMeter(at: devicePoint)
    }

    func clearTapFocus() { capture.clearTapFocus() }

    /// Outils d'exposition : un seul flux d'analyse, actif seulement si un outil est affiché.
    func setExposureTools(histogram: Bool, zebraPercent: Int?, peaking: Bool) {
        let on = histogram || zebraPercent != nil || peaking
        capture.setAnalysis(enabled: on, zebraLuma: zebraPercent.map(ExposureAnalysis.thresholdToLuma), peaking: peaking)
        if !on { analysis = .empty }
    }

    /// Cadence de capture (hors direct : elle est annoncée au pont à la connexion).
    func setFps(_ f: Int) {
        guard !isLive else { return }
        fps = f
        capture.setFormat(width: format.width, height: format.height, fps: f)
        refreshCaps()
    }

    /// Résolutions que cet appareil sait produire à la cadence courante.
    func supportedFormats() -> [VideoFormat] { capture.supportedFormats(fps: fps) }

    /// Résolution du flux (hors direct) ; le débit s'ajuste au format choisi.
    func setResolution(_ f: VideoFormat) {
        guard !isLive else { return }
        format = f
        currentBitrate = f.bitrateBps
        capture.setFormat(width: f.width, height: f.height, fps: fps)
        refreshCaps()
    }

    func setAdaptiveBitrate(_ on: Bool) {
        adaptiveBitrate = on
        if isStreaming { echo() }
    }

    // MARK: - Débit adaptatif (recul franc, remontée lente, plafond thermique), comme Android

    private func startAdaptiveBitrate() {
        adaptTimer?.invalidate()
        lastDropped = client.framesDropped
        adaptTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.adaptStep() }
        }
    }

    private func adaptStep() {
        guard isStreaming, let encoder else { return }
        throughputBps = client.throughputBps
        let nominal = format.bitrateBps
        let dropped = client.framesDropped
        let delta = dropped - lastDropped
        lastDropped = dropped
        guard adaptiveBitrate else {
            let target = manualBitrate ?? nominal
            if currentBitrate != target { currentBitrate = target; encoder.setBitrate(target) }
            return
        }
        var next = currentBitrate
        if delta > 2 { next = Int(Double(next) * 0.72) }   // recul FRANC : on désengorge vite
        else if delta == 0 { next += nominal / 10 }         // réseau sain : on remonte doucement
        let minBps = max(nominal / 4, 500_000)
        let thermalCap = Int(Double(nominal) * thermalFactor(thermal))
        next = min(max(next, minBps), max(thermalCap, minBps))
        if next != currentBitrate { currentBitrate = next; encoder.setBitrate(next) }
    }

    private func thermalFactor(_ t: ThermalLevel) -> Double {
        switch t {
        case .warm: return 0.85
        case .hot: return 0.6
        case .critical: return 0.4
        default: return 1
        }
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
        if isStreaming { client.sendStats(DeviceStats(batteryPercent: battery, charging: charging, thermal: thermal)) }
    }

    // MARK: - Canal retour : CUE / REPLY

    private func showCue(_ c: Cue) {
        guard !c.text.isEmpty else { return }
        cue = c
        cueToken += 1
        let token = cueToken
        DispatchQueue.main.asyncAfter(deadline: .now() + (c.urgent ? 8.0 : 6.0)) { [weak self] in
            guard let self, self.cueToken == token else { return }
            self.cue = nil
        }
    }

    /// Réponse du vidéaste vers la régie (réponse rapide, accusé de consigne, alerte, message libre).
    func sendReply(_ text: String, alert: Bool = false) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, isStreaming else { return }
        client.sendReply(Reply(text: t, alert: alert))
        replyStatus = ReplyStatus(text: t)
        replyToken += 1
        let token = replyToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.replyToken == token else { return }
            self.replyStatus = nil
        }
    }

    /// Accusé de la consigne affichée : ferme la boucle avec la régie (« ✓ <consigne> »).
    func acknowledgeCue() {
        guard let c = cue else { return }
        sendReply("✓ " + c.text)
        cue = nil
    }

    private func markReplySeen() {
        guard var r = replyStatus, !r.seen else { return }
        r.seen = true
        replyStatus = r
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

        var c = controls
        if let v = cmd.torch { c.torch = v }
        if let v = cmd.autoExposure { c.autoExposure = v }
        if let v = cmd.iso { c.iso = v }
        if let v = cmd.exposureTimeNs { c.exposureTimeNs = v }
        if let v = cmd.aeCompensation { c.aeCompensation = v }
        if let v = cmd.wbManual { c.wbManual = v }
        if let v = cmd.wbKelvin { c.wbKelvin = v }
        if let v = cmd.autoFocus { c.autoFocus = v }
        if let v = cmd.focusDistance { c.focusPosition = v; c.autoFocus = false }
        let old = controls
        controls = c
        capture.apply(c, old: old, caps: caps)
        if let z = cmd.zoom { zoomTo(z) }

        cmd.paused.map { setPaused($0) }
        if let muted = cmd.audioMuted { setAudioMuted(muted) }
        if let gain = cmd.micGainDb { micGainDb = gain; audio.setGainDb(gain) }
        cmd.adaptiveBitrate.map { adaptiveBitrate = $0 }
        if let kbps = cmd.bitrateKbps {
            manualBitrate = kbps * 1000
            if !adaptiveBitrate { currentBitrate = kbps * 1000; encoder?.setBitrate(currentBitrate) }
        }
        if let h = cmd.resolutionHeight, let f = VideoFormat.candidates.first(where: { $0.height == h }) {
            format = f
        }

        if cmd.restartStream == true { restart() } else { echo() }
    }

    /// Coupe/relance l'envoi vidéo SANS fermer la connexion (le pont garde son canal de commande).
    private func setPaused(_ p: Bool) {
        flags.paused = p
        paused = p
        if !p { encoder?.requestKeyframe() }   // sans image clé, le pont ne redécode pas
    }

    /// Coupe/rend le son : on LIBÈRE réellement le micro (indicateur système éteint), comme Android.
    private func setAudioMuted(_ muted: Bool) {
        audioMuted = muted
        if muted { audio.stop() } else if micEnabled && isStreaming { startAudio() }
    }

    // MARK: - Reconnexion bornée (reprise d'une micro-coupure, puis abandon)

    private func handleDisconnect() {
        guard isStreaming else { return }   // perte involontaire pendant le direct
        reconnecting = true
        reconnectDeadline = Date().addingTimeInterval(maxReconnect)
        status = "Reconnexion…"
        attemptReconnect(backoff: 0.5)
    }

    private func attemptReconnect(backoff: Double) {
        guard reconnecting, isStreaming, let connect = lastConnect else { return }
        if Date() > (reconnectDeadline ?? .distantPast) {
            reconnecting = false
            fail("Connexion perdue — direct arrêté (le réseau est resté coupé trop longtemps)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff) { [weak self] in
            guard let self, self.reconnecting else { return }
            connect { ok in
                Task { @MainActor in
                    guard self.reconnecting else { return }
                    if ok { self.onReconnected() } else { self.attemptReconnect(backoff: min(backoff * 2, 5)) }
                }
            }
        }
    }

    /// Lien rétabli : on refait le handshake et on force SPS/PPS + image clé (le pont a tout perdu).
    private func onReconnected() {
        reconnecting = false
        status = "En direct"
        client.sendHello(name: deviceName)
        client.sendStreamConfig(StreamConfig(codec: .h264, width: format.width, height: format.height, fps: fps, bitrateBps: currentBitrate))
        encoder?.resendConfig()
        encoder?.requestKeyframe()
        if micEnabled && !audioMuted { startAudio() }
        reportStats()
        echo()
    }

    /// Reconnecte le lien pour appliquer une nouvelle résolution en direct (comme Android).
    private func restart() {
        guard let connect = lastConnect, let label = bridgeName else { echo(); return }
        stop()
        capture.setFormat(width: format.width, height: format.height, fps: fps)
        refreshCaps()
        beginConnect(label: label, connect)
    }

    private func echo() {
        client.sendControl(CameraCommand(
            autoExposure: capture.isExposureAuto,
            iso: capture.currentISO,
            exposureTimeNs: capture.currentExposureNs,
            aeCompensation: controls.aeCompensation,
            awbMode: nil,
            wbManual: capture.isWhiteBalanceManual,
            wbKelvin: controls.wbManual ? controls.wbKelvin : nil,
            autoFocus: capture.isFocusAuto,
            focusDistance: nil,
            zoom: controls.zoom,
            paused: flags.paused,
            torch: capture.torchOn,
            audioMuted: audioMuted || !micEnabled,
            micGainDb: micGainDb,
            adaptiveBitrate: adaptiveBitrate,
            bitrateKbps: currentBitrate / 1000,
            resolutionHeight: format.height,
            restartStream: nil))
    }

    // MARK: - Arrêt / erreur

    func stop() {
        endLive()
        state = .idle
        status = "Prêt"
    }

    func teardown() {
        stop()
        capture.stop()
        statsTimer?.invalidate(); statsTimer = nil
        discovery.stop()
        previewStarted = false
        previewReady = false
    }

    private func fail(_ message: String) {
        endLive()
        state = .failed(message)
        status = message
    }

    private func endLive() {
        reconnecting = false
        adaptTimer?.invalidate(); adaptTimer = nil
        capture.onSample = nil
        audio.stop()
        encoder?.stop(); encoder = nil
        client.close()
        // Plus de lien = plus d'antenne. Laisser un voyant rouge allumé serait dangereux.
        tally = .off
        cue = nil
        paused = false
        flags.paused = false
        throughputBps = 0
        liveSince = nil
        bridgeName = link == .wifi ? discovered?.name : nil
    }

    /// Change le mode de connexion (hors direct).
    func setLink(_ l: Link) {
        guard !isLive else { return }
        link = l
        bridgeName = l == .wifi ? discovered?.name : nil
    }
}

/// Copie modifiée d'une valeur (évite les `var c = …; c.x = …` en cascade).
func with<T>(_ value: T, _ change: (inout T) -> Void) -> T {
    var v = value
    change(&v)
    return v
}
