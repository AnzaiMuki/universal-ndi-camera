import Foundation
import AVFoundation
import Network
import UIKit

// Orchestrateur : relie la capture caméra, l'encodeur H.264 et le client réseau UNDI.
// Enchaînement du direct (identique à l'app Android) :
//   connexion TCP → HELLO → STREAM_CONFIG → SPS/PPS (VIDEO+CONFIG) → trames VIDEO.
@MainActor
final class StreamManager: ObservableObject {
    enum State: Equatable { case idle, connecting, streaming, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var status: String = "Prêt"
    @Published var deviceName: String = UIDevice.current.name
    @Published var micEnabled = true   // l'audio est optionnel ; activable avant le direct

    // Paramètres du flux (version minimale : 720p30 ≈ 4 Mbit/s).
    private let width = 1280, height = 720, fps = 30, bitrate = 4_000_000

    let capture = CameraCapture()
    private var encoder: H264Encoder?
    private let client = UndiClient()
    private let audio = AudioCapture()

    private var previewStarted = false

    init() {
        client.onStatus = { [weak self] s in Task { @MainActor in self?.status = s } }
    }

    var isStreaming: Bool { if case .streaming = state { return true }; return false }

    // MARK: - Aperçu caméra (avant le direct, pour cadrer)

    func startPreview() {
        guard !previewStarted else { return }
        CameraCapture.requestAccess { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else { self.status = "Accès caméra refusé"; return }
                self.previewStarted = true
                self.capture.configure()
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
        // Capturés localement : la boucle capture→encodeur→réseau tourne alors sur la file de
        // capture (hors thread principal), sans repasser par l'acteur principal à chaque image.
        let client = self.client
        client.sendHello(name: deviceName)
        client.sendStreamConfig(StreamConfig(codec: .h264, width: width, height: height, fps: fps, bitrateBps: bitrate))

        let enc = H264Encoder(width: width, height: height, fps: fps)
        enc.onConfig = { cfg in client.sendVideo(cfg, ptsUs: 0, keyframe: false, config: true) }
        enc.onFrame = { data, pts, key in client.sendVideo(data, ptsUs: pts, keyframe: key, config: false) }
        enc.start(bitrateBps: bitrate)
        encoder = enc

        // La session tourne déjà (aperçu) : on branche simplement l'encodeur sur le flux d'images.
        capture.onSample = { sample in
            guard let pixel = CMSampleBufferGetImageBuffer(sample) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let ptsUs = Int64((CMTimeGetSeconds(pts) * 1_000_000).rounded())
            enc.encode(pixel, ptsUs: ptsUs)
        }

        // Audio OPTIONNEL : s'il échoue, la vidéo continue (comme côté Android).
        if micEnabled {
            audio.onPCM = { pcm, sr, ch, pts in client.sendAudio(pcm, sampleRate: sr, channels: ch, ptsUs: pts) }
            audio.start()
        }

        state = .streaming
        status = "En direct"
    }

    // MARK: - Arrêt / erreur

    /// Arrête le direct mais garde l'aperçu caméra actif (on peut relancer aussitôt).
    func stop() {
        capture.onSample = nil
        audio.stop()
        encoder?.stop()
        encoder = nil
        client.close()
        state = .idle
        status = "Prêt"
    }

    /// Coupe tout, y compris l'aperçu (à la sortie de l'écran).
    func teardown() {
        stop()
        capture.stop()
        previewStarted = false
    }

    private func fail(_ message: String) {
        capture.onSample = nil
        audio.stop()
        encoder?.stop(); encoder = nil
        client.close()
        state = .failed(message)
        status = message
    }
}
