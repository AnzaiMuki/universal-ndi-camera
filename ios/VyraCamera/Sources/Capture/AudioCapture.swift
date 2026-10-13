import Foundation
import AVFoundation

// Capture micro en PCM 16 bits MONO 48 kHz (format EXACT attendu par VYRA Studio ; voir
// AudioCapture.kt + TcpSink.onAudioFrame côté Android). L'audio est OPTIONNEL : une panne micro
// ne doit jamais couper la vidéo, donc start() n'échoue pas bruyamment — il n'émet simplement rien.
//
// Horodatage : secondes d'horloge hôte (AVAudioTime.seconds(forHostTime:)), MÊME base que les PTS
// vidéo (CMSampleBuffer sur l'horloge hôte du capteur) → synchro labiale correcte côté pont.
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true)!
    private var started = false

    // Appelé pour chaque bloc converti : (PCM int16 LE, sampleRate, channels, ptsUs). Thread audio.
    var onPCM: ((Data, Int, Int, Int64) -> Void)?
    var onFailure: ((String) -> Void)?

    // Gain linéaire appliqué au PCM avant envoi (1 = natif). Piloté à distance via setGainDb [-24,+24] dB.
    private var gainFactor: Float = 1

    func setGainDb(_ db: Int) {
        let clamped = min(max(db, -24), 24)
        gainFactor = clamped == 0 ? 1 : powf(10, Float(clamped) / 20)
    }

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        let s = AVAudioSession.sharedInstance()
        switch s.recordPermission {
        case .granted: done(true)
        case .undetermined: s.requestRecordPermission { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    func start() {
        guard !started else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default, options: [.allowBluetooth])
            try session.setActive(true)
        } catch {
            onFailure?("Session audio indisponible")
            return
        }

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            onFailure?("Micro indisponible")
            return
        }
        converter = conv

        // ~20 ms à la cadence d'entrée (comme les blocs de 1920 o côté Android).
        let tapFrames = AVAudioFrameCount(inFormat.sampleRate * 0.02)
        input.installTap(onBus: 0, bufferSize: max(tapFrames, 256), format: inFormat) { [weak self] buffer, when in
            self?.handle(buffer, when: when)
        }

        do {
            engine.prepare()
            try engine.start()
            started = true
        } catch {
            input.removeTap(onBus: 0)
            onFailure?("Démarrage audio impossible")
        }
    }

    func stop() {
        guard started else { return }
        started = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func handle(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let converter, let onPCM else { return }

        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if err != nil || out.frameLength == 0 { return }

        guard let ch = out.int16ChannelData else { return }
        let count = Int(out.frameLength)

        // Gain : multiplie chaque échantillon int16 par le facteur, avec écrêtage dur (comme Android).
        if gainFactor != 1 {
            let g = gainFactor
            let p = ch[0]
            for i in 0..<count {
                let v = Int(Float(p[i]) * g)
                p[i] = Int16(min(max(v, -32768), 32767))
            }
        }

        let byteCount = count * MemoryLayout<Int16>.size
        let pcm = Data(bytes: ch[0], count: byteCount)

        let ptsUs = Int64(AVAudioTime.seconds(forHostTime: when.hostTime) * 1_000_000)
        onPCM(pcm, Int(outFormat.sampleRate), 1, ptsUs)
    }
}
