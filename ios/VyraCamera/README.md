# VYRA Camera — iPhone (version minimale)

App iOS native (Swift / SwiftUI) qui transforme un iPhone en caméra pour **VYRA Studio**, en
parlant **exactement le même protocole UNDI** que l'app Android (en-tête 24 octets, H.264 Annex-B,
Bonjour `_undicam._tcp`, port TCP **6789**). Aucune caméra à acheter, aucun abonnement.

## Ce que fait cette v0.4 (parité avec l'app Android, sauf SRT)

- Aperçu caméra plein écran (caméra arrière, **720p / 1080p / 2160p**, débit réglable).
- Connexion à la régie : **régie détectée sur le réseau** (Bonjour) **ou IP saisie à la main**.
- Vidéo **H.264 → VYRA Studio** + **audio micro** PCM 16 bits mono 48 kHz (synchro labiale).
- **Canal retour** : tally (à l'antenne / préparation), consignes **CUE** (bannière HUD),
  réponses **REPLY** du vidéaste (+ accusé « vu »).
- **Pilotage à distance** (trames CONTROL) : zoom, torche, exposition (auto / ISO+durée + biais EV),
  mise au point, balance des blancs, pause vidéo, coupure/volume micro, débit adaptatif ou fixe,
  résolution — tout borné aux capacités du capteur, et **ré-émis au pont** (il affiche la vérité).
- **Télémétrie** batterie / charge / niveau thermique toutes les 5 s.
- **Reconnexion bornée 90 s** (reprise d'une micro-coupure, puis abandon) — comme l'Android.

Hors parité pour l'instant : **SRT** (l'Android s'appuie sur la bibliothèque native *libsrt* via
`srtdroid` ; la porter sur iOS demande un xcframework `libsrt`, à faire dans un second temps) ;
caméra frontale. Le chemin principal en réseau local (**NDI via TCP**) est complet.

## Tester GRATUITEMENT (sans appareil, sans Mac)

> ⚠️ **Il n'existe aucun émulateur iPhone sous Windows.** Le simulateur iOS d'Apple ne tourne que
> sur macOS (il fait partie de Xcode) **et n'a pas de caméra**. On ne peut donc pas « régler un
> émulateur iPhone sur son PC Windows » : ça n'existe pas. Mais le test automatique se fait très bien
> **dans le cloud macOS gratuit** (GitHub Actions) — c'est ce que fait le workflow :

1. **Tests unitaires** (`Tests/UndiProtocolTests.swift`) : vérifient **octet par octet** que l'iPhone
   produit exactement les formats attendus par VYRA Studio (en-tête, STREAM_CONFIG, audio, CONTROL,
   tally, cue, reply, stats). C'est la vérification « de A à Z » du protocole, **sans appareil**.
2. **Smoke test sur simulateur** : l'app est **installée et lancée** dans un simulateur iPhone (sur
   le Mac cloud) → confirme qu'elle démarre sans planter et que l'UI s'affiche.

Ce que le simulateur **ne peut pas** tester : la captation caméra et le direct réel (pas de caméra
dans le simulateur). Ça se teste sur **iPhone physique** (sideload, voir ci-dessous) face à VYRA Studio.
Pour lancer le simulateur en local, il faut un **Mac** (ou un Mac cloud type MacStadium / GitHub
Actions) ; depuis Windows, on s'appuie sur le CI.

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
