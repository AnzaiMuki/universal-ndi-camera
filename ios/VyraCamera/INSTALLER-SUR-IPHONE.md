# Installer VYRA Camera sur iPhone — gratuitement

Sans compte Apple Developer payant : **Sideloadly** installe l'app avec un **identifiant Apple gratuit**
(celui de l'iPhone convient, un identifiant secondaire est encore mieux).

- iPhone sous **iOS 15 ou plus récent**.
- Un **PC Windows** et un **câble USB**.

**Fichier de l'app (dernière version) :**

```
https://github.com/AnzaiMuki/universal-ndi-camera/releases/download/ios-beta/VyraCamera.ipa
```

---

## 1. Préparer le PC (une seule fois)

1. Installez **iTunes** et **iCloud** depuis le site d'Apple. Les versions du Microsoft Store
   ne fonctionnent pas avec Sideloadly.
2. Téléchargez **Sideloadly** sur **sideloadly.io**, puis installez-le.

## 2. Installer VYRA Camera

1. Téléchargez `VyraCamera.ipa` (lien ci-dessus).
2. Branchez l'iPhone au PC. Sur l'iPhone, touchez **Se fier à cet ordinateur**.
3. Ouvrez Sideloadly : l'iPhone apparaît dans la liste des appareils.
4. Glissez `VyraCamera.ipa` dans la fenêtre de Sideloadly.
5. Dans **Apple account**, saisissez votre identifiant Apple, puis cliquez sur **Start**. Entrez
   le mot de passe et, si demandé, le code à 6 chiffres reçu sur l'iPhone. Ils ne sont envoyés qu'à Apple.
6. Attendez **Done**.

## 3. Autoriser l'app sur l'iPhone (une seule fois)

1. **Réglages ▸ Général ▸ VPN et gestion de l'appareil** : touchez votre identifiant Apple, puis
   **Faire confiance**.
2. Sous iOS 16 ou plus récent : **Réglages ▸ Confidentialité et sécurité ▸ Mode développeur**,
   activez-le. L'iPhone redémarre ; confirmez ensuite avec **Activer**.
3. Au premier lancement de VYRA Camera, acceptez **Caméra**, **Micro** et **Réseau local**.
   Sans le réseau local, VYRA Studio ne voit pas l'iPhone.

## 4. Renouvellement et mises à jour

- Avec un identifiant Apple gratuit, Apple limite l'installation à **7 jours**. Pour la prolonger,
  refaites l'étape 2 avec le même fichier : vos réglages sont conservés.
- Au-delà de 7 jours sans renouvellement, l'app ne s'ouvre plus. Il suffit de la réinstaller.
- Pour une nouvelle version, téléchargez de nouveau `VyraCamera.ipa` et refaites l'étape 2.
- Un identifiant Apple gratuit permet **3 apps** installées de cette façon.

## En cas de problème

| Message | Solution |
|---|---|
| L'iPhone n'apparaît pas dans Sideloadly | Déverrouillez-le, touchez « Se fier », vérifiez qu'iTunes (version du site Apple) le voit. |
| « Unable to launch… / Développeur non approuvé » | Refaites l'étape 3.1 (faire confiance au profil). |
| « Mode développeur requis » | Refaites l'étape 3.2. |
| « Maximum number of apps » | Supprimez une autre app installée de cette façon. |
| L'app ne s'ouvre plus | Les 7 jours sont passés : refaites l'étape 2. |
