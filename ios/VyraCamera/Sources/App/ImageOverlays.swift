import SwiftUI
import CoreMotion

// Surcouches posées DANS la zone image (bornée au vrai 16:9) : elles collent à l'image réelle.
// Toutes sont locales à l'écran — jamais incrustées dans le flux NDI.

/// Repères de cadrage (masque de bits, comme l'Android).
struct Guide: OptionSet, Hashable {
    let rawValue: Int
    static let thirds = Guide(rawValue: 1)
    static let grid = Guide(rawValue: 2)
    static let center = Guide(rawValue: 4)
    static let safe = Guide(rawValue: 8)
    static let all: [(Guide, String)] = [(.thirds, "Tiers"), (.grid, "Quadrillage"), (.center, "Centre"), (.safe, "Zone sûre")]
}

struct GuidesOverlay: View {
    let mask: Guide

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            func line(_ a: CGPoint, _ b: CGPoint, _ c: Color, _ width: CGFloat = 1) {
                var p = Path(); p.move(to: a); p.addLine(to: b)
                ctx.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            if mask.contains(.grid) {
                for i in 1...3 {
                    line(CGPoint(x: w * CGFloat(i) / 4, y: 0), CGPoint(x: w * CGFloat(i) / 4, y: h), .white.opacity(0.20))
                    line(CGPoint(x: 0, y: h * CGFloat(i) / 4), CGPoint(x: w, y: h * CGFloat(i) / 4), .white.opacity(0.20))
                }
            }
            if mask.contains(.thirds) {
                for i in 1...2 {
                    line(CGPoint(x: w * CGFloat(i) / 3, y: 0), CGPoint(x: w * CGFloat(i) / 3, y: h), .white.opacity(0.42))
                    line(CGPoint(x: 0, y: h * CGFloat(i) / 3), CGPoint(x: w, y: h * CGFloat(i) / 3), .white.opacity(0.42))
                }
            }
            if mask.contains(.center) {
                let cx = w / 2, cy = h / 2, arm = h * 0.045
                line(CGPoint(x: cx - arm, y: cy), CGPoint(x: cx + arm, y: cy), .white.opacity(0.85), 1.4)
                line(CGPoint(x: cx, y: cy - arm), CGPoint(x: cx, y: cy + arm), .white.opacity(0.85), 1.4)
            }
            if mask.contains(.safe) {
                // Zone sûre broadcast : 90 % de l'image.
                ctx.stroke(Path(CGRect(x: w * 0.05, y: h * 0.05, width: w * 0.9, height: h * 0.9)),
                           with: .color(Vyra.amber.opacity(0.5)), lineWidth: 1.4)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Réticule ambre à l'endroit touché : quatre équerres, lisibles sur n'importe quel fond.
struct FocusReticle: View {
    let point: CGPoint
    @State private var scale: CGFloat = 1.35
    @State private var alpha: Double = 1

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, inset = w * (1 - scale) / 2
            let lo = inset, hi = w - inset, len = w * 0.22
            let c = Vyra.amber
            func line(_ a: CGPoint, _ b: CGPoint) {
                var p = Path(); p.move(to: a); p.addLine(to: b)
                ctx.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
            line(CGPoint(x: lo, y: lo), CGPoint(x: lo + len, y: lo)); line(CGPoint(x: lo, y: lo), CGPoint(x: lo, y: lo + len))
            line(CGPoint(x: hi, y: lo), CGPoint(x: hi - len, y: lo)); line(CGPoint(x: hi, y: lo), CGPoint(x: hi, y: lo + len))
            line(CGPoint(x: lo, y: hi), CGPoint(x: lo + len, y: hi)); line(CGPoint(x: lo, y: hi), CGPoint(x: lo, y: hi - len))
            line(CGPoint(x: hi, y: hi), CGPoint(x: hi - len, y: hi)); line(CGPoint(x: hi, y: hi), CGPoint(x: hi, y: hi - len))
            let r = w * 0.028
            ctx.fill(Path(ellipseIn: CGRect(x: w / 2 - r, y: w / 2 - r, width: r * 2, height: r * 2)), with: .color(c))
        }
        .frame(width: 78, height: 78)
        .opacity(alpha)
        .position(point)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) { scale = 1 }
            withAnimation(.easeIn(duration: 0.28).delay(1.5)) { alpha = 0 }
        }
    }
}

/// Voyant tally : cadre coloré sur tout le pourtour de l'image (rouge épais = antenne, vert = prêt).
struct TallyOverlay: View {
    let tally: TallyState

    var body: some View {
        if tally.program || tally.preview {
            let t: CGFloat = tally.program ? 11 : 5
            Rectangle().strokeBorder(tally.program ? Vyra.live : Vyra.ready, lineWidth: t).allowsHitTesting(false)
        }
    }
}

/// Image d'un masque binaire (blanc ou couleur là où la cellule est active).
private func maskImage(_ mask: AnalysisMask, rgba: (UInt8, UInt8, UInt8)) -> CGImage? {
    var px = [UInt8](repeating: 0, count: mask.width * mask.height * 4)
    for (i, cell) in mask.cells.enumerated() where cell != 0 {
        px[i * 4] = rgba.0; px[i * 4 + 1] = rgba.1; px[i * 4 + 2] = rgba.2; px[i * 4 + 3] = 255
    }
    guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
    return CGImage(width: mask.width, height: mask.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: mask.width * 4,
                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

/// Zebras : rayures diagonales nettes, découpées par le masque des zones surexposées.
struct ZebraOverlay: View {
    let mask: AnalysisMask?

    var body: some View {
        if let mask, mask.hasAny, let img = maskImage(mask, rgba: (255, 255, 255)) {
            Canvas { ctx, size in
                var x = -size.height
                while x < size.width + size.height {
                    var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    ctx.stroke(p, with: .color(.white), lineWidth: 5)
                    x += 16
                }
            }
            .mask(Image(decorative: img, scale: 1).resizable().interpolation(.none))
            .allowsHitTesting(false)
        }
    }
}

/// Focus peaking : contours nets surlignés en vert lime.
struct PeakingOverlay: View {
    let mask: AnalysisMask?

    var body: some View {
        if let mask, mask.hasAny, let img = maskImage(mask, rgba: (0xB6, 0xFF, 0x3A)) {
            Image(decorative: img, scale: 1).resizable().interpolation(.none).allowsHitTesting(false)
        }
    }
}

/// Histogramme de luminance avec alerte d'écrêtage aux deux extrémités.
struct HistogramOverlay: View {
    let histogram: LumaHistogram
    private static let clipAlert: Float = 0.02

    var body: some View {
        let burnt = histogram.clippedHigh > Self.clipAlert
        let crushed = histogram.clippedLow > Self.clipAlert
        VStack(spacing: 3) {
            HStack {
                Text("LUMINANCE").tracking(1.1).font(.system(size: 8, weight: .heavy)).foregroundColor(Vyra.muted)
                Spacer()
                Text(burnt ? "BRÛLÉ" : crushed ? "BOUCHÉ" : "OK").font(.system(size: 8, weight: .heavy))
                    .foregroundColor(burnt ? Vyra.live : crushed ? Vyra.accent : Vyra.ready)
            }
            Canvas { ctx, size in
                let bins = histogram.bins
                guard !bins.isEmpty else { return }
                let peak = CGFloat(max(histogram.max, 1))
                let bw = size.width / CGFloat(bins.count)
                for (i, count) in bins.enumerated() {
                    let h = CGFloat(count) / peak * size.height
                    let color: Color = i == 0 && crushed ? Vyra.accent : i == bins.count - 1 && burnt ? Vyra.live : .white.opacity(0.82)
                    ctx.fill(Path(CGRect(x: CGFloat(i) * bw, y: size.height - h, width: bw * 0.86, height: h)), with: .color(color))
                }
                for i in 1...3 {
                    let x = size.width * CGFloat(i) / 4
                    var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(p, with: .color(.white.opacity(0.14)), lineWidth: 0.5)
                }
            }
            .frame(height: 38)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(width: 156)
        .background(Vyra.hudBg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Vyra.hudLine))
    }
}

// MARK: - Niveau électronique « Double axe »

/// Lit la gravité (CoreMotion) et fournit roulis/tangage dans le repère de l'écran paysage.
/// N'écoute le capteur que si le niveau est affiché. Calibration persistée (trépied jamais d'aplomb).
final class LevelMotion: ObservableObject {
    @Published private(set) var roll: Float = 0
    @Published private(set) var pitch: Float = 0
    private let motion = CMMotionManager()
    private let defaults = UserDefaults.standard

    var calRoll: Float { defaults.float(forKey: "ndicam_level.roll") }
    var calPitch: Float { defaults.float(forKey: "ndicam_level.pitch") }
    var isCalibrated: Bool { defaults.object(forKey: "ndicam_level.roll") != nil }

    func setEnabled(_ on: Bool) {
        guard on else { motion.stopDeviceMotionUpdates(); return }
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let g = data?.gravity else { return }
            // Paysage, bouton/encoche à droite : droite écran = -y appareil, haut écran = +x appareil.
            let right = -g.y, up = g.x
            let r = Float(atan2(right, -up) * 180 / .pi)
            let p = Float(atan2(-g.z, hypot(right, up)) * 180 / .pi)
            // Passe-bas léger : la gravité est quasi constante, on lisse juste la mesure.
            self.roll += 0.18 * (r - self.roll)
            self.pitch += 0.18 * (p - self.pitch)
        }
    }

    func calibrate() {
        defaults.set(roll, forKey: "ndicam_level.roll")
        defaults.set(pitch, forKey: "ndicam_level.pitch")
        objectWillChange.send()
    }

    func reset() {
        defaults.removeObject(forKey: "ndicam_level.roll")
        defaults.removeObject(forKey: "ndicam_level.pitch")
        objectWillChange.send()
    }
}

struct LevelOverlay: View {
    let roll: Float
    let pitch: Float
    private static let threshold: Float = 1

    var body: some View {
        let rollLevel = abs(roll) <= Self.threshold
        let level = rollLevel && abs(pitch) <= Self.threshold
        let green = Color(argb: 0xFF35D08A)
        let color = level ? green : Color.white.opacity(0.85)
        Canvas { ctx, size in
            let cx = size.width / 2, cy = size.height / 2, ring: CGFloat = 108
            ctx.stroke(Path(ellipseIn: CGRect(x: cx - ring, y: cy - ring, width: ring * 2, height: ring * 2)), with: .color(.white.opacity(0.12)), lineWidth: 1)
            ctx.stroke(Path(ellipseIn: CGRect(x: cx - 30, y: cy - 30, width: 60, height: 60)), with: .color(.white.opacity(0.22)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 2, y: cy - 2, width: 4, height: 4)), with: .color(.white.opacity(0.45)))

            // Barre mobile : décalée en tangage (3 pt/°, bornée), pivotée en roulis.
            let by = cy + CGFloat(-min(max(pitch, -30), 30) * 3)
            var bar = ctx
            bar.translateBy(x: cx, y: by)
            bar.rotate(by: .degrees(Double(-roll)))
            func seg(_ a: CGPoint, _ b: CGPoint, _ c: Color, _ w: CGFloat, on g: GraphicsContext) {
                var p = Path(); p.move(to: a); p.addLine(to: b)
                g.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: w, lineCap: .round))
            }
            seg(CGPoint(x: -100, y: 0), CGPoint(x: 100, y: 0), color.opacity(0.25), 9, on: bar)
            seg(CGPoint(x: -100, y: 0), CGPoint(x: 100, y: 0), color, 4, on: bar)
            seg(CGPoint(x: 0, y: -9), CGPoint(x: 0, y: 9), color, 4, on: bar)

            // Deux ailes fixes au niveau de l'anneau : la barre s'y aligne quand c'est droit.
            let wing = rollLevel ? green : Color.white.opacity(0.35)
            seg(CGPoint(x: cx - ring, y: cy), CGPoint(x: cx - ring + 16, y: cy), wing, 3, on: ctx)
            seg(CGPoint(x: cx + ring - 16, y: cy), CGPoint(x: cx + ring, y: cy), wing, 3, on: ctx)
        }
        .allowsHitTesting(false)
    }
}
