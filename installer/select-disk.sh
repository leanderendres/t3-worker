#!/bin/sh
# partman/early_command for the t3-worker installer (runs in the Debian
# installer's busybox environment, not on the installed system).
#
# Picks the internal SSD by model and tells partman to use only that disk.
# Aborts the whole install (message + power off) when:
#   - the SSD model is not found, or found more than once
#   - any disk larger than 1.5 TB is attached (e.g. the 2 TB T7)
#   - any USB disk other than the installer stick is attached
# Asks before overwriting an existing t3-worker installation.

SSD_MODEL="HFS128G39TND"
MAX_BYTES=1500000000000

# shellcheck source=/dev/null  # only exists inside the Debian installer
. /usr/share/debconf/confmodule

abort() {
    cat > /tmp/t3worker.templates <<EOF
Template: t3worker/abort
Type: error
Description: t3-worker: Installation abgebrochen
 $1
 .
 Es wurde nichts auf eine Festplatte geschrieben. Das Gerät schaltet sich
 nach Bestätigung aus.
EOF
    debconf-loadtemplate t3worker /tmp/t3worker.templates
    db_fset t3worker/abort seen false
    db_input critical t3worker/abort || true
    db_go || true
    logger -t t3-worker "abort: $1"
    sleep 1
    poweroff -f
    exit 1
}

# Disk that holds the installer medium (mounted on /cdrom).
installer_disk=""
cdrom_dev=$(awk '$2 == "/cdrom" { print $1; exit }' /proc/mounts)
if [ -n "$cdrom_dev" ]; then
    cdrom_name=$(basename "$(readlink -f "$cdrom_dev")")
    for d in /sys/block/*; do
        n=$(basename "$d")
        if [ "$n" = "$cdrom_name" ] || [ -e "$d/$cdrom_name" ]; then
            installer_disk=$n
        fi
    done
fi

target=""
count=0
for d in /sys/block/sd* /sys/block/nvme*n* /sys/block/mmcblk*; do
    [ -e "$d" ] || continue
    n=$(basename "$d")
    case "$n" in mmcblk*boot*|mmcblk*rpmb) continue ;; esac
    sectors=$(cat "$d/size" 2>/dev/null || echo 0)
    [ "$sectors" -gt 0 ] || continue
    bytes=$((sectors * 512))
    model=$(cat "$d/device/model" 2>/dev/null | tr -s ' ')
    path=$(readlink -f "$d")

    if [ "$bytes" -gt "$MAX_BYTES" ]; then
        abort "Datenträger /dev/$n ($model, $((bytes / 1000000000)) GB) ist größer als 1,5 TB. Bitte alle externen Laufwerke (z. B. die T7) abziehen und neu starten."
    fi
    case "$path" in
        */usb*)
            if [ "$n" != "$installer_disk" ]; then
                abort "USB-Datenträger /dev/$n ($model) gefunden, der nicht der Installationsstick ist. Bitte abziehen und neu starten."
            fi
            continue
            ;;
    esac

    matched=0
    case "$model" in *"$SSD_MODEL"*) matched=1 ;; esac
    if [ "$matched" = 0 ]; then
        for link in /dev/disk/by-id/ata-*"$SSD_MODEL"*; do
            [ -e "$link" ] || continue
            case "$link" in *-part*) continue ;; esac
            [ "$(basename "$(readlink -f "$link")")" = "$n" ] && matched=1
        done
    fi
    if [ "$matched" = 1 ]; then
        target="/dev/$n"
        count=$((count + 1))
    fi
done

[ "$count" -eq 1 ] || abort "Interne SSD mit Modell $SSD_MODEL nicht eindeutig gefunden (Treffer: $count). Im BIOS SATA-Modus auf AHCI stellen und prüfen, ob die SSD erkannt wird."

# Existing t3-worker installation on the SSD? Then ask (default: no).
if blkid 2>/dev/null | grep "^$target" | grep -q 'LABEL="t3root"'; then
    cat > /tmp/t3worker-reinstall.templates <<EOF
Template: t3worker/reinstall
Type: boolean
Default: false
Description: Vorhandene t3-worker-Installation auf $target überschreiben?
 Auf der internen SSD ist bereits eine t3-worker-Installation. Bei "Ja" wird
 die SSD komplett neu eingerichtet (Repos und Daten darauf gehen verloren).
 Bei "Nein" schaltet sich das Gerät aus. Die Festplatte (HDD) und externe
 Laufwerke werden in keinem Fall verändert.
EOF
    debconf-loadtemplate t3worker /tmp/t3worker-reinstall.templates
    db_fset t3worker/reinstall seen false
    db_input critical t3worker/reinstall || true
    db_go || true
    db_get t3worker/reinstall
    [ "$RET" = "true" ] || abort "Neuinstallation abgelehnt."
fi

logger -t t3-worker "target disk: $target"
debconf-set partman-auto/disk "$target"
debconf-set grub-installer/bootdev "$target"
exit 0
