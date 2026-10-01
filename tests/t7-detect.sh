#!/usr/bin/env bash
# Function-level checks for the T7 logic (NTFS or exFAT) without a real disk:
# blkid is stubbed, fstab is a temp file, the exFAT boot sector an image file.
# Needs no root. Run by tests/container-check.sh, or directly: tests/t7-detect.sh
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
export T3W_ROOT=$REPO NO_COLOR=1 DRY_RUN=0
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"
# shellcheck source=lib/phases-storage.sh
. "$REPO/lib/phases-storage.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILED=0
check() { # check NAME GOT WANT
    if [ "$2" = "$3" ]; then
        printf '%-48s %s\n' "$1" OK
    else
        printf '%-48s %s\n' "$1" FEHLER
        printf '    erwartet: %s\n    bekommen: %s\n' "$3" "$2"
        FAILED=1
    fi
}

# --- stubbed blkid: BLKID_DEVS holds "device type label" lines ------------------
BLKID_DEVS=''
blkid() {
    local want='' field='' out='' dev='' d t l
    while [ $# -gt 0 ]; do
        case "$1" in
            -t) [ -z "$want" ] || { echo "blkid: Can only search for one NAME=value pair" >&2; return 4; }
                want=$2; shift ;;
            -s) field=$2; shift ;;
            -o) out=$2; shift ;;
            *) dev=$1 ;;
        esac
        shift
    done
    while read -r d t l; do
        [ -n "$d" ] || continue
        if [ -n "$want" ]; then
            [ "$out" = device ] && [ "LABEL=$l" = "$want" ] && echo "$d"
        elif [ "$d" = "$dev" ] && [ "$field" = TYPE ]; then
            echo "$t"
            return 0
        fi
    done <<<"$BLKID_DEVS"
    [ -n "$want" ] || return 2
}

BLKID_DEVS='/dev/sdc1 exfat T7 Shield'
check "find_t7 exFAT" "$(find_t7)" /dev/sdc1
check "t7_fstype exFAT" "$(t7_fstype /dev/sdc1)" exfat
BLKID_DEVS='/dev/sdc1 ntfs T7 Shield'
check "find_t7 NTFS" "$(find_t7)" /dev/sdc1
check "t7_fstype NTFS" "$(t7_fstype /dev/sdc1)" ntfs
BLKID_DEVS='/dev/sdc1 ext4 T7 Shield'
check "find_t7 lehnt ext4 mit T7-Namen ab" "$(find_t7 || echo keine)" keine
BLKID_DEVS=$'/dev/sdc1 vfat T7 Shield\n/dev/sdd1 exfat T7 Shield'
check "find_t7 nimmt nur NTFS/exFAT" "$(find_t7)" /dev/sdd1
BLKID_DEVS='/dev/sdc1 exfat Other'
check "find_t7 anderer Name" "$(find_t7 || echo keine)" keine
BLKID_DEVS=''
check "find_t7 ohne Laufwerk" "$(find_t7 || echo keine)" keine

# --- fstab line per type ----------------------------------------------------------
check "fstab-Zeile exFAT" "$(storage_t7_fstab 12C3-A890 exfat 1000 1000)" \
    "UUID=12C3-A890 /srv/t7 exfat uid=1000,gid=1000,umask=002,iocharset=utf8,noatime,noauto,nofail,x-systemd.device-timeout=10s 0 0"
check "fstab-Zeile NTFS" "$(storage_t7_fstab 0123456789ABCDEF ntfs 1000 1000)" \
    "UUID=0123456789ABCDEF /srv/t7 ntfs3 uid=1000,gid=1000,umask=002,iocharset=utf8,windows_names,noatime,nofail,x-systemd.device-timeout=10s 0 0"
check "fstab-Zeile unbekannter Typ" "$(storage_t7_fstab X ext4 1000 1000 || echo abgelehnt)" abgelehnt

# --- old entries are replaced, not duplicated -------------------------------------
FSTAB=$TMP/fstab
cat >"$FSTAB" <<'EOF'
UUID=root / btrfs defaults 0 0
UUID=AAAA-BBBB /srv/t7 exfat defaults 0 0
# >>> t3-worker storage >>>
UUID=tm /srv/timemachine ext4 defaults,noatime,nofail 0 2
UUID=0123456789ABCDEF /srv/t7 ntfs3 uid=1000,gid=1000,windows_names,nofail 0 0
# <<< t3-worker storage <<<
EOF
apply_fstab() {
    storage_fstab_retire "$FSTAB" /srv/t7 >/dev/null
    ensure_block "$FSTAB" "t3-worker storage" >/dev/null <<EOF
UUID=tm /srv/timemachine ext4 defaults,noatime,nofail 0 2
$(storage_t7_fstab 12C3-A890 exfat 1000 1000)
EOF
}
apply_fstab
check "fstab: genau ein aktiver T7-Eintrag" "$(awk '$1 !~ /^#/ && $2 == "/srv/t7"' "$FSTAB")" \
    "$(storage_t7_fstab 12C3-A890 exfat 1000 1000)"
check "fstab: fremde Zeile auskommentiert" "$(grep -c '^# t3-worker (ersetzt): UUID=AAAA-BBBB /srv/t7 ' "$FSTAB")" 1
check "fstab: andere Einträge unverändert" "$(grep -cE '^UUID=(root /|tm /srv/timemachine) ' "$FSTAB")" 2
before=$(cat "$FSTAB")
apply_fstab
check "fstab: zweiter Lauf ändert nichts" "$(cat "$FSTAB")" "$before"

# --- exFAT VolumeDirty flag (read-only) --------------------------------------------
IMG=$TMP/t7.img
if command -v mkfs.exfat >/dev/null 2>&1; then
    truncate -s 16M "$IMG"
    mkfs.exfat -L "T7 Shield" "$IMG" >/dev/null 2>&1
    kind="mkfs.exfat"
else # hand-made boot sector: file system name at offset 3
    truncate -s 1M "$IMG"
    printf 'EXFAT   ' | dd of="$IMG" bs=1 seek=3 conv=notrunc status=none
    kind="Bootsektor"
fi
check "exFAT sauber ($kind)" "$(exfat_volume_state "$IMG")" clean
printf '\002' | dd of="$IMG" bs=1 seek=106 conv=notrunc status=none
sum=$(sha256sum "$IMG")
check "exFAT nicht sauber getrennt" "$(exfat_volume_state "$IMG")" dirty
check "Prüfung liest nur" "$(sha256sum "$IMG")" "$sum"
check "kein exFAT: unbekannt" "$(exfat_volume_state "$0")" unknown
check "fehlendes Gerät: unbekannt" "$(exfat_volume_state "$TMP/missing")" unknown

BLKID_DEVS="$IMG exfat T7 Shield"
check "kein Mount bei nicht sauberem exFAT" "$(t7_mount_refusal "$IMG" >/dev/null && echo abgelehnt || echo erlaubt)" abgelehnt
printf '\000' | dd of="$IMG" bs=1 seek=106 conv=notrunc status=none
check "Mount bei sauberem exFAT" "$(t7_mount_refusal "$IMG" >/dev/null && echo abgelehnt || echo erlaubt)" erlaubt
BLKID_DEVS="$IMG ntfs T7 Shield"
check "NTFS: Prüfung übernimmt ntfs3" "$(t7_mount_refusal "$IMG" >/dev/null && echo abgelehnt || echo erlaubt)" erlaubt

# --- Samba share per file system ----------------------------------------------------
STORAGE_ENV=$TMP/storage.env
for t in exfat ntfs ''; do
    printf 'T7_UUID=X\nT7_FSTYPE=%s\n' "$t" >"$STORAGE_ENV"
    samba_render >"$TMP/smb-${t:-any}.conf"
    check "smb.conf (${t:-unbekannt}): keine Platzhalter" "$(grep -c '@@' "$TMP/smb-${t:-any}.conf")" 0
    if command -v testparm >/dev/null 2>&1; then
        testparm -s "$TMP/smb-${t:-any}.conf" >"$TMP/testparm.out" 2>"$TMP/testparm.err"
        check "testparm (${t:-unbekannt})" "$?" 0
        check "testparm (${t:-unbekannt}) ohne Warnung" "$(grep -ciE 'unknown|error|ignoring' "$TMP/testparm.err")" 0
    fi
done
t7_share() { sed -n '/^\[T7\]/,/^\[TimeMachine\]/p' "$1" | sed -nE 's/^ *(comment|vfs objects|ea support) = //p' | paste -sd'|'; }
check "T7-Freigabe exFAT" "$(t7_share "$TMP/smb-exfat.conf")" "Samsung T7 Shield (exFAT)|catia fruit|no"
check "T7-Freigabe NTFS" "$(t7_share "$TMP/smb-ntfs.conf")" "Samsung T7 Shield (NTFS)|catia fruit streams_xattr|yes"
check "T7-Freigabe unbekannt" "$(t7_share "$TMP/smb-any.conf")" "Samsung T7 Shield (NTFS oder exFAT)|catia fruit|no"

exit "$FAILED"
