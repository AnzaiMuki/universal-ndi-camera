import SwiftUI

// Écran unique (version minimale) : aperçu caméra plein écran + panneau de connexion.
// Deux voies vers la régie : régies découvertes sur le réseau (Bonjour) ou IP saisie à la main.
struct ContentView: View {
    @EnvironmentObject private var manager: StreamManager
    @EnvironmentObject private var discovery: Discovery

    @State private var host = ""
    @State private var port = "6789"   // port TCP par défaut de VYRA Studio

    // Palette EXCLUSIVE VYRA.
    private let ink = Color(red: 0.918, green: 0.941, blue: 0.925)   // #EAF0EC
    private let sage = Color(red: 0.616, green: 0.690, blue: 0.651)  // #9DB0A6
    private let green = Color(red: 0.133, green: 0.773, blue: 0.369) // #22C55E

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

            VStack(spacing: 0) {
                header
                Spacer()
                controls
            }
            .padding(20)
        }
        .onAppear { manager.startPreview(); discovery.start() }
        .onDisappear { discovery.stop(); manager.teardown() }
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
            Button(action: manager.stop) {
                Label("Arrêter le direct", systemImage: "stop.fill")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            .foregroundColor(.white)
            .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if !discovery.services.isEmpty {
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

                Toggle(isOn: Binding(get: { manager.micEnabled }, set: { manager.micEnabled = $0 })) {
                    Label("Micro", systemImage: manager.micEnabled ? "mic.fill" : "mic.slash.fill")
                        .foregroundColor(ink).font(.subheadline)
                }
                .tint(green)

                HStack(spacing: 10) {
                    field("Adresse IP de la régie", text: $host, keyboard: .decimalPad)
                    field("Port", text: $port, keyboard: .numberPad).frame(width: 90)
                }

                Button(action: connectManual) {
                    Label(manager.state == .connecting ? "Connexion…" : "Passer en direct", systemImage: "dot.radiowaves.left.and.right")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                .foregroundColor(.white)
                .background(Color(red: 0.086, green: 0.639, blue: 0.290), in: RoundedRectangle(cornerRadius: 16)) // #16A34A
                .disabled(host.isEmpty || manager.state == .connecting)
                .opacity(host.isEmpty ? 0.5 : 1)
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(sage))
            .keyboardType(keyboard)
            .foregroundColor(ink)
            .padding(.vertical, 12).padding(.horizontal, 14)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func connectManual() {
        guard let p = UInt16(port.trimmingCharacters(in: .whitespaces)) else { return }
        manager.startManual(host: host.trimmingCharacters(in: .whitespaces), port: p)
    }
}
