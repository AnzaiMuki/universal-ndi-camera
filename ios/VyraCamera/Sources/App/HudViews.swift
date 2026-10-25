import SwiftUI

// Éléments du HUD posés sur l'image, repris de CameraScreen.kt (refonte « variante B ») : le texte
// se pose directement sur l'image, séparé par de fins filets, à la manière d'une caméra de production.

// MARK: - Haut-gauche : lecture d'exposition

struct ExposureReadouts: View {
    let c: CameraControls
    let fps: Int

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Readout(label: "Im/s", value: "\(fps)")
            ReadoutDivider()
            Readout(label: "Obtur.", value: c.autoExposure || c.exposureTimeNs == nil ? "AUTO" : shutterFromNs(c.exposureTimeNs!), auto: c.autoExposure)
            ReadoutDivider()
            Readout(label: "ISO", value: c.autoExposure ? "AUTO" : (c.iso.map(String.init) ?? "AUTO"), auto: c.autoExposure)
            ReadoutDivider()
            Readout(label: "WB", value: c.wbManual ? "\(c.wbKelvin)K" : awbLabel(c.awbMode), auto: !c.wbManual, accent: c.wbManual)
        }
    }
}

private struct Readout: View {
    let label: String
    let value: String
    var auto = false
    var accent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).tracking(1.2)
                .font(.system(size: 9, weight: .bold)).foregroundColor(Vyra.muted).readoutShadow()
            HStack(alignment: .top, spacing: 2) {
                Text(value).font(.mono(16)).foregroundColor(accent ? Vyra.accent : .white).readoutShadow()
                if auto {
                    Text("A").font(.system(size: 8, weight: .heavy)).foregroundColor(Vyra.accent).readoutShadow()
                }
            }
        }
        .padding(.horizontal, 10)
    }
}

private struct ReadoutDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.13)).frame(width: 1, height: 26).padding(.top, 2)
    }
}

// MARK: - Haut-centre : timecode du direct + état du lien

struct TimecodeStatus: View {
    let state: StreamManager.State
    let previewReady: Bool
    let paused: Bool
    let bridgeName: String?
    let usb: Bool
    let liveSince: Date?

    var body: some View {
        VStack(spacing: 0) {
            if state == .streaming {
                TimelineView(.periodic(from: liveSince ?? Date(), by: 1)) { ctx in
                    let seconds = max(Int(ctx.date.timeIntervalSince(liveSince ?? ctx.date)), 0)
                    Text(String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60))
                        .tracking(1).font(.mono(30)).foregroundColor(.white).readoutShadow()
                }
                let sub = paused ? ("SIGNAL COUPÉ", Vyra.amber) : ("EN DIRECT · NDI", Vyra.live)
                HStack(spacing: 6) {
                    Circle().fill(sub.1).frame(width: 7, height: 7)
                    Text(sub.0).tracking(1.6).font(.system(size: 10, weight: .bold)).foregroundColor(sub.1).readoutShadow()
                }
                .padding(.top, 5)
            } else {
                Text(label).tracking(1.4).font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.92)).readoutShadow()
            }
        }
    }

    private var label: String {
        switch state {
        case .connecting: return usb && bridgeName == nil ? "ATTENTE DU CÂBLE…" : "CONNEXION…"
        case .failed: return "HORS LIGNE"
        default:
            if !previewReady { return "DÉMARRAGE…" }
            if usb { return "MODE CÂBLE USB" }
            return bridgeName != nil ? "PONT TROUVÉ" : "RECHERCHE DU PONT…"
        }
    }
}

// MARK: - Haut-droite : format, thermique, batterie

struct TopRightCluster: View {
    let thermal: ThermalLevel
    let battery: Int
    let charging: Bool
    let resolutionLabel: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ClusterItem(label: "Format", value: resolutionLabel)
            if let t = thermalText {
                ClusterItem(label: "Thermique", value: t, color: thermal == .critical ? Vyra.live : Vyra.amber)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(charging ? "BATTERIE ⚡" : "BATTERIE").tracking(1.2)
                    .font(.system(size: 9, weight: .bold)).foregroundColor(Vyra.muted).readoutShadow()
                HStack(spacing: 5) {
                    BatteryGlyph(percent: battery)
                    Text((0...100).contains(battery) ? "\(battery)%" : "—").font(.mono(14)).foregroundColor(.white).readoutShadow()
                }
            }
        }
    }

    private var thermalText: String? {
        switch thermal {
        case .warm: return "Tiède"
        case .hot: return "Chaud"
        case .critical: return "Surchauffe"
        default: return nil
        }
    }
}

private struct ClusterItem: View {
    let label: String
    let value: String
    var color: Color = .white

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label.uppercased()).tracking(1.2)
                .font(.system(size: 9, weight: .bold)).foregroundColor(Vyra.muted).readoutShadow()
            Text(value).font(.mono(14)).foregroundColor(color).readoutShadow()
        }
    }
}

private struct BatteryGlyph: View {
    let percent: Int
    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(.white.opacity(0.5)), lineWidth: 1)
            guard (0...100).contains(percent) else { return }
            // Sous 15 %, l'ambre : une batterie qui lâche coupe le direct.
            let fill = percent <= 15 ? Vyra.amber : Vyra.ready
            let inner = CGRect(x: 2, y: 2, width: (size.width - 4) * CGFloat(percent) / 100, height: size.height - 4)
            ctx.fill(Path(roundedRect: inner, cornerRadius: 0.75), with: .color(fill))
        }
        .frame(width: 20, height: 10)
    }
}

// MARK: - Rail d'outils (droite)

enum Tool { case exposure, whiteBalance, focus, guides }
enum Glyph { case focus, camera, exposure, wb, grid, settings }

struct Toolbar: View {
    let live: Bool
    let selected: Tool?
    let onSelect: (Tool) -> Void
    let onCamera: () -> Void
    let onLive: () -> Void
    let onSettings: () -> Void

    var body: some View {
        // 3 icônes au-dessus / 3 en dessous : le bouton rouge tombe pile au centre du rail.
        VStack(spacing: 5) {
            ToolButton(glyph: .focus, active: selected == .focus) { onSelect(.focus) }
            ToolButton(glyph: .camera, active: selected == nil, action: onCamera)
            ToolButton(glyph: .exposure, active: selected == .exposure) { onSelect(.exposure) }
            LiveButton(live: live, action: onLive)
            ToolButton(glyph: .wb, active: selected == .whiteBalance) { onSelect(.whiteBalance) }
            ToolButton(glyph: .grid, active: selected == .guides) { onSelect(.guides) }
            ToolButton(glyph: .settings, active: false, action: onSettings)
        }
        .padding(6)
        .background(Color(argb: 0x8C0A0D10), in: RoundedRectangle(cornerRadius: 19))
        .overlay(RoundedRectangle(cornerRadius: 19).stroke(Vyra.hudLine))
        .padding(8)
    }
}

private struct ToolButton: View {
    let glyph: Glyph
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if glyph == .settings {
                    Image(systemName: "gearshape.fill").font(.system(size: 18)).foregroundColor(.white)
                } else {
                    GlyphView(glyph: glyph).frame(width: 20, height: 20)
                }
            }
            .frame(width: 38, height: 38)
            .background(active ? Vyra.accent : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(glyph == .settings ? "settings" : "tool-\(glyph)")
    }
}

struct LiveButton: View {
    let live: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color(argb: 0xFF151A1F))
                Circle().stroke(Color.white.opacity(0.85), lineWidth: 3)
                // Carré = couper (en direct) ; pastille ronde = passer en direct.
                RoundedRectangle(cornerRadius: live ? 3 : 11).fill(Vyra.live)
                    .frame(width: live ? 18 : 22, height: live ? 18 : 22)
            }
            .frame(width: 50, height: 50)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("live")
        .accessibilityLabel(live ? "Couper le direct" : "Passer en direct")
    }
}

/// Petits pictos dessinés, identiques à drawGlyph côté Android.
struct GlyphView: View {
    let glyph: Glyph
    var color: Color = .white

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let s = StrokeStyle(lineWidth: w * 0.09, lineCap: .round)
            func line(_ a: CGPoint, _ b: CGPoint, _ width: CGFloat? = nil) {
                var p = Path(); p.move(to: a); p.addLine(to: b)
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width ?? s.lineWidth, lineCap: .round))
            }
            switch glyph {
            case .focus:
                let m = w * 0.12, len = w * 0.22
                func corner(_ cx: CGFloat, _ cy: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
                    line(CGPoint(x: cx, y: cy), CGPoint(x: cx + dx, y: cy))
                    line(CGPoint(x: cx, y: cy), CGPoint(x: cx, y: cy + dy))
                }
                corner(m, m, len, len); corner(w - m, m, -len, len)
                corner(m, h - m, len, -len); corner(w - m, h - m, -len, -len)
                ctx.fill(Path(ellipseIn: CGRect(x: w / 2 - w * 0.11, y: h / 2 - w * 0.11, width: w * 0.22, height: w * 0.22)), with: .color(color))
            case .camera:
                ctx.stroke(Path(roundedRect: CGRect(x: w * 0.14, y: h * 0.28, width: w * 0.5, height: h * 0.44), cornerRadius: w * 0.08),
                           with: .color(color), style: s)
                var p = Path()
                p.move(to: CGPoint(x: w * 0.68, y: h * 0.4)); p.addLine(to: CGPoint(x: w * 0.86, y: h * 0.3))
                p.addLine(to: CGPoint(x: w * 0.86, y: h * 0.7)); p.addLine(to: CGPoint(x: w * 0.68, y: h * 0.6)); p.closeSubpath()
                ctx.stroke(p, with: .color(color), style: s)
            case .exposure:
                let r = w * 0.34, c = CGPoint(x: w / 2, y: h / 2)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color), style: s)
                var half = Path()
                half.move(to: c)
                half.addArc(center: c, radius: r, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
                half.closeSubpath()
                ctx.fill(half, with: .color(color))
            case .wb:
                let c = CGPoint(x: w / 2, y: h / 2), r = w * 0.16
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color), style: s)
                for i in 0..<8 {
                    let a = Double(i) * .pi / 4
                    let (co, si) = (CGFloat(cos(a)), CGFloat(sin(a)))
                    line(CGPoint(x: c.x + r * 1.5 * co, y: c.y + r * 1.5 * si), CGPoint(x: c.x + r * 2.2 * co, y: c.y + r * 2.2 * si))
                }
            case .grid:
                let m = w * 0.13, side = w - m * 2
                ctx.stroke(Path(roundedRect: CGRect(x: m, y: m, width: side, height: side), cornerRadius: w * 0.08), with: .color(color), style: s)
                for i in 1...2 {
                    let o = m + side * CGFloat(i) / 3
                    line(CGPoint(x: o, y: m), CGPoint(x: o, y: m + side), s.lineWidth * 0.8)
                    line(CGPoint(x: m, y: o), CGPoint(x: m + side, y: o), s.lineWidth * 0.8)
                }
            case .settings:
                break
            }
        }
    }
}

// MARK: - Bas-centre : ligne d'état, zoom en arc, messagerie

/// Tally, pont, débit. Hors direct et hors tally, la ligne s'efface.
struct StreamStatusLine: View {
    let streaming: Bool
    let tally: TallyState
    let paused: Bool
    let bridgeName: String?
    let throughputBps: Int

    var body: some View {
        if streaming || tally.program || tally.preview {
            HStack(spacing: 8) {
                let t: (String, Color)? = paused ? ("SIGNAL COUPÉ", Vyra.amber)
                    : tally.program ? ("À L'ANTENNE", Vyra.live)
                    : tally.preview ? ("PRÊT", Vyra.ready) : nil
                if let t {
                    HStack(spacing: 5) {
                        Circle().fill(t.1).frame(width: 7, height: 7)
                        Text(t.0).tracking(1).font(.system(size: 11, weight: .heavy)).foregroundColor(t.1).readoutShadow()
                    }
                }
                if let bridgeName, streaming {
                    if t != nil { separator }
                    Text("Pont \(bridgeName)").font(.mono(10, .medium)).foregroundColor(Vyra.ready.opacity(0.9)).readoutShadow()
                }
                if streaming {
                    if t != nil || bridgeName != nil { separator }
                    Text(String(format: "%.1f Mb/s", Double(throughputBps) / 1_000_000))
                        .font(.mono(10, .bold)).foregroundColor(.white.opacity(0.85)).readoutShadow()
                }
            }
            .fixedSize()
        }
    }

    private var separator: some View {
        Text("·").font(.system(size: 11)).foregroundColor(.white.opacity(0.3)).readoutShadow()
    }
}

/// Icône Messages au centre, facteurs de zoom en arc (dôme) autour, ligne d'état au-dessus.
struct BottomCluster<Status: View>: View {
    let dim: Bool
    let status: Status
    let presets: [Float]
    let currentZoom: Float
    let onZoom: (Float) -> Void
    let onToggleMsg: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            status.opacity(dim ? 0.15 : 1)
                .frame(maxHeight: .infinity, alignment: .top)

            // Facteurs répartis en arc (~130°) autour du centre de l'icône.
            let fabR = 25.0, chipR = 17.0, radius = 76.0, span = 130.0
            ForEach(Array(presets.enumerated()), id: \.offset) { i, z in
                let theta = presets.count <= 1 ? 0 : -span / 2 + Double(i) * span / Double(presets.count - 1)
                let rad = theta * .pi / 180
                ZoomChip(zoom: z, active: abs(currentZoom - z) < z * 0.06) { onZoom(z) }
                    .offset(x: radius * sin(rad), y: chipR - (fabR + radius * cos(rad)))
                    .opacity(dim ? 0.12 : 1)
            }

            MessagesFab(open: dim, action: onToggleMsg)
        }
        .frame(width: 210, height: 150)
    }
}

private struct ZoomChip: View {
    let zoom: Float
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(zoomLabel(zoom)).font(.mono(12, .bold)).foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(active ? Vyra.accent.opacity(0.9) : Color.black.opacity(0.42), in: Circle())
                .overlay(Circle().stroke(active ? Color.clear : Color.white.opacity(0.28)))
        }
        .buttonStyle(.plain)
    }
}

/// Icône Messages : même diamètre que le bouton Live. Bleue (fermée) ou grise (ouverte = « fermer »).
private struct MessagesFab: View {
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(RadialGradient(
                    colors: open ? [Color(argb: 0xFF3B4757), Color(argb: 0xFF212B36)]
                                 : [Color(argb: 0xFF57B4FF), Vyra.accent, Color(argb: 0xFF1462BE)],
                    center: .center, startRadius: 0, endRadius: 25))
                Circle().stroke(Color.white.opacity(0.25))
                MessageBubble(color: open ? Color(argb: 0xFFC7D2DD) : .white).frame(width: 24, height: 24)
            }
            .frame(width: 50, height: 50)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("messages")
        .accessibilityLabel("Messages")
    }
}

/// Bulle de dialogue + ergot + 3 points (signe universel du chat).
private struct MessageBubble: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            ctx.fill(Path(roundedRect: CGRect(x: w * 0.08, y: h * 0.14, width: w * 0.84, height: h * 0.56), cornerRadius: w * 0.17), with: .color(color))
            var tail = Path()
            tail.move(to: CGPoint(x: w * 0.28, y: h * 0.66)); tail.addLine(to: CGPoint(x: w * 0.14, y: h * 0.9))
            tail.addLine(to: CGPoint(x: w * 0.46, y: h * 0.7)); tail.closeSubpath()
            ctx.fill(tail, with: .color(color))
            let r = w * 0.058, dy = h * 0.42
            for x in [0.35, 0.5, 0.65] {
                ctx.fill(Path(ellipseIn: CGRect(x: w * x - r, y: dy - r, width: r * 2, height: r * 2)), with: .color(Color(argb: 0xFF1668C9)))
            }
        }
    }
}

/// Barre de messagerie déployée : réponses rapides + « Besoin de la régie » + message libre.
struct MessagingPanel: View {
    let onReply: (String, Bool) -> Void
    @State private var text = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                ReplyChip(label: "Prêt", alert: false) { onReply("Prêt", false) }
                ReplyChip(label: "Attendez", alert: false) { onReply("Attendez", false) }
                ReplyChip(label: "Compris ✓", alert: false) { onReply("Compris ✓", false) }
            }
            ReplyChip(label: "✋ Besoin de la régie", alert: true) { onReply("Besoin de la régie", true) }
            HStack(spacing: 7) {
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text("Message personnalisé…").font(.system(size: 14)).foregroundColor(.white.opacity(0.4))
                    }
                    TextField("", text: $text)
                        .font(.system(size: 14)).foregroundColor(.white).accentColor(Vyra.accent)
                        .submitLabel(.send).onSubmit(sendFree)
                        .onChange(of: text) { t in if t.count > Reply.maxLen { text = String(t.prefix(Reply.maxLen)) } }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.18)))
                Button(action: sendFree) {
                    Text("Envoyer").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Vyra.accent, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(maxWidth: 460)
        .background(Color(argb: 0xE6070B10), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.15)))
    }

    private func sendFree() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { onReply(t, false); text = "" }
    }
}

private struct ReplyChip: View {
    let label: String
    let alert: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                .frame(maxWidth: .infinity).padding(.vertical, 9).padding(.horizontal, 8)
                .background(alert ? Vyra.live : Color.white.opacity(0.10), in: Capsule())
                .overlay(Capsule().stroke(alert ? Color.clear : Color.white.opacity(0.22)))
        }
        .buttonStyle(.plain)
    }
}

/// Accusé de lecture : « envoyé » (blanc) puis « Vu par la régie ✓✓ » (vert).
struct ReplyStatusPill: View {
    let status: ReplyStatus
    private let green = Color(argb: 0xFF34C759)

    var body: some View {
        HStack(spacing: 7) {
            Text("« \(status.text) »").font(.system(size: 11, weight: .semibold)).foregroundColor(.white).lineLimit(1)
            Text(status.seen ? "Vu par la régie ✓✓" : "envoyé").font(.system(size: 11, weight: .bold))
                .foregroundColor(status.seen ? green : .white.opacity(0.75))
        }
        .padding(.horizontal, 13).padding(.vertical, 6)
        .background(status.seen ? Color(argb: 0xCC0D1A12) : Color(argb: 0xB3000000), in: Capsule())
        .overlay(Capsule().stroke(status.seen ? green.opacity(0.5) : Color.white.opacity(0.18)))
    }
}

// MARK: - Consigne de la régie

/// Bannière TRANSLUCIDE : le vidéaste continue de voir l'image. Bleu = normale, rouge = urgente.
struct CueBanner: View {
    let cue: Cue
    let onAck: () -> Void

    var body: some View {
        let color = cue.urgent ? Vyra.live : Vyra.accent
        HStack(spacing: 12) {
            Text(cue.text.uppercased()).tracking(0.5).font(.system(size: 17, weight: .heavy)).foregroundColor(.white)
                .shadow(color: .black.opacity(0.7), radius: 2.5)
            Button(action: onAck) {
                Text("✓ Compris").font(.system(size: 13, weight: .heavy)).foregroundColor(color)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 20).padding(.trailing, 8).padding(.vertical, 8)
        .background(color.opacity(0.34), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.85), lineWidth: 1.5))
    }
}

// MARK: - Bas-droite : vumètre audio

/// Échelle dBFS (-45 à +3), dégradé vert → ambre → rouge. Un appui coupe ou remet le micro.
struct AudioMeter: View {
    let level: Float
    let failure: String?
    let micEnabled: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            VStack(spacing: 5) {
                HStack {
                    Text("AUDIO").tracking(1).font(.system(size: 9, weight: .bold)).foregroundColor(micEnabled ? .white : Vyra.muted)
                    Spacer()
                    Text(failure != nil ? "!" : (!micEnabled ? "MUET" : "48 kHz")).tracking(0.8)
                        .font(.system(size: 8, weight: .bold)).foregroundColor(failure != nil ? Vyra.live : Vyra.muted)
                }
                if let failure {
                    Text(failure).font(.system(size: 9, weight: .medium)).foregroundColor(Vyra.live)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(argb: 0x33FFFFFF))
                            LinearGradient(stops: [.init(color: Vyra.ready, location: 0), .init(color: Vyra.ready, location: 0.62),
                                                   .init(color: Vyra.amber, location: 0.82), .init(color: Vyra.live, location: 1)],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: g.size.width)
                                .mask(alignment: .leading) {
                                    Capsule().frame(width: g.size.width * CGFloat(micEnabled ? level : 0))
                                }
                                .animation(.linear(duration: 0.09), value: level)
                        }
                    }
                    .frame(height: 6)
                    HStack {
                        ForEach(["-45", "-20", "-6", "0", "+3"], id: \.self) { t in
                            Text(t).font(.mono(7, .regular)).foregroundColor(Vyra.muted)
                            if t != "+3" { Spacer() }
                        }
                    }
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(width: 172)
            .background(Vyra.hudBg, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Vyra.hudLine))
        }
        .buttonStyle(.plain)
    }
}
