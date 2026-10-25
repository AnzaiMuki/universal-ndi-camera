import SwiftUI
import AVFoundation

// Écrans d'entrée, repris de MainActivity.kt / VyraSplash.kt : morph du logo, acceptation du CLUF au
// premier lancement, puis autorisation caméra (le micro est demandé avec, mais son refus n'empêche rien).

// MARK: - Lancement animé

/// Morph du logo VYRA (tuile + barre laiton + point graphite) vers le lockup « VYRA Camera ».
struct VyraSplash: View {
    let onDone: () -> Void
    @State private var start = Date()

    private static let duration = 1.3
    private let bg = Color(argb: 0xFF0E1318)
    private let frame = Color(argb: 0xFFE8EDF1)
    private let tile = Color.white
    private let brass = Color(argb: 0xFFA67C52)
    private let graphite = Color(argb: 0xFF2E3A44)
    private let ink2 = Color(argb: 0xFF9AA5B1)

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = Float(min(timeline.date.timeIntervalSince(start) / Self.duration, 1))
            Canvas { ctx, size in draw(&ctx, size, t) }
        }
        .background(bg)
        .ignoresSafeArea()
        .onAppear {
            start = Date()
            // Bref maintien du lockup final avant de révéler la caméra.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration + 0.26, execute: onDone)
        }
    }

    private func seg(_ t: Float, _ a: Float, _ b: Float) -> Float { b <= a ? 0 : min(max((t - a) / (b - a), 0), 1) }
    private func ease(_ x: Float) -> Float { x * x * (3 - 2 * x) }
    private func lerp(_ a: Float, _ b: Float, _ x: Float) -> Float { a + (b - a) * x }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Float) {
        let cy = size.height / 2
        let logoSide = min(max(size.height * 0.30, 56), 150)
        let appear = ease(seg(t, 0, 0.12))
        let markScale: Float = t < 0.12 ? lerp(0.5, 1.18, ease(seg(t, 0, 0.12))) : t < 0.52 ? 1.18 : lerp(1.18, 1, ease(seg(t, 0.52, 1)))
        let barGrow = ease(seg(t, 0.08, 0.26))
        let dotScale = ease(seg(t, 0.12, 0.26))
        let fly: Float = t < 0.35 ? 0 : t < 0.60 ? ease(seg(t, 0.35, 0.60)) : t < 0.85 ? 1 - ease(seg(t, 0.60, 0.85)) : 0
        let wordReveal = ease(seg(t, 0.58, 1))

        let vyra = ctx.resolve(Text("VYRA").font(.system(size: logoSide * 0.42, weight: .heavy)).foregroundColor(.white))
        let cam = ctx.resolve(Text("CAMERA").font(.system(size: logoSide * 0.17, weight: .semibold)).tracking(3).foregroundColor(ink2))
        let vs = vyra.measure(in: size), cs = cam.measure(in: size)
        let wordW = max(vs.width, cs.width)
        let gap = logoSide * 0.22

        let logoW = logoSide * CGFloat(markScale)
        let shownWordW = wordW * CGFloat(wordReveal)
        let totalW = logoW + (wordReveal > 0 ? gap + shownWordW : 0)
        let left = (size.width - totalW) / 2
        let logoCx = left + logoW / 2
        let wordLeft = left + logoW + gap

        let s = logoW, lx = logoCx - s / 2, ly = cy - s / 2
        func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ c: Color) {
            ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r), with: .color(c.opacity(Double(appear))))
        }
        if appear > 0 {
            rr(lx + s * 0.13, ly + s * 0.13, s * 0.74, s * 0.74, s * 0.225, frame)
            rr(lx + s * 0.225, ly + s * 0.225, s * 0.55, s * 0.55, s * 0.16, tile)
            let barW = s * 0.117, barH = s * 0.333 * CGFloat(barGrow)
            rr(lx + s * 0.39, ly + s * 0.667 - barH, barW, barH, barW / 2, brass)
            let dotW = s * 0.117, dotH = s * 0.20
            let ds = CGFloat(dotScale * (1 - 0.18 * fly))
            let dw = dotW * ds, dh = dotH * ds
            let dcx = lx + s * 0.55 + dotW / 2 + s * 2.6 * CGFloat(fly)
            let dcy = ly + s * 0.467 + dotH / 2 - s * 0.5 * CGFloat(fly)
            rr(dcx - dw / 2, dcy - dh / 2, dw, dh, dw / 2, graphite)
        }
        if wordReveal > 0 {
            let blockH = vs.height + cs.height * 1.05
            let topV = cy - blockH / 2
            var word = ctx
            word.clip(to: Path(CGRect(x: wordLeft, y: 0, width: shownWordW + 2, height: size.height)))
            word.opacity = Double(wordReveal)
            word.draw(vyra, at: CGPoint(x: wordLeft, y: topV), anchor: .topLeading)
            word.draw(cam, at: CGPoint(x: wordLeft, y: topV + vs.height * 1.02), anchor: .topLeading)
        }
    }
}

// MARK: - CLUF

/// Acceptation du contrat AVANT tout usage, au premier lancement. La clé porte la VERSION du contrat :
/// une révision future redemandera l'accord. 100 % local : rien n'est envoyé.
struct LicenseGate<Content: View>: View {
    @ViewBuilder let content: Content
    @AppStorage("cluf_accepted_v1") private var accepted = false
    @State private var refused = false

    var body: some View {
        if accepted {
            content
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Conditions d'utilisation").font(.system(size: 22, weight: .bold)).foregroundColor(Vyra.m3OnSurface)
                Text("VYRA Camera").font(.system(size: 13)).foregroundColor(Vyra.m3Primary)
                ScrollView {
                    Text(cluf).font(.system(size: 13.5)).foregroundColor(Vyra.m3OnSurface).frame(maxWidth: .infinity, alignment: .leading)
                }
                if refused {
                    // iOS ne ferme pas une app à la place de l'utilisateur : on le dit, sans rien débloquer.
                    Text("Sans acceptation, l'application reste inutilisable. Vous pouvez la fermer.")
                        .font(.system(size: 12)).foregroundColor(Vyra.m3Outline)
                }
                HStack(spacing: 12) {
                    Button { refused = true } label: {
                        Text("Refuser").font(.system(size: 14, weight: .medium)).foregroundColor(Vyra.m3Primary)
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .overlay(Capsule().stroke(Vyra.m3Outline))
                    }
                    Button { accepted = true } label: {
                        Text("J'accepte").font(.system(size: 14, weight: .medium)).foregroundColor(Vyra.m3OnPrimary)
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .background(Vyra.m3Primary, in: Capsule())
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Vyra.m3Background.ignoresSafeArea())
        }
    }

    private var cluf: String {
        """
        En utilisant VYRA Camera, vous acceptez le présent contrat. VYRA Camera transforme votre téléphone en caméra pour VYRA Studio.

        • Licence : droit d'usage de l'application, personnel et non transférable. VYRA Studio (sur l'ordinateur) est sous licence par poste ; sans licence valide, un essai gratuit de 14 jours s'applique (produit complet avec filigrane ; au-delà, la diffusion est bloquée jusqu'à l'activation d'une licence).

        • Hors ligne : l'application fonctionne sur votre réseau local. Elle ne collecte aucune donnée personnelle et n'envoie aucune télémétrie.

        • Vos contenus : les images filmées et diffusées vous appartiennent ; l'éditeur n'y accède pas.

        • Fourni « en l'état » : sans garantie d'un fonctionnement ininterrompu ni d'adéquation à un besoin particulier. Responsabilité de l'éditeur limitée au montant éventuellement payé ; préjudices indirects exclus.

        • Restrictions : ne pas revendre, redistribuer, prêter, ni pratiquer l'ingénierie inverse de l'application ; ne pas contourner le mécanisme de licence.

        • Composants tiers : NDI® (marque de son titulaire), FFmpeg (LGPL) et autres, régis par leurs licences respectives. VYRA n'est pas affilié à NDI®.

        • Droit applicable : droit béninois (et, le cas échéant, Actes uniformes OHADA) ; tribunaux compétents de Cotonou.

        Éditeur : Godwill AGBOMENOU — vyraconcept.send.it@gmail.com — WhatsApp +229 01 41 59 59 29.
        Version 1.0 — 12/09/2026.
        """
    }
}

// MARK: - Autorisation caméra

/// La caméra bloque, le micro non : les deux sont demandés ensemble, mais seul le refus caméra
/// empêche l'accès à l'écran de prise de vue (le son vient souvent de la console de mixage).
struct CameraPermissionGate<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var granted = CameraCapture.isAuthorized

    var body: some View {
        if granted {
            content
        } else {
            VStack(spacing: 0) {
                Text("L'acces a la camera est necessaire pour diffuser.").multilineTextAlignment(.center)
                Text("Le micro est facultatif : sans lui, la diffusion se fait en video seule.")
                    .multilineTextAlignment(.center).padding(.top, 8)
                Button(action: request) {
                    Text("Autoriser").font(.system(size: 14, weight: .medium)).foregroundColor(Vyra.m3OnPrimary)
                        .padding(.horizontal, 24).frame(height: 40)
                        .background(Vyra.m3Primary, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
            }
            .font(.system(size: 16)).foregroundColor(Vyra.m3OnSurface)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Vyra.m3Background.ignoresSafeArea())
        }
    }

    private func request() {
        CameraCapture.requestAccess { ok in
            AudioCapture.requestAccess { _ in granted = ok }
        }
    }
}
