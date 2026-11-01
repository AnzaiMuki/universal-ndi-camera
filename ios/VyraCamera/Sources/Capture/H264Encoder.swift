import Foundation
import VideoToolbox
import CoreMedia

// Encodeur H.264 / HEVC matériel (VideoToolbox). Sort de l'Annex-B (préfixes 00 00 00 01) comme
// l'app Android, et émet les paramètres (SPS/PPS, + VPS en HEVC) séparément en trame CONFIG — c'est ce
// que VYRA Studio attend. Le HEVC n'est demandé que si le pont l'annonce (voir StreamManager).
final class H264Encoder {
    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    private let fps: Int32
    private let hevc: Bool
    private var sentConfig = false
    private var forceKeyframeNext = true   // la première image est forcée en clé

    var onConfig: ((Data) -> Void)?             // SPS/PPS (Annex-B)
    var onFrame: ((Data, Int64, Bool) -> Void)? // (Annex-B, ptsUs, estKeyframe)

    init(width: Int, height: Int, fps: Int, hevc: Bool = false) {
        self.width = Int32(width); self.height = Int32(height); self.fps = Int32(fps); self.hevc = hevc
    }

    /// L'appareil sait-il encoder ce format en HEVC matériel ? (A10 et suivants, selon la définition.)
    static func supportsHEVC(width: Int, height: Int) -> Bool {
        var id: CFString?
        var props: CFDictionary?
        return VTCopySupportedPropertyDictionaryForEncoder(
            width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil, encoderIDOut: &id, supportedPropertiesOut: &props) == noErr
    }

    func start(bitrateBps: Int) {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width, height: height,
            codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &created)
        guard status == noErr, let session = created else { return }
        self.session = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // H.264 High (CABAC, ~10-15 % de qualité en plus à débit égal que Main) ; HEVC Main.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 2))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2))
        setBitrate(bitrateBps)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func setBitrate(_ bps: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bps))
        let limits = [NSNumber(value: bps / 8), NSNumber(value: 1)] as CFArray // octets / 1 s
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    func requestKeyframe() { forceKeyframeNext = true }

    /// Après une reconnexion, force la ré-émission du SPS/PPS à la prochaine image clé (sans quoi le
    /// pont, qui a perdu son contexte, ne saurait pas redécoder le flux).
    func resendConfig() { sentConfig = false }

    func encode(_ pixelBuffer: CVPixelBuffer, ptsUs: Int64) {
        guard let session else { return }
        let pts = CMTime(value: ptsUs, timescale: 1_000_000)
        var props: CFDictionary?
        if forceKeyframeNext {
            forceKeyframeNext = false
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self, status == noErr, let sb = sampleBuffer else { return }
            self.handle(sb, ptsUs: ptsUs)
        }
    }

    private func handle(_ sb: CMSampleBuffer, ptsUs: Int64) {
        let keyframe = Self.isKeyframe(sb)
        if keyframe, !sentConfig, let fmt = CMSampleBufferGetFormatDescription(sb), let cfg = Self.annexBParameterSets(fmt, hevc: hevc) {
            sentConfig = true
            onConfig?(cfg)
        }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        // Le tampon compressé peut être fragmenté (grosses images clés) : on le recopie d'un bloc
        // plutôt que de lire `totalLength` octets derrière un pointeur qui n'en couvre qu'une partie.
        let totalLength = CMBlockBufferGetDataLength(bb)
        var avcc = [UInt8](repeating: 0, count: totalLength)
        guard CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: totalLength, destination: &avcc) == kCMBlockBufferNoErr else { return }
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        out.reserveCapacity(totalLength + 16)
        var i = 0
        while i + 4 <= totalLength {
            // préfixe de longueur AVCC (big-endian)
            let nalLen = Int(avcc[i]) << 24 | Int(avcc[i + 1]) << 16 | Int(avcc[i + 2]) << 8 | Int(avcc[i + 3])
            i += 4
            if nalLen <= 0 || i + nalLen > totalLength { break }
            out.append(contentsOf: startCode)
            out.append(contentsOf: avcc[i..<(i + nalLen)])
            i += nalLen
        }
        if !out.isEmpty { onFrame?(out, ptsUs, keyframe) }
    }

    private static func isKeyframe(_ sb: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
              let first = arr.first else { return true }
        let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !notSync
    }

    private static func annexBParameterSets(_ fmt: CMFormatDescription, hevc: Bool) -> Data? {
        // Même signature pour les deux codecs : on choisit la fonction d'accès aux paramètres.
        let get = hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex : CMVideoFormatDescriptionGetH264ParameterSetAtIndex
        var count = 0
        guard get(fmt, 0, nil, nil, &count, nil) == noErr else { return nil }
        let startCode: [UInt8] = [0, 0, 0, 1]
        var data = Data()
        for idx in 0..<count {
            var psPtr: UnsafePointer<UInt8>?
            var psSize = 0
            if get(fmt, idx, &psPtr, &psSize, nil, nil) == noErr, let p = psPtr {
                data.append(contentsOf: startCode)
                data.append(UnsafeBufferPointer(start: p, count: psSize))
            }
        }
        return data.isEmpty ? nil : data
    }

    func stop() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        sentConfig = false
        forceKeyframeNext = true
    }
}
