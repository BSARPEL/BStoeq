#!/bin/zsh
set -euo pipefail
# Run the cleanup trap even if a nested command fails under errexit.
setopt POSIX_TRAPS
cd "${0:A:h:h}"

# Puts BStoeq.app in a disk image (.dmg) beside a link to the Applications folder, so
# it can be installed by dragging. Without an argument the app is built first with
# build.sh; pass an existing BStoeq.app or BStoeq-macOS.zip to package that copy.

fail() { print -ru2 -- "$*"; exit 1; }
(( $# <= 1 )) || fail 'Kullanım: ./scripts/package-dmg.sh [BStoeq.app | BStoeq-macOS.zip]'

OUTPUT_DIR="${BSTOEQ_OUTPUT_DIR:-$PWD/dist}"
mkdir -p "$OUTPUT_DIR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bstoeq-dmg.XXXXXXXX")"
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
   "$(plutil -extract CFBundleIdentifier raw "$INFO")" == local.barlet.app ]] ||
    fail 'Kaynak, BStoeq.app adlı uygulama paketi olmalı.'
codesign --verify --deep --strict --all-architectures "$APP" || fail 'Uygulamanın kod imzası doğrulanamadı.'
VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO")"

ROOT="$WORK/root"
mkdir "$ROOT"
ditto "$APP" "$ROOT/BStoeq.app"
# A copy taken from a downloaded ZIP must not carry its quarantine into the image.
xattr -dr com.apple.quarantine "$ROOT/BStoeq.app" 2>/dev/null || true
ln -s /Applications "$ROOT/Applications"
hdiutil create -quiet -volname "BStoeq $VERSION" -srcfolder "$ROOT" -fs APFS -format UDZO -ov "$WORK/BStoeq-macOS.dmg"
hdiutil verify -quiet "$WORK/BStoeq-macOS.dmg"

# The image must hold the app with a valid signature and the Applications link.
MOUNT="$WORK/mount"
mkdir "$MOUNT"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT" "$WORK/BStoeq-macOS.dmg"
{
    codesign --verify --deep --strict "$MOUNT/BStoeq.app" &&
        [[ "$(readlink "$MOUNT/Applications")" == /Applications ]]
} || { hdiutil detach -quiet "$MOUNT"; fail 'Disk görüntüsü doğrulanamadı.'; }
hdiutil detach -quiet "$MOUNT"

mv -f "$WORK/BStoeq-macOS.dmg" "$OUTPUT_DIR/BStoeq-macOS.dmg"
print "Disk görüntüsü hazır: $OUTPUT_DIR/BStoeq-macOS.dmg"
print "SHA-256: $(shasum -a 256 "$OUTPUT_DIR/BStoeq-macOS.dmg" | cut -d ' ' -f 1)"
