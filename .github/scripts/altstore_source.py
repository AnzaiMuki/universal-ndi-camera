"""Génère la source AltStore de VYRA Camera (lue par AltStore sur l'iPhone).

Usage : altstore_source.py <Info.plist de l'app> <fichier .ipa> <propriétaire/dépôt>
La version et le numéro de build sont lus dans l'app elle-même : AltStore refuse une app
dont la version ne correspond pas à celle annoncée par la source.
"""
import datetime
import json
import os
import plistlib
import sys

info_path, ipa_path, depot = sys.argv[1:4]
with open(info_path, "rb") as f:
    info = plistlib.load(f)

base = f"https://github.com/{depot}"
privacy = {k: v for k, v in info.items() if k.startswith("NS") and k.endswith("UsageDescription")}

source = {
    "name": "VYRA",
    "identifier": "com.vyra.source",
    "subtitle": "Vision. Connectivity. Broadcast.",
    "website": base,
    "tintColor": "2E9BFF",
    "apps": [{
        "name": "VYRA Camera",
        "bundleIdentifier": info["CFBundleIdentifier"],
        "developerName": "Godwill AGBOMENOU",
        "subtitle": "Votre iPhone devient une caméra pour VYRA Studio.",
        "localizedDescription": "Caméra de production pour VYRA Studio : Wi-Fi ou câble USB, "
                                "tally, consignes de la régie, messagerie et réglages manuels.",
        "iconURL": f"https://raw.githubusercontent.com/{depot}/ios-camera-v0.1/"
                   "ios/VyraCamera/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
        "tintColor": "2E9BFF",
        "category": "photo-video",
        "versions": [{
            "version": info["CFBundleShortVersionString"],
            "buildVersion": info["CFBundleVersion"],
            "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "downloadURL": f"{base}/releases/download/ios-beta/VyraCamera.ipa",
            "size": os.path.getsize(ipa_path),
            "minOSVersion": info.get("MinimumOSVersion", "15.0"),
        }],
        "appPermissions": {"entitlements": [], "privacy": privacy},
    }],
    "news": [],
}
json.dump(source, sys.stdout, ensure_ascii=False, indent=2)
