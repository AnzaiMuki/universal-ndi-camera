import SwiftUI

// Volet d'outils du bas (exposition, balance des blancs, point, repères), repris de CameraScreen.kt.
// Valeurs normalisées : un opérateur raisonne en crans, pas en nombres continus.

private let isoStops = [50, 100, 200, 400, 800, 1600, 3200, 6400]
private let shutterDenoms: [Int64] = [24, 30, 48, 50, 60, 100, 120, 250, 500, 1000, 2000]
private let kelvinPresets = [(2800, "Tungstène"), (3200, "Halogène"), (4300, "Fluo"), (5600, "Jour"), (6500, "Nuageux"), (7500, "Ombre")]
private let kelvinMin = 2300, kelvinMax = 7500

// MARK: - Briques

/// Rampe de précision : rail fin, graduations, curseur barre (un instrument, pas un curseur grand public).
struct PrecisionRamp: View {
    let position: Float
    let ticks: Int
    var bipolar = false
    let onChange: (Float) -> Void

    var body: some View {
        GeometryReader { g in
            Canvas { ctx, size in
                let cy = size.height / 2
                func line(_ a: CGPoint, _ b: CGPoint, _ c: Color, _ w: CGFloat) {
                    var p = Path(); p.move(to: a); p.addLine(to: b)
                    ctx.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: w, lineCap: .round))
                }
                line(CGPoint(x: 0, y: cy), CGPoint(x: size.width, y: cy), .white.opacity(0.20), 2)
                if ticks > 1 {
                    for i in 0..<ticks {
                        let x = size.width * CGFloat(i) / CGFloat(ticks - 1)
                        line(CGPoint(x: x, y: cy - 4.5), CGPoint(x: x, y: cy + 4.5), .white.opacity(0.28), 1)
                    }
                }
                let px = size.width * CGFloat(min(max(position, 0), 1))
                // Valeur bipolaire (±EV) : le remplissage part du cran neutre, pas du bord.
                let from = bipolar ? size.width / 2 : 0
                if px != from { line(CGPoint(x: from, y: cy), CGPoint(x: px, y: cy), Vyra.accent, 2) }
                line(CGPoint(x: px, y: cy - 10), CGPoint(x: px, y: cy + 10), .white, 3)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                onChange(Float(min(max(v.location.x / max(g.size.width, 1), 0), 1)))
            })
        }
        .frame(height: 30)
    }
}

struct RampRow: View {
    let label: String
    let value: String
    let position: Float
    let ticks: Int
    var bipolar = false
    let onChange: (Float) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                Text(label).tracking(1).font(.system(size: 9, weight: .bold)).foregroundColor(Vyra.muted)
                Spacer()
                Text(value).font(.mono(14)).foregroundColor(.white)
            }
            PrecisionRamp(position: position, ticks: ticks, bipolar: bipolar, onChange: onChange)
        }
    }
}

struct ValueChip: View {
    let text: String
    let active: Bool
    var mono = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text).font(mono ? .mono(12) : .system(size: 12, weight: .semibold))
                .foregroundColor(active ? .white : Vyra.chipText).lineLimit(1)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(active ? Vyra.accent : Color(argb: 0x14FFFFFF), in: Capsule())
                .overlay(Capsule().stroke(active ? Color.clear : Vyra.hudLine))
        }
        .buttonStyle(.plain)
    }
}

struct ChipRow<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) { content } }
    }
}

struct PanelTitle: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 14, weight: .bold)).foregroundColor(.white) }
}

struct Hint: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundColor(Vyra.muted).frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct Segmented: View {
    let left: String
    let right: String
    let leftActive: Bool
    let onLeft: () -> Void
    let onRight: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            seg(left, leftActive, onLeft)
            seg(right, !leftActive, onRight)
        }
        .padding(3)
        .background(Color(argb: 0x1FFFFFFF), in: RoundedRectangle(cornerRadius: 10))
    }

    private func seg(_ text: String, _ active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundColor(active ? .white : Vyra.muted)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(active ? Vyra.accent : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Volet

struct ControlPanel: View {
    @EnvironmentObject private var m: StreamManager
    let tool: Tool
    @Binding var guideMask: Guide
    @ObservedObject var level: LevelMotion
    @Binding var levelOn: Bool
    @Binding var histogramOn: Bool
    @Binding var zebraPercent: Int?
    @Binding var peakingOn: Bool
    let onContinuousFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch tool {
            case .exposure: ExposurePanel(histogramOn: $histogramOn, zebraPercent: $zebraPercent)
            case .whiteBalance: WhiteBalancePanel()
            case .focus: FocusPanel(peakingOn: $peakingOn, onContinuous: onContinuousFocus)
            case .guides: GuidesPanel(mask: $guideMask, level: level, levelOn: $levelOn)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Vyra.hudBg, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Vyra.hudLine))
        .contentShape(Rectangle())
        .onTapGesture {}   // absorbe les appuis : ils ne doivent pas déplacer la mise au point
        // Marge droite calée sur le rail : le volet ne passe jamais dessous.
        .padding(.leading, 18).padding(.trailing, 88).padding(.vertical, 8)
    }
}

private struct ExposurePanel: View {
    @EnvironmentObject private var m: StreamManager
    @Binding var histogramOn: Bool
    @Binding var zebraPercent: Int?
    @State private var isoTab = true

    var body: some View {
        let c = m.controls, caps = m.caps
        HStack {
            PanelTitle(text: "Exposition")
            Spacer()
            HStack(spacing: 6) {
                // Torche : n'apparaît que si l'objectif a un éclairage (une option absente est une décision).
                if caps.hasFlash {
                    ValueChip(text: "Torche", active: c.torch, mono: false) { m.setControls(with(c) { $0.torch.toggle() }) }
                }
                ValueChip(text: "Histo.", active: histogramOn, mono: false) { histogramOn.toggle() }
                // 70 % = carnations, 95 % = juste avant l'écrêtage. Le seuil actif, retouché, coupe les zebras.
                ForEach(ExposureAnalysis.thresholds, id: \.self) { p in
                    ValueChip(text: "\(p)%", active: zebraPercent == p) { zebraPercent = zebraPercent == p ? nil : p }
                }
            }
            Spacer()
            if caps.manualSensor {
                Segmented(left: "Auto", right: "Manuel", leftActive: c.autoExposure,
                          onLeft: { m.setControls(with(c) { $0.autoExposure = true }) },
                          onRight: {
                              // Valeurs explicites dès le passage en manuel (règle des 180° pour l'obturation).
                              let def180 = Int64(1_000_000_000 / (m.fps * 2))
                              m.setControls(with(c) {
                                  $0.autoExposure = false
                                  $0.iso = $0.iso ?? caps.isoRange.map { 400.clamped($0.lowerBound, $0.upperBound) }
                                  $0.exposureTimeNs = $0.exposureTimeNs ?? caps.exposureTimeRange.map { def180.clamped($0.lowerBound, $0.upperBound) } ?? def180
                              })
                          })
            }
        }

        if c.autoExposure {
            if caps.supportsExposureCompensation {
                let r = caps.aeCompRange
                let span = Float(r.upperBound - r.lowerBound)
                RampRow(label: "COMPENSATION", value: String(format: "%+.1f EV", Float(c.aeCompensation) * caps.aeCompStep),
                        position: Float(c.aeCompensation - r.lowerBound) / span, ticks: 13, bipolar: true) { p in
                    m.setControls(with(c) { $0.aeCompensation = r.lowerBound + Int((p * span).rounded()) })
                }
            } else {
                Hint(text: "Exposition automatique. Ce capteur n'expose pas de compensation.")
            }
            Hint(text: "Touchez l'image pour recentrer la mesure sur un sujet.")
        } else {
            Segmented(left: "ISO", right: "Obturation", leftActive: isoTab, onLeft: { isoTab = true }, onRight: { isoTab = false })
            if isoTab { isoControls(c, caps) } else { shutterControls(c, caps) }
        }
    }

    @ViewBuilder private func isoControls(_ c: CameraControls, _ caps: CameraCapabilities) -> some View {
        if let range = caps.isoRange {
            let lo = max(range.lowerBound, 1), hi = max(range.upperBound, lo + 1)
            let current = (c.iso ?? 400).clamped(lo, hi)
            ChipRow {
                ForEach(isoStops.filter { (lo...hi).contains($0) }, id: \.self) { stop in
                    ValueChip(text: "\(stop)", active: current == stop) { m.setControls(with(c) { $0.iso = stop }) }
                }
            }
            // Échelle logarithmique : un cran de curseur = un cran d'exposition.
            let pos = Float(log(Double(current) / Double(lo)) / log(Double(hi) / Double(lo)))
            RampRow(label: "SENSIBILITÉ", value: "ISO \(current)", position: pos, ticks: 9) { p in
                let v = Int((Double(lo) * pow(Double(hi) / Double(lo), Double(p))).rounded()).clamped(lo, hi)
                m.setControls(with(c) { $0.iso = v })
            }
        } else {
            Hint(text: "Sensibilité manuelle indisponible sur ce capteur.")
        }
    }

    @ViewBuilder private func shutterControls(_ c: CameraControls, _ caps: CameraCapabilities) -> some View {
        if let range = caps.exposureTimeRange {
            let steps = shutterDenoms.map { 1_000_000_000 / $0 }.filter { range.contains($0) }
            if steps.isEmpty {
                Hint(text: "Aucune vitesse standard dans la plage du capteur.")
            } else {
                let target = Int64(1_000_000_000 / (m.fps * 2))
                let current = c.exposureTimeNs ?? steps.min { abs($0 - target) < abs($1 - target) }!
                let index = max(steps.firstIndex { $0 <= current } ?? 0, 0)
                ChipRow {
                    ForEach(steps, id: \.self) { ns in
                        ValueChip(text: shutterFromNs(ns), active: ns == current) { m.setControls(with(c) { $0.exposureTimeNs = ns }) }
                    }
                }
                // Règle des 180 degrés : le flou de mouvement naturel en vidéo.
                RampRow(label: "OBTURATION · 180° = 1/\(m.fps * 2)", value: shutterFromNs(current),
                        position: steps.count > 1 ? Float(index) / Float(steps.count - 1) : 0, ticks: steps.count) { p in
                    m.setControls(with(c) { $0.exposureTimeNs = steps[Int((p * Float(steps.count - 1)).rounded())] })
                }
            }
        } else {
            Hint(text: "Obturation manuelle indisponible sur ce capteur.")
        }
    }
}

private struct WhiteBalancePanel: View {
    @EnvironmentObject private var m: StreamManager

    var body: some View {
        let c = m.controls
        HStack {
            PanelTitle(text: "Balance des blancs")
            Spacer()
            if m.caps.manualWhiteBalance {
                Segmented(left: "Presets", right: "Kelvin", leftActive: !c.wbManual,
                          onLeft: { m.setControls(with(c) { $0.wbManual = false }) },
                          onRight: { m.setControls(with(c) { $0.wbManual = true }) })
            }
        }
        if c.wbManual {
            ChipRow {
                ForEach(kelvinPresets, id: \.0) { k, label in
                    ValueChip(text: label, active: c.wbKelvin == k, mono: false) { m.setControls(with(c) { $0.wbKelvin = k }) }
                }
            }
            let span = Float(kelvinMax - kelvinMin)
            RampRow(label: "TEMPÉRATURE", value: "\(c.wbKelvin) K", position: Float(c.wbKelvin - kelvinMin) / span, ticks: 11) { p in
                let k = (Int((Float(kelvinMin) + p * span).rounded()) / 50) * 50
                m.setControls(with(c) { $0.wbKelvin = k.clamped(kelvinMin, kelvinMax) })
            }
        } else {
            ChipRow {
                ForEach(m.caps.awbModes, id: \.self) { mode in
                    ValueChip(text: awbLabel(mode), active: c.awbMode == mode, mono: false) { m.setControls(with(c) { $0.awbMode = mode }) }
                }
            }
            Hint(text: "Touchez l'image pour recentrer la balance sur un sujet.")
        }
    }
}

private struct FocusPanel: View {
    @EnvironmentObject private var m: StreamManager
    @Binding var peakingOn: Bool
    let onContinuous: () -> Void

    var body: some View {
        let c = m.controls, manual = m.caps.supportsManualFocus
        HStack {
            PanelTitle(text: "Mise au point")
            Spacer()
            if manual {
                Segmented(left: "Auto", right: "Manuel", leftActive: c.autoFocus,
                          onLeft: onContinuous, onRight: { m.setControls(with(c) { $0.autoFocus = false }) })
            }
        }
        if !c.autoFocus && manual {
            RampRow(label: "DISTANCE", value: focusLabel(c.focusPosition), position: c.focusPosition, ticks: 9) { p in
                m.setControls(with(c) { $0.focusPosition = p })
            }
        } else if !manual {
            Hint(text: "Autofocus continu. Ce capteur ne permet pas le point manuel.")
        } else {
            Hint(text: "Autofocus continu. Touchez l'image pour verrouiller le point sur un sujet ; « Auto » relance le suivi.")
        }
        ChipRow { ValueChip(text: "Peaking", active: peakingOn, mono: false) { peakingOn.toggle() } }
        Hint(text: "Surligne les contours nets en vert. Repère local, absent du flux diffusé.")
    }
}

private struct GuidesPanel: View {
    @Binding var mask: Guide
    @ObservedObject var level: LevelMotion
    @Binding var levelOn: Bool

    var body: some View {
        PanelTitle(text: "Repères de cadrage")
        ChipRow {
            ForEach(Guide.all, id: \.0.rawValue) { g, label in
                ValueChip(text: label, active: mask.contains(g), mono: false) { mask.formSymmetricDifference(g) }
            }
            ValueChip(text: "Niveau", active: levelOn, mono: false) { levelOn.toggle() }
        }
        if levelOn {
            ChipRow {
                ValueChip(text: "Calibrer", active: false, mono: false) { level.calibrate() }
                if level.isCalibrated { ValueChip(text: "Réinitialiser", active: false, mono: false) { level.reset() } }
            }
            Hint(text: level.isCalibrated ? "Niveau calibré sur ta position de référence."
                 : "« Calibrer » fixe la position tenue comme zéro (utile sur trépied ou pour un angle voulu).")
        } else {
            Hint(text: "Affichage local uniquement : jamais incrustés dans le flux NDI.")
        }
    }
}
