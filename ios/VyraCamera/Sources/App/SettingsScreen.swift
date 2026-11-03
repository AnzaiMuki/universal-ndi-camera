import SwiftUI

// Écran RÉGLAGES plein, ouvert par l'engrenage du rail (comme SettingsScreen côté Android) : la
// configuration se pose une fois et se lit rangée par sections. Le viseur continue de diffuser dessous.
struct SettingsScreen: View {
    @EnvironmentObject private var m: StreamManager
    @Binding var previewLocked: Bool
    @Binding var manualHost: String
    let onClose: () -> Void

    private let fpsChoices = [24, 25, 30, 50, 60]

    var body: some View {
        ZStack {
            Color(argb: 0xF2070A0F).ignoresSafeArea()
                .contentShape(Rectangle()).onTapGesture {}   // rien n'atteint le viseur dessous
            ScrollView {
                VStack(spacing: 12) {
                    HStack {
                        Text("Réglages").font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                        Spacer()
                        Button(action: onClose) {
                            Text("Terminé").font(.system(size: 13, weight: .bold)).foregroundColor(Vyra.accent)
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .background(Color(argb: 0x22FFFFFF), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                    quality
                    image
                    network
                    about
                }
                .frame(maxWidth: 680)
                .padding(.horizontal, 24).padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Qualité

    private var quality: some View {
        let live = m.isLive
        return SettingsSection(title: "Qualité") {
            SettingsRowLabel(text: "Résolution")
            ChipRow {
                ForEach(m.supportedFormats()) { f in
                    ValueChip(text: f.label, active: f.height == m.format.height, mono: false) { m.setResolution(f) }
                }
            }
            Hint(text: live ? "Verrouillée pendant le direct."
                 : "Ne sont proposées que les résolutions que cet appareil sait encoder. Plus haut = plus net, mais plus de débit. Le pont affiche le format choisi.")

            SettingsRowLabel(text: "Cadence")
            let choices = m.caps.constantFps.filter { fpsChoices.contains($0) }
            ChipRow {
                ForEach(choices.isEmpty ? fpsChoices : choices, id: \.self) { f in
                    ValueChip(text: "\(f) fps", active: f == m.fps) { m.setFps(f) }
                }
            }
            if live { Hint(text: "Verrouillée pendant le direct : la cadence est annoncée à la production à la connexion.") }

            SettingsRowLabel(text: "Débit adaptatif")
            ChipRow {
                ValueChip(text: "Activé", active: m.adaptiveBitrate, mono: false) { m.setAdaptiveBitrate(true) }
                ValueChip(text: "Fixe", active: !m.adaptiveBitrate, mono: false) { m.setAdaptiveBitrate(false) }
            }
            Hint(text: m.adaptiveBitrate
                 ? "Le débit baisse tout seul si le Wi-Fi sature ou si le téléphone chauffe — l'image reste fluide au lieu de saccader."
                 : "Débit fixe à \(String(format: "%.1f", Double(m.format.bitrateBps) / 1_000_000).replacingOccurrences(of: ".", with: ",")) Mbps, sans filet en cas de congestion ou de surchauffe.")
            Hint(text: "H.264 · NDI")
        }
    }

    // MARK: Image

    private var image: some View {
        SettingsSection(title: "Image") {
            SettingsRowLabel(text: "Aperçu")
            ChipRow {
                ValueChip(text: "16:9 exact", active: previewLocked, mono: false) { previewLocked = true }
                ValueChip(text: "Plein écran", active: !previewLocked, mono: false) { previewLocked = false }
            }
            Hint(text: previewLocked ? "Le viseur affiche précisément l'image diffusée, avec de fines bandes sur les côtés."
                 : "L'aperçu remplit l'écran ; il peut montrer un peu moins que le flux réel.")

            // Stabilisation : montrée UNIQUEMENT si le capteur déclare un mode.
            if m.caps.supportsStabilization {
                let c = m.controls
                SettingsRowLabel(text: "Stabilisation")
                ChipRow {
                    ValueChip(text: "Désactivée", active: c.stabilization == .off, mono: false) { m.setControls(with(c) { $0.stabilization = .off }) }
                    if m.caps.hasOpticalStabilization {
                        ValueChip(text: "Optique", active: c.stabilization == .optical, mono: false) { m.setControls(with(c) { $0.stabilization = .optical }) }
                    }
                    if m.caps.hasElectronicStabilization {
                        ValueChip(text: "Électronique", active: c.stabilization == .electronic, mono: false) { m.setControls(with(c) { $0.stabilization = .electronic }) }
                    }
                }
                Hint(text: {
                    switch c.stabilization {
                    case .off: return "Recommandé sur trépied : l'image est déjà stable, et l'EIS coupée évite le recadrage et les déformations quand on penche le téléphone."
                    case .optical: return "Optique (OIS) : compensation matérielle, sans latence ni recadrage."
                    case .electronic: return "Électronique (EIS) : léger recadrage et légère latence — à réserver à la caméra à main."
                    }
                }())
            }
        }
    }

    // MARK: Réseau

    private var network: some View {
        let usb = m.link == .usb
        return SettingsSection(title: "Réseau") {
            Text("Mode de connexion").font(.system(size: 12)).foregroundColor(Vyra.muted)
            HStack(spacing: 8) {
                FilterChip(label: "Wi-Fi (auto)", selected: !usb) { m.setLink(.wifi) }
                FilterChip(label: "USB (câble)", selected: usb) { m.setLink(.usb) }
                Spacer()
            }
            Text(statusText(usb: usb)).font(.system(size: 13, weight: .medium))
                .foregroundColor(m.bridgeName != nil ? Vyra.ready : Vyra.muted)
            if usb {
                Hint(text: "Par câble : branchez l'iPhone à l'ordinateur. VYRA Studio s'y connecte tout seul (iTunes ou l'app Appareils Apple doit être installé sur l'ordinateur). Aucun réseau Wi-Fi requis, latence minimale.")
            } else {
                Hint(text: "La connexion est automatique sur le même Wi-Fi. Le champ plus bas n'est qu'un secours si la découverte échoue.")
                #if SRT_ENABLED
                Text("Transport").font(.system(size: 12)).foregroundColor(Vyra.muted)
                HStack(spacing: 8) {
                    FilterChip(label: "TCP (fluide)", selected: m.transport == .tcp) { m.transport = .tcp }
                    FilterChip(label: "SRT (anti-perte)", selected: m.transport == .srt) { m.transport = .srt }
                    Spacer()
                }
                Hint(text: m.transport == .srt
                     ? "SRT borne la latence en lâchant les paquets en retard : utile sur un Wi-Fi qui perd, mais peut « laguer » si le réseau est déjà bon. Effet au prochain direct."
                     : "TCP : fiable et fluide, le meilleur choix sur un Wi-Fi sain. Effet au prochain direct.")
                #endif
                if !m.isLive {
                    HStack(spacing: 8) {
                        OutlinedField(label: "IP du pont (secours)", text: $manualHost)
                        Button { m.goLiveManual(manualHost) } label: {
                            Text("Connexion").font(.system(size: 14, weight: .medium))
                                .foregroundColor(manualHost.trimmingCharacters(in: .whitespaces).isEmpty ? Vyra.m3OnSurface.opacity(0.38) : Vyra.m3Primary)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func statusText(usb: Bool) -> String {
        if let b = m.bridgeName { return usb ? "Connecté par câble ✓" : "Pont détecté : \(b)" }
        return usb ? "En attente du pont via USB — branchez le câble…" : "Recherche du pont sur le Wi-Fi…"
    }

    // MARK: À propos

    private var about: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return SettingsSection(title: "À propos") {
            Hint(text: "VYRA Camera \(version)")
            Hint(text: "Vision. Connectivity. Broadcast.")
            Hint(text: "La source NDI et son nom sont gérés par le pont (VYRA Studio), sur l'ordinateur.")
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).tracking(1.4).font(.system(size: 11, weight: .bold)).foregroundColor(Vyra.accent)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(argb: 0x12FFFFFF), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Vyra.hudLine))
    }
}

private struct SettingsRowLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundColor(.white).padding(.top, 4)
    }
}

/// Puce de filtre Material 3 (sombre) : contour, coche quand elle est choisie.
private struct FilterChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if selected { Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)) }
                Text(label).font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(selected ? Color(argb: 0xFFE8DEF8) : Color(argb: 0xFFCAC4D0))
            .padding(.leading, selected ? 8 : 16).padding(.trailing, 16)
            .frame(height: 32)
            .background(selected ? Color(argb: 0xFF4A4458) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.clear : Vyra.m3Outline))
        }
        .buttonStyle(.plain)
    }
}

/// Champ texte « contouré » Material 3 avec libellé flottant.
private struct OutlinedField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextField("", text: $text)
                .keyboardType(.decimalPad)
                .font(.system(size: 16)).foregroundColor(Vyra.m3OnSurface).accentColor(Vyra.m3Primary)
                .padding(.horizontal, 16).frame(height: 56)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Vyra.m3Outline))
            Text(label).font(.system(size: text.isEmpty ? 16 : 12)).foregroundColor(Color(argb: 0xFFCAC4D0))
                .padding(.horizontal, 4)
                .background(text.isEmpty ? Color.clear : Color(argb: 0xFF0B0E12))
                .offset(x: 12, y: text.isEmpty ? 18 : -8)
                .allowsHitTesting(false)
        }
    }
}
