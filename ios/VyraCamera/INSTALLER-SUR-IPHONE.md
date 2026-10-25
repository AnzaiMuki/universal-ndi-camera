# Installer VYRA Camera sur iPhone — gratuitement

Sans compte Apple Developer payant : **AltStore** installe l'app avec un **identifiant Apple gratuit**
(celui de l'iPhone convient, un identifiant secondaire est encore mieux).

- iPhone sous **iOS 15 ou plus récent**.
- Un **PC Windows** sur le même Wi-Fi que l'iPhone (pour l'installation et le renouvellement).
- Un **câble USB** pour la première fois.

**Source AltStore de VYRA :**

```
https://github.com/AnzaiMuki/universal-ndi-camera/releases/download/ios-beta/altstore.json
```

---

## 1. Préparer le PC (une seule fois)

1. Installez **iTunes** et **iCloud** depuis le site d'Apple. Les versions du Microsoft Store
   ne fonctionnent pas avec AltServer. Les liens directs se trouvent sur **altstore.io**, dans la
   page d'installation pour Windows.
2. Téléchargez **AltServer pour Windows** sur **altstore.io**, installez-le, puis lancez-le.
   Son icône (un losange) apparaît près de l'horloge, en bas à droite.

## 2. Installer AltStore sur l'iPhone (une seule fois)

1. Branchez l'iPhone au PC. Sur l'iPhone, touchez **Se fier à cet ordinateur**.
2. Ouvrez iTunes, cliquez sur l'icône de l'iPhone, cochez
   **Synchroniser avec cet iPhone en Wi-Fi**, puis **Appliquer**. Ce réglage permet le
   renouvellement sans câble.
3. Cliquez sur l'icône AltServer près de l'horloge, puis **Install AltStore** ▸ votre iPhone.
   Saisissez votre identifiant Apple et son mot de passe. Ils ne sont envoyés qu'à Apple.
4. Sur l'iPhone, ouvrez **Réglages ▸ Général ▸ VPN et gestion de l'appareil**, touchez votre
   identifiant Apple, puis **Faire confiance**.
5. Sous iOS 16 ou plus récent, ouvrez **Réglages ▸ Confidentialité et sécurité ▸ Mode développeur**
   et activez-le. L'iPhone redémarre ; confirmez ensuite avec **Activer**.

## 3. Installer VYRA Camera

1. Sur l'iPhone, ouvrez **AltStore** ▸ onglet **Sources** ▸ **+**.
2. Collez l'adresse de la source VYRA (ci-dessus), puis validez.
3. Touchez **VYRA Camera** ▸ **Gratuit** / **Installer**. L'app apparaît sur l'écran d'accueil.

*Autre méthode :* ouvrez sur l'iPhone la page
**github.com/AnzaiMuki/universal-ndi-camera/releases/tag/ios-beta**, téléchargez
`VyraCamera.ipa`, puis dans AltStore ▸ **Mes apps** ▸ **+**, choisissez ce fichier.

## 4. Renouvellement et mises à jour

- Avec un identifiant Apple gratuit, Apple limite l'installation à **7 jours**. AltStore la
  renouvelle **tout seul** quand l'iPhone et le PC (AltServer lancé) sont sur le même Wi-Fi.
  Vous pouvez aussi le faire à la main : AltStore ▸ **Mes apps** ▸ **Tout actualiser**.
- Sans renouvellement au-delà de 7 jours, l'app ne s'ouvre plus. Vos réglages sont conservés :
  il suffit d'actualiser.
- Chaque nouvelle version publiée apparaît dans AltStore ▸ **Mes apps** ▸ **Mettre à jour**.
- Un identifiant Apple gratuit permet **3 apps** installées de cette façon, AltStore compris.

## En cas de problème

| Message | Solution |
|---|---|
| « Could not find AltServer » | Vérifiez qu'AltServer est lancé et que l'iPhone et le PC sont sur le même Wi-Fi, ou branchez le câble. |
| « Unable to launch… / Développeur non approuvé » | Refaites l'étape 2.4 (faire confiance au profil). |
| « Mode développeur requis » | Refaites l'étape 2.5. |
| « Maximum number of apps » | Supprimez une autre app installée via AltStore ou Sideloadly. |
| L'app ne s'ouvre plus | Les 7 jours sont passés : AltStore ▸ Mes apps ▸ Tout actualiser. |
