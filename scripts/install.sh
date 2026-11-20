#!/bin/zsh
set -euo pipefail

fail() { print -ru2 -- "$*"; exit 1; }

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    print 'Kullanım: ./scripts/install.sh'
    print 'Eksik Homebrew, Xcode ve medya araçlarını kurar, BStoeq’i derler ve Uygulamalar klasörüne yükler.'
    exit 0
fi
(( $# == 0 )) || fail 'Kullanım: ./scripts/install.sh'
[[ $(uname -s) == Darwin ]] || fail 'BStoeq macOS gerektirir.'
if [[ $(uname -m) != arm64 ]]; then
    [[ $(/usr/sbin/sysctl -in sysctl.proc_translated) == 1 ]] || fail 'BStoeq için Apple Silicon işlemcili bir Mac gerekir.'
    exec /usr/bin/arch -arm64 /bin/zsh "$0"
fi
os_version=$(/usr/bin/sw_vers -productVersion)
(( ${os_version%%.*} >= 27 )) || fail 'BStoeq için macOS 27.0 veya üstü gerekir.'
(( EUID != 0 )) || fail 'Kurucuyu kendi hesabından, sudo kullanmadan çalıştır.'

project_dir=${0:A:h:h}
work_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/bstoeq-install.XXXXXXXX")
trap '/bin/rm -rf "$work_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
brew_bin=/opt/homebrew/bin/brew
if [[ ! -x $brew_bin ]]; then
    print 'Homebrew indiriliyor. Resmî kurucu, gerekirse Apple Komut Satırı Araçlarını da yükler.'
    /usr/bin/curl --fail --show-error --silent --location --retry 2 --proto '=https' --proto-redir '=https' \
        https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$work_dir/homebrew-install.sh"
    /bin/bash "$work_dir/homebrew-install.sh"
fi
[[ -x $brew_bin ]] || fail 'Homebrew kurulumu tamamlanamadı. Kurucunun çıktısını kontrol edip tekrar çalıştır.'
# Finder and this installer can use Homebrew without changing shell profiles.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH"

select_xcode() {
    local active developer sdk major
    active=$(/usr/bin/xcode-select -p 2>/dev/null) || active=''
    for developer in "${DEVELOPER_DIR:-}" "$active" /Applications/Xcode.app/Contents/Developer /Applications/Xcode*.app/Contents/Developer(N); do
        [[ -n $developer ]] || continue
        [[ $developer == *.app ]] && developer="$developer/Contents/Developer"
        [[ -x $developer/usr/bin/xcodebuild ]] || continue
        sdk=$(/usr/bin/plutil -extract Version raw -o - "$developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/SDKSettings.plist" 2>/dev/null) || continue
        major=${sdk%%.*}
        if [[ $major == <-> ]] && (( major >= 27 )); then
            export DEVELOPER_DIR="$developer"
            return 0
        fi
    done
    return 1
}

if ! select_xcode; then
    print 'macOS 27 SDK’sını içeren tam Xcode gerekiyor. Xcode, Mac App Store üzerinden kurulacak.'
    mas_bin=/opt/homebrew/bin/mas
    [[ -x $mas_bin ]] || "$brew_bin" install mas
    action=get
    [[ ! -d /Applications/Xcode.app ]] || action=update
    if ! "$mas_bin" "$action" 497799835 || ! select_xcode; then
        /usr/bin/open 'macappstore://apps.apple.com/app/id497799835' || true
        fail 'App Store’da hesabına giriş yapıp Xcode kurulumunu veya güncellemesini tamamla. Ardından ./scripts/install.sh komutunu tekrar çalıştır.'
    fi
fi

if ! /usr/bin/xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    print 'Xcode ilk açılış işlemlerini bekliyor. Açılan Xcode penceresinde lisansı incele ve gerekli bileşenleri yükle.'
    /usr/bin/open "${DEVELOPER_DIR:h:h}"
    for attempt in {1..180}; do
        /usr/bin/xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 && break
        /bin/sleep 5
    done
    /usr/bin/xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 || fail 'Xcode ilk açılış işlemlerini tamamladıktan sonra ./scripts/install.sh komutunu tekrar çalıştır.'
fi

# Use the same executable locations as the app when it is launched from Finder.
media_tool() {
    local dir
    for dir in /opt/homebrew/bin /usr/local/bin /opt/local/bin "$HOME/.local/bin" "$HOME/bin"; do
        if [[ -f $dir/$1 && -x $dir/$1 ]]; then
            print -r -- "$dir/$1"
            return 0
        fi
    done
    return 1
}

has_ffmpeg_pair() {
    local binary
    binary=$(media_tool ffmpeg) && [[ -f ${binary:h}/ffprobe && -x ${binary:h}/ffprobe ]]
}

missing=()
if ! media_tool yt-dlp >/dev/null; then
    missing+=(yt-dlp)  # The Homebrew formula also installs Deno.
elif ! media_tool deno >/dev/null; then
    missing+=(deno)
fi
has_ffmpeg_pair || missing+=(ffmpeg)
if (( ${#missing} )); then
    print "Medya araçları kuruluyor: ${(j:, :)missing}"
    "$brew_bin" install "${missing[@]}"
fi
for tool in yt-dlp deno; do
    media_tool "$tool" >/dev/null || fail "$tool bulunamadı. Homebrew çıktısını kontrol edip kurucuyu yeniden çalıştır."
done
has_ffmpeg_pair || fail 'ffmpeg ve ffprobe aynı klasörde bulunamadı. Homebrew çıktısını kontrol edip kurucuyu yeniden çalıştır.'

print 'BStoeq yerel imzayla derleniyor.'
BSTOEQ_OUTPUT_DIR="$work_dir/package" BSTOEQ_SIGNING_IDENTITY=- "$project_dir/scripts/build.sh"
/usr/bin/ditto -x -k "$work_dir/package/BStoeq-macOS.zip" "$work_dir/unpacked"
"$project_dir/scripts/install-app.sh" "$work_dir/unpacked/BStoeq.app"
print 'BStoeq hazır. Açmak için: open /Applications/BStoeq.app'
