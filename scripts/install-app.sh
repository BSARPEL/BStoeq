#!/bin/zsh -f
set -eu

fail() { print -u2 -r -- "$*"; exit 1; }
if (( $# != 1 )); then
    print -u2 'Kullanım: install-app.sh /yol/BStoeq.app'
    exit 64
fi

app_dir=/Applications
target="$app_dir/BStoeq.app"
source_app=${1:a}
[[ ${source_app:t} == BStoeq.app && -d "$source_app" && ! -L "$source_app" ]] ||
    fail 'Kaynak, BStoeq.app adlı bir uygulama paketi olmalı.'
[[ -d "$app_dir" && ! -L "$app_dir" ]] || fail 'Uygulamalar klasörü kullanılamıyor.'
[[ ! "$source_app" -ef "$target" && ${source_app:A} != "$target"/* ]] ||
    fail 'Kurulum için hedef uygulamanın dışında bir kaynak seçin.'

check_bundle() {
    local app="$1" contents="$1/Contents" info="$1/Contents/Info.plist" binary="$1/Contents/MacOS/BStoeq"
    [[ -d "$app" && ! -L "$app" && -d "$contents" && ! -L "$contents" &&
       -f "$info" && ! -L "$info" && ! -L "$contents/MacOS" && -f "$binary" && -x "$binary" && ! -L "$binary" ]] &&
        [[ $(/usr/bin/plutil -extract CFBundleIdentifier raw "$info") == local.barlet.app &&
           $(/usr/bin/plutil -extract CFBundleExecutable raw "$info") == BStoeq &&
           $(/usr/bin/plutil -extract CFBundlePackageType raw "$info") == APPL ]] &&
        /usr/bin/codesign --verify --deep --strict --all-architectures "$app"
}

require_quit() {
    if /usr/bin/pgrep -qx BStoeq; then
        fail 'BStoeq çalışıyor. Menü çubuğundan uygulamadan çıkıp kurulumu yeniden başlatın.'
    else
        (( $? == 1 )) || fail 'Çalışan uygulamalar kontrol edilemedi.'
    fi
}

check_bundle "$source_app" || fail 'Kaynak paketin kimliği veya kod imzası doğrulanamadı.'
require_quit
old_id=''
if [[ -e "$target" || -L "$target" ]]; then
    check_bundle "$target" || fail 'Hedefteki öğe geçerli bir BStoeq paketi olarak doğrulanamadı.'
    old_id=$(/usr/bin/stat -f '%d:%i' "$target")
fi

# Stage on the destination volume so installation can use one atomic rename.
stage=$(/usr/bin/mktemp -d "$app_dir/.BStoeq-install.XXXXXXXX") ||
    fail 'Uygulamalar klasörüne yazılamadı. Kurulumu bu klasöre yazabilen bir yönetici hesabıyla çalıştırın.'
staged="$stage/BStoeq.app"
preserve_stage=0
cleanup() {
    if (( preserve_stage )); then
        print -u2 -r -- "Kurtarma için saklanan klasör: $stage"
    else
        /bin/rm -rf "$stage"
    fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
/usr/bin/ditto "$source_app" "$staged"
check_bundle "$staged" || fail 'Kopyalanan uygulama doğrulanamadı.'

# macOS renamex_np swaps complete bundles on update. Exclusive rename refuses
# to replace anything that appears at an initially empty destination.
rename_bundle() {
    /usr/bin/osascript -l JavaScript - "$staged" "$target" "$1" <<'JXA'
ObjC.bindFunction('renamex_np', ['int', ['char *', 'char *', 'unsigned int']])
function run([source, target, mode]) {
    const flag = mode === 'swap' ? 2 : 4
    if ($.renamex_np(source, target, flag) !== 0) throw Error('Uygulama taşınamadı.')
}
JXA
}

require_quit
if [[ -n "$old_id" ]]; then
    [[ $(/usr/bin/stat -f '%d:%i' "$target") == "$old_id" ]] ||
        fail 'Hedef kurulum sırasında değişti. Yeniden deneyin.'
    new_id=$(/usr/bin/stat -f '%d:%i' "$staged")
    preserve_stage=1
    if ! rename_bundle swap; then
        # A rejected swap leaves both entries intact.
        if [[ $(/usr/bin/stat -f '%d:%i' "$staged") == "$new_id" ]]; then preserve_stage=0; fi
        fail 'Uygulama değiştirilemedi.'
    fi
    if [[ $(/usr/bin/stat -f '%d:%i' "$staged") != "$old_id" ]] || ! check_bundle "$target"; then
        [[ $(/usr/bin/stat -f '%d:%i' "$target") == "$new_id" ]] ||
            fail 'Hedef başka bir işlem tarafından değiştirildi.'
        rename_bundle swap || fail 'Önceki uygulama geri yüklenemedi.'
        preserve_stage=0
        fail 'Kurulum tamamlanamadı. Önceki uygulama geri yüklendi.'
    fi
    preserve_stage=0
else
    rename_bundle exclusive || fail 'Hedefe kurulum yapılamadı.'
fi
print -r -- "BStoeq yüklendi: $target"
