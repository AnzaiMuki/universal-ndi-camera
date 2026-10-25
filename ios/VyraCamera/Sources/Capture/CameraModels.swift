import Foundation
import CoreVideo

// Modèles de la caméra, miroir de l'app Android (CameraControls.kt, CameraCapabilities.kt,
// ExposureAnalysis.kt, LumaHistogram.kt). Mêmes champs, mêmes valeurs métier.

/// Stabilisation : iOS ne pilote pas l'optique (OIS) séparément ; seul l'électronique est proposé.
enum StabilizationMode { case off, optical, electronic }

/// Réglages caméra appliqués à chaud. Champs manuels ignorés quand l'auto correspondant est actif.
struct CameraControls: Equatable {
    var autoExposure = true
    var iso: Int?
    var exposureTimeNs: Int64?
    var aeCompensation = 0           // en crans de `CameraCapabilities.aeCompStep` EV
    var awbMode = CameraCapabilities.awbAuto
    var wbManual = false
    var wbKelvin = 5600
    var autoFocus = true
    var focusPosition: Float = 1     // position d'objectif 0 (proche) … 1 (infini)
    var zoom: Float = 1
    var torch = false
    var stabilization: StabilizationMode = .off
}

/// Ce que le capteur sait réellement faire : l'interface ne propose rien d'autre.
struct CameraCapabilities: Equatable {
    static let awbAuto = 1           // même valeur que CONTROL_AWB_MODE_AUTO côté Android

    var maxZoom: Float = 1
    var isoRange: ClosedRange<Int>?
    var exposureTimeRange: ClosedRange<Int64>?
    var aeCompRange: ClosedRange<Int> = 0...0
    var aeCompStep: Float = 1.0 / 3.0
    var manualWhiteBalance = false
    var supportsManualFocus = false
    var hasFlash = false
    var hasOpticalStabilization = false
    var hasElectronicStabilization = false
    var constantFps: [Int] = [30]
    var awbModes: [Int] = [awbAuto]

    var supportsZoom: Bool { maxZoom > 1.05 }
    var manualSensor: Bool { isoRange != nil && exposureTimeRange != nil }
    var supportsExposureCompensation: Bool { aeCompRange.lowerBound < aeCompRange.upperBound }
    var supportsStabilization: Bool { hasOpticalStabilization || hasElectronicStabilization }
}

/// Un format vidéo proposable (débit calibré pour la résolution), comme VideoFormat côté Android.
struct VideoFormat: Equatable, Identifiable {
    let label: String
    let width: Int
    let height: Int
    let bitrateBps: Int
    var id: Int { height }

    static let p360 = VideoFormat(label: "360p", width: 640, height: 360, bitrateBps: 900_000)
    static let p720 = VideoFormat(label: "720p", width: 1280, height: 720, bitrateBps: 3_500_000)
    static let p1080 = VideoFormat(label: "1080p", width: 1920, height: 1080, bitrateBps: 6_000_000)
    static let p1440 = VideoFormat(label: "1440p", width: 2560, height: 1440, bitrateBps: 10_000_000)
    static let candidates = [p360, p720, p1080, p1440]
}

// MARK: - Analyse d'exposition

/// Histogramme de luminance sur 64 classes + indicateurs d'écrêtage.
struct LumaHistogram: Equatable {
    static let binCount = 64
    static let empty = LumaHistogram(bins: [Int](repeating: 0, count: binCount), clippedLow: 0, clippedHigh: 0)
    var bins: [Int]
    var clippedLow: Float
    var clippedHigh: Float
    var max: Int { bins.max() ?? 0 }
}

/// Masque binaire basse définition (zebras ou peaking), indexé `y * width + x`.
struct AnalysisMask: Equatable {
    let width: Int
    let height: Int
    let cells: [UInt8]
    var hasAny: Bool { cells.contains { $0 != 0 } }
}

struct ExposureAnalysis: Equatable {
    var histogram: LumaHistogram
    var zebra: AnalysisMask?
    var peaking: AnalysisMask?

    static let empty = ExposureAnalysis(histogram: .empty, zebra: nil, peaking: nil)
    static let thresholds = [70, 85, 95]
    static let peakingGradient = 42
    static let analysisWidth = 320, analysisHeight = 180
    private static let clipLow = 4, clipHigh = 251

    static func thresholdToLuma(_ percent: Int) -> Int { Swift.min(Swift.max(percent * 255 / 100, 1), 255) }

    /// Analyse le plan de luminance d'une image NV12, échantillonné en 320×180, en UNE passe.
    static func of(_ pixelBuffer: CVPixelBuffer, zebraLuma: Int?, peaking: Bool) -> ExposureAnalysis {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return .empty }
        let srcW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let srcH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let src = base.assumingMemoryBound(to: UInt8.self)
        let w = analysisWidth, h = analysisHeight
        guard srcW >= w, srcH >= h else { return .empty }

        // Sous-échantillonnage : un pixel source par cellule d'analyse.
        var y = [UInt8](repeating: 0, count: w * h)
        for row in 0..<h {
            let line = src + (row * srcH / h) * stride
            for col in 0..<w { y[row * w + col] = line[col * srcW / w] }
        }

        var bins = [Int](repeating: 0, count: LumaHistogram.binCount)
        var low = 0, high = 0
        var zebra = zebraLuma.map { _ in [UInt8](repeating: 0, count: w * h) }
        let zThreshold = zebraLuma ?? Int.max
        var peak = peaking ? [UInt8](repeating: 0, count: w * h) : nil

        for row in 0..<h {
            for col in 0..<w {
                let i = row * w + col
                let luma = Int(y[i])
                bins[luma * LumaHistogram.binCount / 256] += 1
                if luma <= clipLow { low += 1 }
                if luma >= clipHigh { high += 1 }
                if luma >= zThreshold { zebra?[i] = 1 }
                if peak != nil, col > 0, row > 0 {
                    let gradient = abs(luma - Int(y[i - 1])) + abs(luma - Int(y[i - w]))
                    if gradient >= peakingGradient { peak?[i] = 1 }
                }
            }
        }
        let total = Float(w * h)
        return ExposureAnalysis(
            histogram: LumaHistogram(bins: bins, clippedLow: Float(low) / total, clippedHigh: Float(high) / total),
            zebra: zebra.map { AnalysisMask(width: w, height: h, cells: $0) },
            peaking: peak.map { AnalysisMask(width: w, height: h, cells: $0) })
    }
}
