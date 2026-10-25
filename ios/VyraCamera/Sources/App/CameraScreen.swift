import SwiftUI

// Écran de prise de vue, reproduction de CameraScreen.kt (Android) : viseur paysage, HUD posé sur
// l'image, rail d'outils à droite, messagerie et zoom en bas, volets d'outils, écran Réglages.
struct CameraScreen: View {
    @EnvironmentObject private var m: StreamManager
    @ObservedObject private var hdmi = ExternalDisplay.shared
    @StateObject private var level = LevelMotion()

    @State private var tool: Tool?
    @State private var guideMask: Guide = .thirds
    // Aperçu borné au vrai 16:9 (défaut) : le viseur montre EXACTEMENT le cadrage diffusé.
    @State private var previewLocked = true
    @State private var showSettings = false
    @State private var msgOpen = false
    @State private var manualHost = ""
    @State private var tap: CGPoint?
    @State private var tapCount = 0
    @State private var pinchStart: Float?
    // L'analyse d'image n'est branchée que si un outil la demande.
    @State private var histogramOn = false
    @State private var zebraPercent: Int?
    @State private var peakingOn = false
    @State private var levelOn = false

    private let handle = PreviewHandle()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { g in
                let full = g.size
                let box = previewLocked
                    ? CGSize(width: min(full.width, full.height * 16 / 9), height: min(full.height, full.width * 9 / 16))
                    : full
                imageArea(box).frame(width: box.width, height: box.height).position(x: full.width / 2, y: full.height / 2)
            }
            .ignoresSafeArea()

            // Voiles haut ET bas : ils garantissent la lisibilité du texte posé sur une scène claire.
            VStack(spacing: 0) {
                LinearGradient(colors: [Color(argb: 0x9E000000), .clear], startPoint: .top, endPoint: .bottom).frame(height: 96)
                Spacer()
                LinearGradient(colors: [.clear, Color(argb: 0xA6000000)], startPoint: .top, endPoint: .bottom).frame(height: 104)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            hud

            if showSettings {
                SettingsScreen(previewLocked: $previewLocked, manualHost: $manualHost) { showSettings = false }
            }
        }
        .onAppear { m.startPreview() }
        .onChange(of: histogramOn) { _ in updateTools() }
        .onChange(of: zebraPercent) { _ in updateTools() }
        .onChange(of: peakingOn) { _ in updateTools() }
        .onChange(of: levelOn) { level.setEnabled($0) }
    }

    private func updateTools() {
        m.setExposureTools(histogram: histogramOn, zebraPercent: zebraPercent, peaking: peakingOn)
    }

    // MARK: - Zone image (tout ce qui doit coller à l'image réelle vit ici)

    private func imageArea(_ size: CGSize) -> some View {
        ZStack {
            CameraPreview(capture: m.capture, handle: handle, fill: !previewLocked)

            // Couche tactile : appui = point + mesure ; pincement = zoom.
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                    guard hypot(v.translation.width, v.translation.height) < 10 else { return }
                    tap = v.location
                    tapCount += 1
                    m.focusAt(handle.devicePoint(v.location, in: size))
                })
                .simultaneousGesture(MagnificationGesture()
                    .onChanged { s in
                        guard m.caps.supportsZoom else { return }
                        if pinchStart == nil { pinchStart = m.controls.zoom }
                        m.setZoom((pinchStart ?? 1) * Float(s))
                    }
                    .onEnded { _ in pinchStart = nil })

            GuidesOverlay(mask: guideMask)
            if levelOn { LevelOverlay(roll: level.roll - level.calRoll, pitch: level.pitch - level.calPitch) }
            if let tap { FocusReticle(point: tap).id(tapCount) }
            ZebraOverlay(mask: m.analysis.zebra)
            PeakingOverlay(mask: m.analysis.peaking)
            TallyOverlay(tally: m.tally)
        }
        .clipped()
    }

    // MARK: - HUD

    private var hud: some View {
        ZStack {
            ExposureReadouts(c: m.controls, fps: m.fps)
                .padding(.top, 12).padding(.leading, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            TimecodeStatus(state: m.state, previewReady: m.previewReady, paused: m.paused,
                           bridgeName: m.bridgeName, usb: m.link == .usb, liveSince: m.liveSince)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if hdmi.connected {
                HdmiBanner(display: hdmi).padding(.top, 48)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            TopRightCluster(thermal: m.thermal, battery: m.battery, charging: m.charging, resolutionLabel: "\(m.format.height)p")
                .padding(.top, 12).padding(.trailing, 12 + Vyra.railWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            Toolbar(live: m.isLive, selected: tool,
                    onSelect: { t in withAnimation(.easeOut(duration: 0.2)) { tool = tool == t ? nil : t } },
                    onCamera: { withAnimation(.easeOut(duration: 0.2)) { tool = nil } },
                    onLive: { m.toggleLive() },
                    onSettings: { tool = nil; showSettings = true })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

            if histogramOn && tool == nil {
                HistogramOverlay(histogram: m.analysis.histogram)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            if tool == nil && m.isLive {
                AudioMeter(level: m.audioLevel, failure: m.audioFailure, micEnabled: m.micEnabled) { m.setMicEnabled(!m.micEnabled) }
                    .padding(.bottom, 12).padding(.trailing, 12 + Vyra.railWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }

            if tool == nil {
                if let rs = m.replyStatus {
                    ReplyStatusPill(status: rs).padding(.bottom, 170)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                if msgOpen {
                    MessagingPanel { text, alert in m.sendReply(text, alert: alert); msgOpen = false }
                        .padding(.horizontal, 16).padding(.bottom, 132)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                BottomCluster(
                    dim: msgOpen,
                    status: StreamStatusLine(streaming: m.isStreaming, tally: m.tally, paused: m.paused,
                                             bridgeName: m.bridgeName, throughputBps: m.throughputBps),
                    presets: m.caps.supportsZoom ? zoomPresets(m.caps.maxZoom) : [],
                    currentZoom: m.controls.zoom,
                    onZoom: { m.zoomTo($0) },
                    onToggleMsg: { withAnimation(.easeOut(duration: 0.2)) { msgOpen.toggle() } })
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }

            if let tool {
                ControlPanel(tool: tool, guideMask: $guideMask, level: level, levelOn: $levelOn,
                             histogramOn: $histogramOn, zebraPercent: $zebraPercent, peakingOn: $peakingOn,
                             onContinuousFocus: {
                                 tap = nil
                                 m.clearTapFocus()
                                 m.setControls(with(m.controls) { $0.autoFocus = true })
                             })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom))
            }

            // Consigne de la régie : par-dessus le HUD, sous le timecode. S'efface seule.
            if let cue = m.cue {
                CueBanner(cue: cue) { m.acknowledgeCue() }.padding(.top, 54)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// Paliers de zoom par doublement (1, 2, 4, 8…), bornés par l'objectif ; le max réel est ajouté
    /// s'il est nettement au-delà du dernier palier.
    private func zoomPresets(_ maxZoom: Float) -> [Float] {
        let steps: [Float] = [1, 2, 4, 8, 16].filter { $0 <= maxZoom + 0.01 }
        guard let last = steps.last else { return [1] }
        return maxZoom > last * 1.25 ? steps + [maxZoom] : steps
    }
}
