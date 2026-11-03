import Foundation

// Interface commune aux transports vers VYRA Studio : TCP/NDI (UndiClient) et SRT (SrtClient).
// StreamManager pilote l'un ou l'autre à l'identique ; seule la façon de se connecter diffère.
protocol Uplink: AnyObject {
    var onStatus: ((String) -> Void)? { get set }
    var onTally: ((TallyState) -> Void)? { get set }
    var onCommand: ((CameraCommand) -> Void)? { get set }
    var onCue: ((Cue) -> Void)? { get set }
    var onSeen: (() -> Void)? { get set }
    var onDisconnected: (() -> Void)? { get set }

    func connect(host: String, port: UInt16, completion: @escaping (Bool) -> Void)
    func sendHello(name: String)
    func sendStreamConfig(_ cfg: StreamConfig)
    func sendVideo(_ annexB: Data, ptsUs: Int64, keyframe: Bool, config: Bool)
    func sendAudio(_ pcm: Data, sampleRate: Int, channels: Int, ptsUs: Int64)
    func sendReply(_ reply: Reply)
    func sendStats(_ stats: DeviceStats)
    func sendControl(_ cmd: CameraCommand)
    func close()

    /// Débit réellement écoulé (bits/s) et images intermédiaires sacrifiées en cas de saturation.
    var throughputBps: Int { get }
    var framesDropped: Int { get }
}

extension Uplink {
    var throughputBps: Int { 0 }
    var framesDropped: Int { 0 }
}
