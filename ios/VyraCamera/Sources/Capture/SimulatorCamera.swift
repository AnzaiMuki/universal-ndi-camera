#if targetEnvironment(simulator)
import Foundation
import CoreMedia
import CoreVideo

// Le simulateur iOS n'a pas de caméra : cette mire animée (1280×720, NV12, 30 i/s) la remplace pour que
// toute la chaîne (encodeur H.264, réseau, sortie HDMI) tourne dans le CI. Absente des builds iPhone.
final class SimulatorCamera {
    static let width = 1280, height = 720, fps = 30
    private var timer: DispatchSourceTimer?
    private var index = 0

    func start(on queue: DispatchQueue, deliver: @escaping (CMSampleBuffer) -> Void) {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(1000 / Self.fps))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if let sample = Self.frame(index: self.index) { deliver(sample) }
            self.index += 1
        }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Une image : dégradé vertical + barre claire qui défile (le mouvement prouve que les images changent).
    static func frame(index: Int, width: Int = width, height: Int = height) -> CMSampleBuffer? {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &buffer) == kCVReturnSuccess,
              let pb = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let luma = base.assumingMemoryBound(to: UInt8.self)
            let bar = (index * 16) % width
            for row in 0..<height {
                let line = luma + row * stride
                memset(line, Int32(40 + row * 120 / height), width)
                memset(line + bar, 235, min(64, width - bar))
            }
        }
        if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            memset(base, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * CVPixelBufferGetHeightOfPlane(pb, 1))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }
}
#endif
