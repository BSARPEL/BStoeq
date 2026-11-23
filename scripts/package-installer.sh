#!/bin/zsh
set -euo pipefail
# Run the cleanup trap even if a nested command fails under errexit.
setopt POSIX_TRAPS
cd "${0:A:h:h}"

# Wraps BStoeq.app in a macOS installer package (.pkg) that places it in
# /Applications. Without an argument the app is built first with build.sh; pass
# an existing BStoeq.app or BStoeq-macOS.zip to package that copy instead.

fail() { print -ru2 -- "$*"; exit 1; }
(( $# <= 1 )) || fail 'Kullanım: ./scripts/package-installer.sh [BStoeq.app | BStoeq-macOS.zip]'

BUNDLE_ID=local.barlet.app
PACKAGE_ID=local.barlet.app.installer
OUTPUT_DIR="${BSTOEQ_OUTPUT_DIR:-$PWD/dist}"
mkdir -p "$OUTPUT_DIR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bstoeq-pkg.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT

SOURCE="${1:-}"
if [[ -z "$SOURCE" ]]; then
    BSTOEQ_OUTPUT_DIR="$WORK/package" ./scripts/build.sh
    SOURCE="$WORK/package/BStoeq-macOS.zip"
fi
if [[ -d "$SOURCE" ]]; then
    APP="${SOURCE:A}"
else
    [[ -f "$SOURCE" ]] || fail "Kaynak bulunamadı: $SOURCE"
    ditto -x -k "$SOURCE" "$WORK/unpacked"
    APP="$WORK/unpacked/BStoeq.app"
fi

INFO="$APP/Contents/Info.plist"
[[ "${APP:t}" == BStoeq.app && -d "$APP" && ! -L "$APP" && -f "$INFO" &&
   "$(plutil -extract CFBundleIdentifier raw "$INFO")" == "$BUNDLE_ID" ]] ||
    fail 'Kaynak, BStoeq.app adlı uygulama paketi olmalı.'
codesign --verify --deep --strict --all-architectures "$APP" || fail 'Uygulamanın kod imzası doğrulanamadı.'
VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO")"
MINIMUM_OS="$(plutil -extract LSMinimumSystemVersion raw "$INFO")"
ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/BStoeq")"

ROOT="$WORK/root"
mkdir -p "$ROOT/Applications"
ditto "$APP" "$ROOT/Applications/BStoeq.app"
# A copy taken from a downloaded ZIP must not carry its quarantine into the payload.
xattr -dr com.apple.quarantine "$ROOT" 2>/dev/null || true

# By default Installer treats an app as relocatable: it would update another copy
# of BStoeq it finds on the disk (a build folder, for example) and leave
# /Applications untouched. Always install here, whatever version is present.
pkgbuild --analyze --root "$ROOT" "$WORK/components.plist" >/dev/null
/usr/bin/python3 - "$WORK/components.plist" <<'PY'
import plistlib
import sys

path = sys.argv[1]
with open(path, "rb") as file:
    components = plistlib.load(file)
if [item.get("RootRelativeBundlePath") for item in components] != ["Applications/BStoeq.app"]:
    raise SystemExit("Unexpected bundles in the installer payload")
components[0].update(BundleIsRelocatable=False, BundleIsVersionChecked=False,
                     BundleHasStrictIdentifier=True, BundleOverwriteAction="upgrade")
with open(path, "wb") as file:
    plistlib.dump(components, file)
PY

# Only the two installer scripts belong in the package, never stray folder metadata.
mkdir "$WORK/scripts"
install -m 755 scripts/installer/preinstall scripts/installer/postinstall "$WORK/scripts/"
pkgbuild --quiet --root "$ROOT" --component-plist "$WORK/components.plist" --scripts "$WORK/scripts" \
    --identifier "$PACKAGE_ID" --version "$VERSION" --install-location / --ownership recommended \
    "$WORK/BStoeq.pkg"

# The startup disk only, for the Macs the app itself supports. Installer asks to
# close a running BStoeq before it replaces the bundle.
cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>BStoeq $VERSION</title>
    <options customize="never" require-scripts="false" hostArchitectures="${ARCHITECTURES// /,}"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <allowed-os-versions>
        <os-version min="$MINIMUM_OS"/>
    </allowed-os-versions>
    <choices-outline>
        <line choice="app"/>
    </choices-outline>
    <choice id="app" visible="false">
        <pkg-ref id="$PACKAGE_ID"/>
    </choice>
    <pkg-ref id="$PACKAGE_ID" version="$VERSION" onConclusion="none">BStoeq.pkg</pkg-ref>
    <pkg-ref id="$PACKAGE_ID">
        <must-close>
            <app id="$BUNDLE_ID"/>
        </must-close>
    </pkg-ref>
</installer-gui-script>
XML

# An unsigned package installs, but Gatekeeper warns about it after a download.
# Signing needs a "Developer ID Installer" certificate.
SIGNING=()
INSTALLER_IDENTITY="${BSTOEQ_INSTALLER_IDENTITY:-}"
[[ -z "$INSTALLER_IDENTITY" ]] || SIGNING=(--sign "$INSTALLER_IDENTITY")
productbuild --quiet --distribution "$WORK/distribution.xml" --package-path "$WORK" \
    "${SIGNING[@]}" "$WORK/BStoeq-macOS.pkg"

# The finished package must hold the app, both scripts and the rules above.
pkgutil --expand "$WORK/BStoeq-macOS.pkg" "$WORK/expanded"
[[ -x "$WORK/expanded/BStoeq.pkg/Scripts/preinstall" && -x "$WORK/expanded/BStoeq.pkg/Scripts/postinstall" ]] ||
    fail 'Kurucu betikleri pakete eklenemedi.'
grep -q "<app id=\"$BUNDLE_ID\"/>" "$WORK/expanded/Distribution" || fail 'Kurucu tanımı pakete eklenemedi.'
pkgutil --payload-files "$WORK/BStoeq-macOS.pkg" | grep -qx './Applications/BStoeq.app/Contents/MacOS/BStoeq' ||
    fail 'Uygulama kurucu paketine eklenemedi.'
[[ -z "$INSTALLER_IDENTITY" ]] || pkgutil --check-signature "$WORK/BStoeq-macOS.pkg" >/dev/null

mv -f "$WORK/BStoeq-macOS.pkg" "$OUTPUT_DIR/BStoeq-macOS.pkg"
print "Kurucu paketi hazır: $OUTPUT_DIR/BStoeq-macOS.pkg"
print "SHA-256: $(shasum -a 256 "$OUTPUT_DIR/BStoeq-macOS.pkg" | cut -d ' ' -f 1)"
