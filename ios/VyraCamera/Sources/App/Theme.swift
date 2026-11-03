import SwiftUI

// Palette et typographie de l'app Android (CameraScreen.kt), reprises à l'identique : monde
// volontairement sombre, un viseur ne change pas de thème.
enum Vyra {
    static let accent = Color(argb: 0xFF2E9BFF)
    static let live = Color(argb: 0xFFFF3B30)
    static let amber = Color(argb: 0xFFFFC24B)
    static let ready = Color(argb: 0xFF34C77B)
    static let hudBg = Color(argb: 0xD10B0E12)
    static let hudLine = Color(argb: 0x24FFFFFF)
    static let muted = Color(argb: 0xFF8B95A1)
    static let chipText = Color(argb: 0xFFCFD6DE)

    /// Largeur du rail d'outils (marge 8 + cadre 6 + bouton 38 + cadre 6 + marge 8).
    static let railWidth: CGFloat = 66

    // Thème Material 3 sombre par défaut (écrans d'accueil : CLUF, autorisation caméra).
    static let m3Background = Color(argb: 0xFF1C1B1F)
    static let m3OnSurface = Color(argb: 0xFFE6E1E5)
    static let m3Primary = Color(argb: 0xFFD0BCFF)
    static let m3OnPrimary = Color(argb: 0xFF381E72)
    static let m3Outline = Color(argb: 0xFF938F99)
}

extension Color {
    /// Couleur au format Android 0xAARRGGBB.
    init(argb: UInt32) {
        self.init(.sRGB,
                  red: Double((argb >> 16) & 0xFF) / 255,
                  green: Double((argb >> 8) & 0xFF) / 255,
                  blue: Double(argb & 0xFF) / 255,
                  opacity: Double((argb >> 24) & 0xFF) / 255)
    }
}

extension View {
    /// Ombre portée des textes posés sur l'image : sans elle, ils disparaissent sur une scène claire.
    func readoutShadow() -> some View {
        shadow(color: Color(argb: 0xE6000000), radius: 2.5, x: 0, y: 1)
    }
}

extension Font {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Facteur de zoom lisible : « 2× » ou « 3.1× ».
func zoomLabel(_ zoom: Float) -> String {
    abs(zoom - zoom.rounded()) < 0.05 ? "\(Int(zoom.rounded()))×" : String(format: "%.1f×", zoom)
}

func shutterFromNs(_ ns: Int64) -> String {
    ns <= 0 ? "—" : "1/\(Int((1_000_000_000.0 / Double(ns)).rounded()))"
}

/// Position d'objectif → libellé : l'infini à l'extrémité, sinon la position en pourcentage.
func focusLabel(_ position: Float) -> String {
    position >= 0.99 ? "∞" : "\(Int((position * 100).rounded())) %"
}

func awbLabel(_ mode: Int) -> String { mode == CameraCapabilities.awbAuto ? "Auto" : "WB \(mode)" }
