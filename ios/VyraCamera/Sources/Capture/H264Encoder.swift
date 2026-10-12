import Foundation
import VideoToolbox
import CoreMedia

// Encodeur H.264 matériel (VideoToolbox). Sort du H.264 en Annex-B (préfixes 00 00 00 01) comme
// l'app Android, et émet le SPS/PPS séparément en trame CONFIG — c'est ce que VYRA Studio attend.
final class H264Encoder {
    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    private let fps: Int32
    private var sentConfig = false
    private var forceKeyframeNext = true   // la première image est forcée en clé

    var onConfig: ((Data) -> Void)?             // SPS/PPS (Annex-B)
    var onFrame: ((Data, Int64, Bool) -> Void)? // (Annex-B, ptsUs, estKeyframe)

    init(width: Int, height: Int, fps: Int) {
        self.width = Int32(width); self.height = Int32(height); self.fps = Int32(fps)
    }

    func start(bitrateBps: Int) {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width, height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &created)
        guard status == noErr, let session = created else { return }
        self.session = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
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
        if keyframe, !sentConfig, let fmt = CMSampleBufferGetFormatDescription(sb), let cfg = Self.annexBParameterSets(fmt) {
            sentConfig = true
            onConfig?(cfg)
        }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        var lengthAtOffset = 0, totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
              let ptr = dataPointer else { return }
        let raw = UnsafeRawPointer(ptr)
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        var i = 0
        while i + 4 <= totalLength {
            var beLen: UInt32 = 0
            memcpy(&beLen, raw + i, 4)                 // préfixe de longueur AVCC (big-endian)
            let nalLen = Int(CFSwapInt32BigToHost(beLen))
            i += 4
            if nalLen <= 0 || i + nalLen > totalLength { break }
            out.append(contentsOf: startCode)
            out.append(Data(bytes: raw + i, count: nalLen))
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

    private static func annexBParameterSets(_ fmt: CMFormatDescription) -> Data? {
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr else { return nil }
        let startCode: [UInt8] = [0, 0, 0, 1]
        var data = Data()
        for idx in 0..<count {
            var psPtr: UnsafePointer<UInt8>?
            var psSize = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: idx, parameterSetPointerOut: &psPtr, parameterSetSizeOut: &psSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p = psPtr {
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
