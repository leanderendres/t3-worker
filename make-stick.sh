#!/usr/bin/env bash
# make-stick.sh: build the unattended t3-worker installer on a Mac.
#
#  1. downloads the current Debian 13 amd64 netinst ISO (cached, SHA256 and,
#     if gpg is available, the signature of SHA256SUMS are verified)
#  2. renders installer/preseed.cfg (password hash, optional Wi-Fi) and embeds
#     it, the install helpers, this repository and the Mac's SSH public key
#  3. adds a default "t3-worker" boot entry for UEFI (GRUB) and BIOS (isolinux)
#     with: auto=true priority=critical preseed/file=/cdrom/preseed.cfg
#  4. writes the ISO to a USB stick with dd (skipped with --iso-only)
#
# The stick writer refuses internal disks, disks larger than 64 GB and anything
# whose name mentions "T7", and requires typing the disk identifier.
#
# Works with the macOS system bash (3.2). Needs: curl, xorriso (brew install
# xorriso), openssl with `passwd -6` (brew install openssl@3), optionally gpg.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
CACHE_DIR=${T3W_CACHE_DIR:-$HOME/.cache/t3-worker}
MIRROR=${T3W_DEBIAN_MIRROR:-https://cdimage.debian.org/debian-cd/current/amd64/iso-cd}
MAX_STICK_BYTES=64000000000
# Debian CD signing keys, see https://www.debian.org/CD/verify
DEBIAN_CD_KEYS="10460DAD76165AD81FBC0CE9988021A964E6EA7D DF9B9C49EAA9298432589D76DA87E80D6294BE9B F41D30342F3546695F65C66942468F4009EA8AC3"

ISO_ONLY=0
KEEP_ISO=0
OFFLINE=0
WIFI=0
IN_ISO=""
OUT_ISO=""
PUBKEY=${T3W_PUBKEY:-$HOME/.ssh/id_ed25519.pub}
DISK=""
CHECK_DISK=""

usage() {
    cat <<'EOF'
Aufruf: ./make-stick.sh [Optionen]

  --iso-only        nur das ISO bauen, keinen Stick beschreiben
  --keep-iso        das gebaute ISO nach dem Schreiben behalten (Standard: löschen)
  --disk diskN      Ziel-Stick vorwählen (wird trotzdem geprüft und bestätigt)
  --check-disk diskN
                    nur die Sicherheitsprüfung für diskN ausführen, nichts schreiben
  --wifi            WLAN-Name und Passwort abfragen und ins ISO einbetten
  --pubkey DATEI    SSH-Public-Key (Standard: ~/.ssh/id_ed25519.pub)
  --iso DATEI       vorhandenes Debian-netinst-ISO verwenden (wird geprüft)
  --out DATEI       Ziel-ISO (Standard: ~/.cache/t3-worker/t3-worker-<debian>.iso)
  --offline         SHA256SUMS nicht neu laden, nur den Cache verwenden
  -h, --help        diese Hilfe

Umgebung: T3W_PASSWORD_HASH (SHA-512-crypt, überspringt die Passwortabfrage),
T3W_WIFI_SSID / T3W_WIFI_PSK (mit --wifi), T3W_CACHE_DIR.
EOF
}

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mFehler:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --iso-only) ISO_ONLY=1 ;;
        --keep-iso) KEEP_ISO=1 ;;
        --offline) OFFLINE=1 ;;
        --wifi) WIFI=1 ;;
        --disk) DISK=${2:?}; shift ;;
        --check-disk) CHECK_DISK=${2:?}; shift ;;
        --pubkey) PUBKEY=${2:?}; shift ;;
        --iso) IN_ISO=${2:?}; shift ;;
        --out) OUT_ISO=${2:?}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unbekannte Option: $1" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# USB stick safety check (also usable alone via --check-disk)
# ---------------------------------------------------------------------------
plist_get() { # plist_get KEY FILE
    plutil -extract "$1" raw -o - "$2" 2>/dev/null || true
}

check_disk() {
    local disk=$1 info internal whole size media ioname removable virt proto names
    case "$disk" in
        /dev/*) disk=${disk#/dev/} ;;
    esac
    case "$disk" in
        disk[0-9]|disk[0-9][0-9]) ;;
        *) echo "Ungültige Kennung '$disk' (erwartet z. B. disk6, ohne Partition)."; return 1 ;;
    esac
    command -v diskutil >/dev/null || { echo "diskutil fehlt (nur auf macOS)."; return 1; }
    info=$(mktemp)
    if ! diskutil info -plist "$disk" >"$info" 2>/dev/null; then
        rm -f "$info"; echo "$disk existiert nicht."; return 1
    fi
    internal=$(plist_get Internal "$info")
    whole=$(plist_get WholeDisk "$info")
    size=$(plist_get TotalSize "$info")
    [ -n "$size" ] || size=$(plist_get Size "$info")
    media=$(plist_get MediaName "$info")
    ioname=$(plist_get IORegistryEntryName "$info")
    removable=$(plist_get RemovableMediaOrExternalDevice "$info")
    virt=$(plist_get VirtualOrPhysical "$info")
    proto=$(plist_get BusProtocol "$info")
    rm -f "$info"
    names=$(diskutil list "$disk" 2>/dev/null || true)

    echo "  Kennung:   $disk"
    echo "  Name:      ${media:-?} (${ioname:-?})"
    echo "  Größe:     $(( ${size:-0} / 1000000000 )) GB"
    echo "  Anschluss: ${proto:-?}, intern: ${internal:-?}"

    [ "$whole" = "true" ] || { echo "ABGELEHNT: $disk ist kein ganzer Datenträger."; return 1; }
    [ "$internal" = "false" ] || { echo "ABGELEHNT: $disk ist ein internes Laufwerk."; return 1; }
    [ "$removable" = "true" ] || { echo "ABGELEHNT: $disk ist nicht als extern/entfernbar gemeldet."; return 1; }
    [ "$virt" != "Virtual" ] || { echo "ABGELEHNT: $disk ist ein virtuelles Laufwerk."; return 1; }
    case "${size:-x}" in
        *[!0-9]*|'') echo "ABGELEHNT: Größe von $disk unbekannt."; return 1 ;;
    esac
    [ "$size" -le "$MAX_STICK_BYTES" ] || { echo "ABGELEHNT: $disk ist größer als 64 GB."; return 1; }
    if printf '%s\n%s\n%s\n' "$media" "$ioname" "$names" | grep -qi 't7'; then
        echo "ABGELEHNT: $disk trägt 'T7' im Namen (Samsung T7 wird nie beschrieben)."
        return 1
    fi
    return 0
}

if [ -n "$CHECK_DISK" ]; then
    if check_disk "$CHECK_DISK"; then
        echo "ZULÄSSIG: $CHECK_DISK würde als Installationsstick akzeptiert (nichts geschrieben)."
        exit 0
    fi
    exit 1
fi

# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------
command -v curl >/dev/null || die "curl fehlt."
command -v xorriso >/dev/null || die "xorriso fehlt: brew install xorriso"

OPENSSL=""
for o in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl openssl; do
    if command -v "$o" >/dev/null 2>&1 && "$o" passwd -6 -salt probe probe >/dev/null 2>&1; then
        OPENSSL=$o; break
    fi
done

sha256_of() {
    if command -v shasum >/dev/null; then shasum -a 256 "$1" | awk '{print $1}'
    else sha256sum "$1" | awk '{print $1}'; fi
}
md5_of() {
    if command -v md5 >/dev/null; then md5 -q "$1"
    else md5sum "$1" | awk '{print $1}'; fi
}

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/t3-worker-stick.XXXXXX")
chmod 700 "$STAGE"
GNUPG_TMP=""
cleanup() {
    # gpg starts dirmngr/gpg-agent for the temporary keyring: stop them again
    if [ -n "$GNUPG_TMP" ]; then GNUPGHOME=$GNUPG_TMP gpgconf --kill all >/dev/null 2>&1 || true; fi
    chmod -R u+w "$STAGE" 2>/dev/null || true
    rm -rf "$STAGE"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 1. Debian ISO
# ---------------------------------------------------------------------------
mkdir -p "$CACHE_DIR"

verify_sums_signature() {
    local sums=$1 sig=$2 gh
    if ! command -v gpg >/dev/null; then
        warn "gpg nicht installiert: Signatur von SHA256SUMS nicht geprüft (nur Prüfsumme)."
        return 0
    fi
    gh=$(mktemp -d "$STAGE/gnupg.XXXXXX")
    chmod 700 "$gh"
    GNUPG_TMP=$gh
    local key server imported=0 fpr
    for key in $DEBIAN_CD_KEYS; do
        for server in hkps://keyring.debian.org hkps://keyserver.ubuntu.com; do
            if GNUPGHOME=$gh gpg -q --batch --keyserver "$server" --recv-keys "$key" >/dev/null 2>&1; then
                imported=$((imported + 1)); break
            fi
        done
    done
    if [ "$imported" -eq 0 ]; then
        warn "Debian-Signaturschlüssel nicht abrufbar: Signatur nicht geprüft (nur Prüfsumme)."
        return 0
    fi
    # Only accept a valid signature by one of the pinned fingerprints
    fpr=$(GNUPGHOME=$gh gpg --batch --status-fd 1 --verify "$sig" "$sums" 2>/dev/null | awk '$2 == "VALIDSIG" { print $NF; exit }')
    case " $DEBIAN_CD_KEYS " in
        *" $fpr "*) [ -n "$fpr" ] && ok "Signatur von SHA256SUMS gültig (Debian CD signing key ${fpr: -16})" ;;
        *) die "Signatur von SHA256SUMS ungültig oder unbekannter Schlüssel. Abbruch." ;;
    esac
    [ -n "$fpr" ] || die "Signatur von SHA256SUMS ungültig. Abbruch."
}

SUMS="$CACHE_DIR/SHA256SUMS"
if [ "$OFFLINE" = 0 ]; then
    say "Lade aktuelle Debian-Prüfsummen ..."
    curl -fsSL -o "$STAGE/SHA256SUMS" "$MIRROR/SHA256SUMS" || die "SHA256SUMS nicht ladbar ($MIRROR)."
    if curl -fsSL -o "$STAGE/SHA256SUMS.sign" "$MIRROR/SHA256SUMS.sign"; then
        verify_sums_signature "$STAGE/SHA256SUMS" "$STAGE/SHA256SUMS.sign"
        cp "$STAGE/SHA256SUMS.sign" "$CACHE_DIR/SHA256SUMS.sign"
    else
        warn "SHA256SUMS.sign nicht ladbar: Signatur nicht geprüft."
    fi
    cp "$STAGE/SHA256SUMS" "$SUMS"
fi
[ -f "$SUMS" ] || die "Keine SHA256SUMS im Cache ($SUMS). Ohne --offline starten."

if [ -n "$IN_ISO" ]; then
    [ -f "$IN_ISO" ] || die "ISO nicht gefunden: $IN_ISO"
    ISO_NAME=$(basename "$IN_ISO")
    ISO=$IN_ISO
else
    ISO_NAME=$(awk '$2 ~ /^debian-[0-9.]+-amd64-netinst\.iso$/ { print $2; exit }' "$SUMS")
    [ -n "$ISO_NAME" ] || die "Kein amd64-netinst-ISO in SHA256SUMS gefunden."
    ISO="$CACHE_DIR/$ISO_NAME"
fi
EXPECTED=$(awk -v n="$ISO_NAME" '$2 == n { print $1; exit }' "$SUMS")
[ -n "$EXPECTED" ] || die "$ISO_NAME steht nicht in SHA256SUMS."

if [ -f "$ISO" ] && [ "$(sha256_of "$ISO")" = "$EXPECTED" ]; then
    ok "ISO im Cache, Prüfsumme stimmt: $ISO"
else
    [ -z "$IN_ISO" ] || die "Prüfsumme von $IN_ISO stimmt nicht."
    [ "$OFFLINE" = 0 ] || die "ISO fehlt im Cache und --offline ist gesetzt."
    say "Lade $ISO_NAME (ca. 800 MB) ..."
    curl -fL --progress-bar -o "$ISO.part" "$MIRROR/$ISO_NAME"
    [ "$(sha256_of "$ISO.part")" = "$EXPECTED" ] || { rm -f "$ISO.part"; die "Prüfsumme des Downloads falsch."; }
    mv "$ISO.part" "$ISO"
    ok "ISO geladen und geprüft: $ISO"
fi
DEBIAN_VERSION=$(printf '%s\n' "$ISO_NAME" | sed -E 's/^debian-([0-9.]+)-amd64-netinst\.iso$/\1/')
[ -n "$OUT_ISO" ] || OUT_ISO="$CACHE_DIR/t3-worker-debian-$DEBIAN_VERSION-amd64.iso"

# ---------------------------------------------------------------------------
# 2. SSH key, password, Wi-Fi
# ---------------------------------------------------------------------------
if [ ! -f "$PUBKEY" ]; then
    [ "$PUBKEY" = "$HOME/.ssh/id_ed25519.pub" ] || die "Public Key nicht gefunden: $PUBKEY"
    echo
    echo "Auf diesem Mac gibt es noch keinen SSH-Schlüssel (~/.ssh/id_ed25519)."
    echo "Er wird gebraucht, damit du dich ohne Passwort am t3-worker anmelden kannst."
    printf 'Jetzt einen neuen Schlüssel erzeugen? [j/N] '
    read -r answer
    case "$answer" in j|J|ja|Ja|y|Y) ;; *) die "Ohne SSH-Schlüssel geht es nicht weiter." ;; esac
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -a 100 -f "$HOME/.ssh/id_ed25519" -C "$(id -un)@$(hostname -s)"
fi
ssh-keygen -l -f "$PUBKEY" >/dev/null 2>&1 || die "$PUBKEY ist kein gültiger SSH-Public-Key."
ok "SSH-Key: $(ssh-keygen -l -f "$PUBKEY" | awk '{print $1, $2, $NF}')"

HASH=${T3W_PASSWORD_HASH:-}
if [ -z "$HASH" ]; then
    [ -n "$OPENSSL" ] || die "openssl mit 'passwd -6' fehlt: brew install openssl@3"
    echo
    echo "Passwort für den Benutzer 'leander' auf dem t3-worker (für sudo, Cockpit und die"
    echo "lokale Konsole; SSH geht nur per Schlüssel). Es wird nur als Hash gespeichert."
    while :; do
        read -r -s -p "Passwort: " pw1; echo
        read -r -s -p "Wiederholen: " pw2; echo
        [ "$pw1" = "$pw2" ] || { warn "Stimmt nicht überein."; continue; }
        [ ${#pw1} -ge 8 ] || { warn "Mindestens 8 Zeichen."; continue; }
        break
    done
    HASH=$(printf '%s' "$pw1" | "$OPENSSL" passwd -6 -stdin)
    unset pw1 pw2
fi
case "$HASH" in
    \$6\$*) ;;
    *) die "Passwort-Hash muss SHA-512-crypt sein (beginnt mit \$6\$)." ;;
esac

WIFI_BLOCK=""
if [ "$WIFI" = 1 ]; then
    SSID=${T3W_WIFI_SSID:-}
    PSK=${T3W_WIFI_PSK:-}
    [ -n "$SSID" ] || read -r -p "WLAN-Name (SSID): " SSID
    [ -n "$PSK" ] || { read -r -s -p "WLAN-Passwort (WPA2/WPA3-Personal): " PSK; echo; }
    [ -n "$SSID" ] && [ ${#PSK} -ge 8 ] || die "SSID oder Passwort ungültig."
    WIFI_BLOCK=$(printf '%s\n' \
        "d-i netcfg/wireless_show_essids select manual" \
        "d-i netcfg/wireless_essid string $SSID" \
        "d-i netcfg/wireless_essid_again string $SSID" \
        "d-i netcfg/wireless_security_type select wpa" \
        "d-i netcfg/wireless_wpa string $PSK")
    unset PSK
fi

# ---------------------------------------------------------------------------
# 3. Stage the files that go into the ISO
# ---------------------------------------------------------------------------
say "Bereite Installer-Dateien vor ..."
umask 077

# subst_literal FILE TOKEN VALUE: replace a literal token (no regex, no & issues)
subst_literal() {
    TOKEN=$2 VALUE=$3 awk '
        BEGIN { t = ENVIRON["TOKEN"]; v = ENVIRON["VALUE"] }
        { out = ""; line = $0
          while ((i = index(line, t)) > 0) { out = out substr(line, 1, i - 1) v; line = substr(line, i + length(t)) }
          print out line }' "$1" >"$1.new"
    mv "$1.new" "$1"
}

cp "$REPO_DIR/installer/preseed.cfg" "$STAGE/preseed.cfg"
subst_literal "$STAGE/preseed.cfg" "@@PASSWORD_HASH@@" "$HASH"
subst_literal "$STAGE/preseed.cfg" "#@@WIFI@@" "$WIFI_BLOCK"
grep -q '@@' "$STAGE/preseed.cfg" && die "Platzhalter in preseed.cfg nicht ersetzt."

mkdir -p "$STAGE/t3-worker/repo"
cp "$REPO_DIR/installer/select-disk.sh" "$REPO_DIR/installer/late.sh" "$STAGE/t3-worker/"
cp "$PUBKEY" "$STAGE/t3-worker/authorized_keys"
if git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    (cd "$REPO_DIR" && git ls-files -co --exclude-standard -z | tar --null -T - -cf -) | tar -xf - -C "$STAGE/t3-worker/repo"
    git -C "$REPO_DIR" rev-parse --short HEAD >"$STAGE/t3-worker/repo/.stick-revision" 2>/dev/null || echo "uncommitted" >"$STAGE/t3-worker/repo/.stick-revision"
else
    (cd "$REPO_DIR" && tar --exclude ./build --exclude '*.iso' -cf - .) | tar -xf - -C "$STAGE/t3-worker/repo"
fi
chmod -R go+rX "$STAGE/t3-worker" "$STAGE/preseed.cfg"
chmod 0644 "$STAGE/preseed.cfg"

# Boot configuration from the original ISO
xorriso -osirrox on -indev "$ISO" \
    -extract /boot/grub/grub.cfg "$STAGE/grub.cfg" \
    -extract /isolinux/isolinux.cfg "$STAGE/isolinux.cfg" \
    -extract /isolinux/menu.cfg "$STAGE/menu.cfg" \
    -extract /isolinux/gtk.cfg "$STAGE/gtk.cfg" \
    -extract /md5sum.txt "$STAGE/md5sum.txt" >/dev/null 2>&1 || die "Boot-Konfiguration nicht aus dem ISO lesbar."
chmod u+w "$STAGE"/*.cfg "$STAGE/md5sum.txt"

BOOT_ARGS="auto=true priority=critical preseed/file=/cdrom/preseed.cfg locale=de_DE.UTF-8 keymap=de hostname=t3-worker domain="

# UEFI: GRUB entry first, default, 10 s timeout
awk -v args="$BOOT_ARGS" '
    !done && /^menuentry / {
        print "set default=0"
        print "set timeout=10"
        print "menuentry --hotkey=t '\''t3-worker: automatische Installation (nur interne SSD)'\'' {"
        print "    set background_color=black"
        print "    linux    /install.amd/vmlinuz " args " vga=788 --- quiet"
        print "    initrd   /install.amd/initrd.gz"
        print "}"
        done = 1
    }
    { print }' "$STAGE/grub.cfg" >"$STAGE/grub.cfg.new"
mv "$STAGE/grub.cfg.new" "$STAGE/grub.cfg"

# BIOS: isolinux entry, default, 10 s timeout
cat >"$STAGE/t3worker.cfg" <<EOF
label t3worker
	menu label ^t3-worker: automatische Installation (nur interne SSD)
	menu default
	kernel /install.amd/vmlinuz
	append $BOOT_ARGS vga=788 initrd=/install.amd/initrd.gz --- quiet
EOF
sed -e 's/^timeout 0$/timeout 100/' "$STAGE/isolinux.cfg" >"$STAGE/isolinux.cfg.new" && mv "$STAGE/isolinux.cfg.new" "$STAGE/isolinux.cfg"
awk '/^include gtk.cfg$/ && !done { print "include t3worker.cfg"; done = 1 } { print }' "$STAGE/menu.cfg" >"$STAGE/menu.cfg.new" && mv "$STAGE/menu.cfg.new" "$STAGE/menu.cfg"
grep -v '^[[:space:]]*menu default$' "$STAGE/gtk.cfg" >"$STAGE/gtk.cfg.new" && mv "$STAGE/gtk.cfg.new" "$STAGE/gtk.cfg"
sed -e 's/^default installgui$/default t3worker/' "$STAGE/gtk.cfg" >"$STAGE/gtk.cfg.new" && mv "$STAGE/gtk.cfg.new" "$STAGE/gtk.cfg"

grep -q 'preseed/file=/cdrom/preseed.cfg' "$STAGE/grub.cfg" || die "grub.cfg: Eintrag nicht eingefügt (ISO-Layout unerwartet)."
grep -q '^timeout 100$' "$STAGE/isolinux.cfg" || die "isolinux.cfg: Timeout nicht gesetzt (ISO-Layout unerwartet)."
grep -q '^include t3worker.cfg$' "$STAGE/menu.cfg" || die "menu.cfg: Eintrag nicht eingefügt (ISO-Layout unerwartet)."

# Keep md5sum.txt consistent for the installer's integrity check
update_md5() { # update_md5 LOCALFILE ISOPATH
    local sum rel="./${2#/}"
    sum=$(md5_of "$1")
    awk -v rel="$rel" '$2 != rel' "$STAGE/md5sum.txt" >"$STAGE/md5sum.txt.new"
    printf '%s  %s\n' "$sum" "$rel" >>"$STAGE/md5sum.txt.new"
    mv "$STAGE/md5sum.txt.new" "$STAGE/md5sum.txt"
}
update_md5 "$STAGE/grub.cfg" /boot/grub/grub.cfg
update_md5 "$STAGE/isolinux.cfg" /isolinux/isolinux.cfg
update_md5 "$STAGE/menu.cfg" /isolinux/menu.cfg
update_md5 "$STAGE/gtk.cfg" /isolinux/gtk.cfg
update_md5 "$STAGE/t3worker.cfg" /isolinux/t3worker.cfg
update_md5 "$STAGE/preseed.cfg" /preseed.cfg
chmod 0644 "$STAGE"/*.cfg "$STAGE/md5sum.txt"

# ---------------------------------------------------------------------------
# 4. Build the ISO
# ---------------------------------------------------------------------------
say "Baue $OUT_ISO ..."
rm -f "$OUT_ISO"
xorriso -indev "$ISO" -outdev "$OUT_ISO" \
    -boot_image any replay \
    -map "$STAGE/preseed.cfg" /preseed.cfg \
    -map "$STAGE/t3-worker" /t3-worker \
    -map "$STAGE/grub.cfg" /boot/grub/grub.cfg \
    -map "$STAGE/isolinux.cfg" /isolinux/isolinux.cfg \
    -map "$STAGE/menu.cfg" /isolinux/menu.cfg \
    -map "$STAGE/gtk.cfg" /isolinux/gtk.cfg \
    -map "$STAGE/t3worker.cfg" /isolinux/t3worker.cfg \
    -map "$STAGE/md5sum.txt" /md5sum.txt \
    >"$STAGE/xorriso.log" 2>&1 || { cat "$STAGE/xorriso.log" >&2; die "xorriso ist fehlgeschlagen."; }
chmod 600 "$OUT_ISO"

# Verify the result
mkdir "$STAGE/verify"
xorriso -osirrox on -indev "$OUT_ISO" \
    -extract /preseed.cfg "$STAGE/verify/preseed.cfg" \
    -extract /boot/grub/grub.cfg "$STAGE/verify/grub.cfg" \
    -extract /isolinux/t3worker.cfg "$STAGE/verify/t3worker.cfg" \
    -extract /t3-worker/select-disk.sh "$STAGE/verify/select-disk.sh" \
    -extract /t3-worker/repo/setup.sh "$STAGE/verify/setup.sh" >/dev/null 2>&1 || die "Prüfung: Dateien fehlen im neuen ISO."
grep -q "preseed/file=/cdrom/preseed.cfg" "$STAGE/verify/grub.cfg" || die "Prüfung: GRUB-Eintrag fehlt."
grep -q "preseed/file=/cdrom/preseed.cfg" "$STAGE/verify/t3worker.cfg" || die "Prüfung: isolinux-Eintrag fehlt."
grep -q "^d-i partman/early_command string sh /cdrom/t3-worker/select-disk.sh" "$STAGE/verify/preseed.cfg" || die "Prüfung: Preseed unvollständig."
if grep -q '@@' "$STAGE/verify/preseed.cfg"; then die "Prüfung: Platzhalter im Preseed."; fi
xorriso -indev "$OUT_ISO" -report_el_torito plain 2>/dev/null | grep -q 'UEFI' || die "Prüfung: UEFI-Bootimage fehlt."
ok "ISO geprüft: Preseed, Boot-Einträge (UEFI + BIOS), Setup-Repo und SSH-Key enthalten"
echo "  $OUT_ISO ($(( $(wc -c <"$OUT_ISO") / 1000000 )) MB)"

if [ "$ISO_ONLY" = 1 ]; then
    echo
    echo "Fertig (--iso-only). Kein Datenträger wurde beschrieben."
    echo
    printf '\033[33mAchtung:\033[0m Das ISO enthält den Passwort-Hash für leander%s.\n' \
        "$([ "$WIFI" = 1 ] && echo ' und das WLAN-Passwort im Klartext')"
    echo "Nicht weitergeben und nach dem Schreiben löschen: rm -P \"$OUT_ISO\""
    exit 0
fi

# ---------------------------------------------------------------------------
# 5. Write the USB stick
# ---------------------------------------------------------------------------
command -v diskutil >/dev/null || die "Stick schreiben geht nur auf macOS. ISO liegt hier: $OUT_ISO"
echo
say "Externe Datenträger:"
diskutil list external physical || true
if [ -z "$DISK" ]; then
    read -r -p "Kennung des USB-Sticks (z. B. disk6): " DISK
fi
DISK=${DISK#/dev/}
echo
check_disk "$DISK" || die "Dieser Datenträger wird nicht beschrieben."
echo
echo "ALLE Daten auf $DISK werden gelöscht."
read -r -p "Zur Bestätigung die Kennung exakt eintippen ($DISK): " typed
[ "$typed" = "$DISK" ] || die "Eingabe stimmt nicht. Abbruch, nichts geschrieben."

diskutil unmountDisk "/dev/$DISK"
say "Schreibe ISO auf /dev/r$DISK (sudo-Passwort des Macs) ..."
if ! sudo dd if="$OUT_ISO" of="/dev/r$DISK" bs=4m status=progress 2>/dev/null; then
    sudo dd if="$OUT_ISO" of="/dev/r$DISK" bs=4m
fi
sync
diskutil eject "/dev/$DISK" || true
if [ "$KEEP_ISO" = 1 ]; then
    warn "ISO behalten (--keep-iso). Es enthält Geheimnisse: $OUT_ISO"
else
    rm -P "$OUT_ISO" 2>/dev/null || rm -f "$OUT_ISO"
    ok "Gebautes ISO gelöscht (enthielt Passwort-Hash/WLAN-Passwort)."
fi
ok "Stick fertig. Weiter mit README.md, Abschnitt 'Install'."
