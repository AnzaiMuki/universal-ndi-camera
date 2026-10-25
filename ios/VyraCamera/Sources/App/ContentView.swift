import SwiftUI

// Écran unique (version minimale) : aperçu caméra plein écran + panneau de connexion.
// Deux voies vers la régie : régies découvertes sur le réseau (Bonjour) ou IP saisie à la main.
struct ContentView: View {
    @EnvironmentObject private var manager: StreamManager
    @EnvironmentObject private var discovery: Discovery
    @ObservedObject private var hdmi = ExternalDisplay.shared

    @State private var host = ""
    @State private var port = "6789"   // port TCP par défaut de VYRA Studio

    // Palette EXCLUSIVE VYRA.
    private let ink = Color(red: 0.918, green: 0.941, blue: 0.925)   // #EAF0EC
    private let sage = Color(red: 0.616, green: 0.690, blue: 0.651)  // #9DB0A6
    private let green = Color(red: 0.133, green: 0.773, blue: 0.369) // #22C55E
    private let onair = Color(red: 0.90, green: 0.26, blue: 0.21)    // tally antenne (rouge)

    var body: some View {
        ZStack {
            Color(red: 0.039, green: 0.059, blue: 0.051).ignoresSafeArea() // #0A0F0D

            CameraPreview(session: manager.capture.session)
                .ignoresSafeArea()

            // Voile bas pour la lisibilité des contrôles.
            LinearGradient(
                colors: [.clear, .black.opacity(0.35), .black.opacity(0.85)],
                startPoint: .center, endPoint: .bottom
            ).ignoresSafeArea()

            VStack(spacing: 12) {
                header
                if hdmi.connected { HStack { HdmiBanner(display: hdmi); Spacer() } }
                if manager.isStreaming { tallyBar }
                Spacer()
                if let c = manager.cue { cueBanner(c) }
                if let r = manager.replyStatus { replyStatusView(r) }
                controls
            }
            .padding(20)
        }
        .onAppear { manager.startPreview(); discovery.start() }
        .onDisappear { discovery.stop(); manager.teardown() }
    }

    // MARK: - Tally / CUE / Réponses

    @ViewBuilder private var tallyBar: some View {
        if manager.tally.program {
            tallyPill("À L'ANTENNE", onair)
        } else if manager.tally.preview {
            tallyPill("PRÉPARATION", green)
        }
    }

    private func tallyPill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(.subheadline, design: .monospaced)).fontWeight(.bold)
            .tracking(2).foregroundColor(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(color, in: RoundedRectangle(cornerRadius: 12))
    }

    private func cueBanner(_ c: Cue) -> some View {
        HStack(spacing: 10) {
            Image(systemName: c.urgent ? "exclamationmark.triangle.fill" : "bubble.left.fill")
            Text(c.text).font(.headline).fontWeight(.semibold)
            Spacer(minLength: 0)
        }
        .foregroundColor(.white).padding(14)
        .frame(maxWidth: .infinity)
        .background(c.urgent ? onair : Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }

    private func replyStatusView(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: manager.replySeen ? "checkmark.circle.fill" : "paperplane.fill").foregroundColor(green)
            Text(manager.replySeen ? "Vu par la régie" : "Envoyé : \(text)")
                .font(.caption).foregroundColor(ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - En-tête

    private var header: some View {
        HStack {
            Text("VYRA").font(.system(.title3, design: .monospaced)).fontWeight(.bold).foregroundColor(ink)
            + Text(" Camera").font(.system(.title3, design: .monospaced)).foregroundColor(sage)
            Spacer()
            statusPill
        }
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            Circle().fill(manager.isStreaming ? green : sage).frame(width: 8, height: 8)
            Text(manager.status).font(.system(.caption, design: .monospaced)).foregroundColor(ink)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Contrôles

    @ViewBuilder private var controls: some View {
        if manager.isStreaming {
            VStack(spacing: 12) {
                statsRow
                // Réponses rapides du vidéaste vers la régie (canal retour).
                HStack(spacing: 8) {
                    replyButton("Compris", alert: false)
                    replyButton("Prêt", alert: false)
                    replyButton("Besoin régie", alert: true)
                }
                Button(action: manager.stop) {
                    Label("Arrêter le direct", systemImage: "stop.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                .foregroundColor(.white)
                .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                // Mode de connexion : réseau ou câble USB (comme l'Android).
                Picker("Connexion", selection: Binding(get: { manager.link }, set: { manager.link = $0 })) {
                    Text("Wi-Fi").tag(StreamManager.Link.wifi)
                    Text("USB (câble)").tag(StreamManager.Link.usb)
                }
                .pickerStyle(.segmented)

                if manager.link == .usb {
                    Text("Branchez l'iPhone au PC avec son câble. iTunes ou l'app Appareils Apple doit être installé sur le PC.")
                        .font(.caption).foregroundColor(sage)
                }

                if manager.link == .wifi, !discovery.services.isEmpty {
                    Text("RÉGIES SUR LE RÉSEAU").font(.system(.caption2, design: .monospaced))
                        .tracking(2).foregroundColor(green)
                    ForEach(discovery.services) { s in
                        Button { manager.startDiscovered(s) } label: {
                            HStack {
                                Image(systemName: "desktopcomputer").foregroundColor(green)
                                Text(s.name).foregroundColor(ink)
                                Spacer()
                                Image(systemName: "arrow.right.circle.fill").foregroundColor(green)
                            }
                            .padding(.vertical, 12).padding(.horizontal, 14)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    Text("ou saisir l'adresse manuellement").font(.caption).foregroundColor(sage)
                }

                #if SRT_ENABLED
                if manager.link == .wifi {
                    Picker("Transport", selection: Binding(get: { manager.transport }, set: { manager.transport = $0 })) {
                        Text("NDI (local)").tag(StreamManager.Transport.tcp)
                        Text("SRT (distant)").tag(StreamManager.Transport.srt)
                    }
                    .pickerStyle(.segmented)
                }
                #endif

                Toggle(isOn: Binding(get: { manager.micEnabled }, set: { manager.micEnabled = $0 })) {
                    Label("Micro", systemImage: manager.micEnabled ? "mic.fill" : "mic.slash.fill")
                        .foregroundColor(ink).font(.subheadline)
                }
                .tint(green)

                if manager.link == .wifi {
                    HStack(spacing: 10) {
                        field("Adresse IP de la régie", text: $host, keyboard: .decimalPad)
                        field("Port", text: $port, keyboard: .numberPad).frame(width: 90)
                    }
                }

                Button { manager.link == .usb ? manager.startUsb() : connectManual() } label: {
                    Label(manager.state == .connecting ? "Connexion…" : "Passer en direct", systemImage: "dot.radiowaves.left.and.right")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                .foregroundColor(.white)
                .background(Color(red: 0.086, green: 0.639, blue: 0.290), in: RoundedRectangle(cornerRadius: 16)) // #16A34A
                .disabled(needsHost || manager.state == .connecting)
                .opacity(needsHost ? 0.5 : 1)
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
    }

    private func replyButton(_ text: String, alert: Bool) -> some View {
        Button { manager.sendReply(text, alert: alert) } label: {
            Text(text).font(.footnote).fontWeight(.semibold).foregroundColor(alert ? .white : ink)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(alert ? onair.opacity(0.85) : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var statsRow: some View {
        HStack(spacing: 14) {
            Label(manager.battery >= 0 ? "\(manager.battery)%" : "—",
                  systemImage: manager.charging ? "battery.100.bolt" : "battery.50")
            Label(thermalText, systemImage: "thermometer.medium")
            Spacer()
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundColor(manager.thermal == .hot || manager.thermal == .critical ? onair : sage)
    }

    private var thermalText: String {
        switch manager.thermal {
        case .nominal: return "OK"
        case .warm: return "Tiède"
        case .hot: return "Chaud"
        case .critical: return "Critique"
        case .unknown: return "—"
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(sage))
            .keyboardType(keyboard)
            .foregroundColor(ink)
            .padding(.vertical, 12).padding(.horizontal, 14)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var needsHost: Bool { manager.link == .wifi && host.isEmpty }

    private func connectManual() {
        guard let p = UInt16(port.trimmingCharacters(in: .whitespaces)) else { return }
        manager.startManual(host: host.trimmingCharacters(in: .whitespaces), port: p)
    }
}
