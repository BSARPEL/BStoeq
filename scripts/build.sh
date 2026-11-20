#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# Check the original engine and its corresponding source before signing the app copy.
/usr/bin/python3 - <<'PY'
import hashlib
import json
from pathlib import Path

manifest = Path("Resources/Licenses/SHA256.json")
for path, expected in json.loads(manifest.read_text()).items():
    if hashlib.sha256(Path(path).read_bytes()).hexdigest() != expected:
        raise SystemExit(f"SHA-256 mismatch: {path}")
PY
swift build -c release --product BStoeq
BIN_DIR="$(swift build -c release --show-bin-path)"
OUTPUT_DIR="${BSTOEQ_OUTPUT_DIR:-${BARLET_OUTPUT_DIR:-$PWD/dist}}"
mkdir -p "$OUTPUT_DIR"
STAGING="$(mktemp -d "$OUTPUT_DIR/.bstoeq-package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/BStoeq.app"
RESOURCE_DIR="$APP/Contents/Resources"
mkdir -p "$APP/Contents/MacOS" "$RESOURCE_DIR"
cp "$BIN_DIR/BStoeq" "$APP/Contents/MacOS/BStoeq"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Stash-LICENSE.txt "$RESOURCE_DIR/"
ditto Resources/Tools "$RESOURCE_DIR/Tools"
ditto Resources/Licenses "$RESOURCE_DIR/Licenses"
for LOCALIZATION in Resources/*.lproj(N); do
    ditto "$LOCALIZATION" "$RESOURCE_DIR/${LOCALIZATION:t}"
done
# Only runtime resources belong in the installed app. Test bundles contain fixtures.
for BUNDLE in BStoeq_BStoeqCore.bundle BStoeq_ArchiveWorkspace.bundle; do
    ditto "$BIN_DIR/$BUNDLE" "$RESOURCE_DIR/$BUNDLE"
done
swift scripts/icon.swift "$STAGING"
iconutil -c icns "$STAGING/AppIcon.iconset" -o "$RESOURCE_DIR/AppIcon.icns"

# Use the existing local signing identity so system permission grants survive updates.
SIGNING_IDENTITY="${BSTOEQ_SIGNING_IDENTITY:-${BARLET_SIGNING_IDENTITY:-}}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    IDENTITIES=("${(@f)$(security find-identity -v -p codesigning | sed -nE 's/^[[:space:]]*[[:digit:]]+\) ([A-F0-9]+) "Apple Development:.*$/\1/p')}")
    if [[ ${#IDENTITIES} -eq 1 && -n "${IDENTITIES[1]}" ]]; then
        SIGNING_IDENTITY="${IDENTITIES[1]}"
    else
        SIGNING_IDENTITY="-"
    fi
fi
ENGINE="$RESOURCE_DIR/Tools/7zz"
codesign --force --sign "$SIGNING_IDENTITY" "$ENGINE"
codesign --verify --strict --all-architectures "$ENGINE"
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

# Both localization catalogs and the Finder service descriptions must ship.
/usr/bin/python3 - "$RESOURCE_DIR" <<'PY'
import json
from pathlib import Path
import sys

for bundle, name in [("BStoeq_BStoeqCore", "Localization"), ("BStoeq_ArchiveWorkspace", "Translations")]:
    catalog = Path(sys.argv[1]) / (bundle + ".bundle") / "Contents/Resources" / (name + ".json")
    entries = json.loads(catalog.read_text())
    if not entries or not all(isinstance(row.get(lang), str) and row[lang].strip()
                              for row in entries.values() for lang in ("tr", "en", "de")):
        raise SystemExit(f"Missing translations in {name}")
PY
for FILE in "$RESOURCE_DIR"/{en,tr,de}.lproj/{ServicesMenu,InfoPlist}.strings "$APP/Contents/Info.plist"; do
    plutil -lint "$FILE" >/dev/null
done
"$ENGINE" i >/dev/null
"$APP/Contents/MacOS/BStoeq" --diagnostics
PACKAGE="$STAGING/BStoeq-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$PACKAGE"
"$ENGINE" t -bso0 -bsp0 "$PACKAGE"
mv -f "$PACKAGE" "$OUTPUT_DIR/BStoeq-macOS.zip"
print "Dağıtım paketi hazır: $OUTPUT_DIR/BStoeq-macOS.zip"
print "ZIP içindeki BStoeq.app dosyasını /Applications klasörüne kur."
