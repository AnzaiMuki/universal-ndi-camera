# VYRA Camera — iPhone (version minimale)

App iOS native (Swift / SwiftUI) qui transforme un iPhone en caméra pour **VYRA Studio**, en
parlant **exactement le même protocole UNDI** que l'app Android (en-tête 24 octets, H.264 Annex-B,
Bonjour `_undicam._tcp`, port TCP **6789**). Aucune caméra à acheter, aucun abonnement.

## Ce que fait cette v0.1 (périmètre volontairement réduit)

- Aperçu caméra plein écran (caméra arrière, **720p30 ≈ 4 Mbit/s**).
- Connexion à la régie : **régie détectée sur le réseau** (Bonjour) **ou IP saisie à la main**.
- Envoi vidéo **H.264 → VYRA Studio** (HELLO → STREAM_CONFIG → SPS/PPS → trames vidéo).

Pas encore : audio, pilotage à distance (zoom/expo), caméra frontale, SRT. À ajouter ensuite.

## Compiler SANS posséder de Mac (gratuit)

Le build tourne sur un Mac **dans le cloud** via **GitHub Actions** (gratuit pour un dépôt public) :

1. Place ce dossier dans le dépôt, à `ios/VyraCamera/`, et pousse sur GitHub.
2. Onglet **Actions → « Build iOS (VYRA Camera) » → Run workflow** (ou tout push qui touche
   `ios/VyraCamera/**`).
3. À la fin, télécharge l'artefact **`VyraCamera-unsigned-ipa`** (un `.ipa` **non signé**).

> Le projet `.xcodeproj` n'est pas versionné : il est **généré** par `xcodegen` à partir de
> `project.yml` pendant le build (rien à maintenir à la main).

## Installer sur l'iPhone SANS compte payant

Le `.ipa` est non signé : on le **re-signe avec un identifiant Apple GRATUIT** à l'installation.

- **Sideloadly** (Windows/Mac, gratuit — https://sideloadly.io) : branche l'iPhone en USB,
  glisse le `.ipa`, saisis ton **Apple ID gratuit** → installe. **Ou**
- **AltStore** (https://altstore.io) : installe AltServer sur le PC, puis l'app via AltStore.

Limites du mode gratuit (règles Apple, pas VYRA) : l'app **expire au bout de 7 jours** (il suffit de
la réinstaller / la rafraîchir), **3 apps** sideloadées à la fois, re-signature **tous les 7 jours**.

Au **premier lancement** : Réglages ▸ Général ▸ VPN et gestion de l'appareil ▸ **faire confiance** au
profil développeur. Autorise aussi **Caméra** et **Réseau local** quand l'app le demande.

## Passer sur l'App Store / TestFlight (plus tard, payant)

Diffusion large et installation « normale » (sans expiration) = **Apple Developer Program à 99 $/an**.
À envisager seulement quand la v1 iPhone sera prête et validée.

## Architecture

```
Sources/
  Protocol/UndiProtocol.swift   en-tête 24 o, STREAM_CONFIG, HELLO (miroir de UndiFrame.kt)
  Net/UndiClient.swift          client TCP (Network.framework) : IP manuelle OU endpoint Bonjour
  Net/Discovery.swift           découverte Bonjour _undicam._tcp (NWBrowser)
  Capture/CameraCapture.swift   AVCaptureSession (arrière, 720p)
  Capture/H264Encoder.swift     VideoToolbox → H.264 Annex-B + SPS/PPS
  Capture/StreamManager.swift   orchestration capture → encodeur → réseau
  App/VyraCameraApp.swift        point d'entrée SwiftUI
  App/ContentView.swift          écran unique (aperçu + connexion)
  App/CameraPreview.swift        couche d'aperçu AVCaptureVideoPreviewLayer
```

La **source de vérité du protocole** reste `core/protocol/UndiFrame.kt` (Android/Studio) : toute
évolution du format doit rester synchronisée entre les deux.
