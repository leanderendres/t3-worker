# shellcheck shell=bash
# shellcheck disable=SC2153  # CHANGED, constants and helpers come from lib/common.sh
# setup.sh phases: storage, samba. Sourced by setup.sh.
#
# Safety: the Samsung T7 (NTFS or exFAT, label $T7_LABEL) holds the only copy of the owner's
# data. Nothing in here ever writes to it: it is only detected (blkid) and mounted.
# Destructive commands (parted, mkfs) only ever target the internal HDD, and only
# after storage_hdd_guard passed twice and the owner typed "FORMAT <sdX>".

STORAGE_ENV=/etc/t3-worker/storage.env
TM_PARTLABEL=t3w-timemachine
MIRROR_PARTLABEL=t3w-t7mirror
HDD_MIN_BYTES=900000000000
HDD_MAX_BYTES=1100000000000

# storage_env_get KEY: value from $STORAGE_ENV (parsed, never sourced)
storage_env_get() {
    [ -r "$STORAGE_ENV" ] || return 0
    sed -nE "s/^$1=([A-Za-z0-9-]*)$/\1/p" "$STORAGE_ENV" | tail -n1
}

# storage_disk_of DEV: parent disk (/dev/sdX) of a partition, or DEV itself
storage_disk_of() {
    local pk
    pk=$(lsblk -dnpo PKNAME "$1" 2>/dev/null | head -n1 || true)
    printf '%s\n' "${pk:-$1}"
}

# storage_part_by_label DISK PARTLABEL: partition of DISK with that GPT name
storage_part_by_label() {
    local disk=$1 want=$2 line
    while IFS= read -r line; do
        [ "$(lsblk_field TYPE "$line")" = part ] || continue
        [ "$(lsblk_field PARTLABEL "$line")" = "$want" ] || continue
        lsblk_field NAME "$line"
        return 0
    done < <(lsblk -npP -o NAME,TYPE,PARTLABEL "$disk" 2>/dev/null)
    return 1
}

# storage_hdd_guard DISK: all non-interactive checks before anything destructive.
# Prints the reason and returns 1 on the first failed check.
storage_hdd_guard() {
    local disk=$1 name type model tran size sysp mnts t7 t7disk rootdisk link okmodel=0 h
    name=$(basename "$disk")
    case "$name" in sd[a-z]|sd[a-z][a-z]) ;; *) fail "HDD: unerwarteter Gerätename $disk"; return 1 ;; esac
    [ -b "$disk" ] || { fail "HDD: $disk ist kein Blockgerät"; return 1; }

    type=$(lsblk -dno TYPE "$disk" 2>/dev/null || true)
    [ "$type" = disk ] || { fail "HDD: $disk ist keine ganze Platte (Typ '$type')"; return 1; }

    # 1. model (lsblk model or the ATA by-id link must point to this very disk)
    model=$(lsblk -dno MODEL "$disk" 2>/dev/null || true)
    case "$model" in *"$HDD_MODEL"*) okmodel=1 ;; esac
    for link in /dev/disk/by-id/ata-*"$HDD_MODEL"*; do
        [ -e "$link" ] || continue
        case "$link" in *-part*) continue ;; esac
        [ "$(readlink -f "$link")" = "$disk" ] && okmodel=1
    done
    [ "$okmodel" = 1 ] || { fail "HDD: $disk ist nicht das Modell $HDD_MODEL (gefunden: '${model:-?}')"; return 1; }

    # 2. not USB (transport and sysfs path)
    tran=$(lsblk -dno TRAN "$disk" 2>/dev/null || true)
    sysp=$(readlink -f "/sys/block/$name" 2>/dev/null || true)
    if [ "$tran" = usb ] || [[ "$sysp" == */usb* ]]; then
        fail "HDD: $disk hängt an USB. Abbruch (USB-Laufwerke werden nie formatiert)."
        return 1
    fi

    # 3. size 900-1100 GB
    size=$(lsblk -dnbo SIZE "$disk" 2>/dev/null | tr -d ' ' || true)
    if ! [[ "$size" =~ ^[0-9]+$ ]] || [ "$size" -lt "$HDD_MIN_BYTES" ] || [ "$size" -gt "$HDD_MAX_BYTES" ]; then
        fail "HDD: $disk hat ${size:-?} Bytes, erwartet 900-1100 GB. Abbruch."
        return 1
    fi

    # 4. never the T7 and never the system disk
    if t7=$(find_t7); then
        t7disk=$(storage_disk_of "$t7")
        [ "$t7disk" != "$disk" ] || { fail "HDD: $disk trägt die T7-Partition. Abbruch."; return 1; }
    fi
    if lsblk -nro LABEL "$disk" 2>/dev/null | grep -qF "$(printf '%s' "$T7_LABEL" | sed 's/ /\\x20/g')"; then
        fail "HDD: $disk hat eine Partition mit dem Namen '$T7_LABEL'. Abbruch."
        return 1
    fi
    rootdisk=$(storage_disk_of "$(findmnt -nvo SOURCE / 2>/dev/null || true)")
    [ "$rootdisk" != "$disk" ] || { fail "HDD: $disk ist die Systemplatte. Abbruch."; return 1; }

    # 5. nothing mounted, no swap, no holders (LVM, RAID, dm-crypt)
    mnts=$(lsblk -nro MOUNTPOINTS "$disk" 2>/dev/null | grep -v '^$' || true)
    [ -z "$mnts" ] || { fail "HDD: auf $disk ist etwas eingehängt ($mnts). Abbruch."; return 1; }
    if awk 'NR > 1 { print $1 }' /proc/swaps 2>/dev/null | grep -q "^$disk"; then
        fail "HDD: $disk wird als Swap benutzt. Abbruch."
        return 1
    fi
    for h in "/sys/block/$name/holders"/* "/sys/block/$name/$name"*/holders/*; do
        [ -e "$h" ] || continue
        fail "HDD: $disk wird von $(basename "$h") benutzt. Abbruch."
        return 1
    done

    # 6. partition layout fits
    if ! [[ "$TM_SIZE_GIB" =~ ^[0-9]+$ ]] || [ $((TM_SIZE_GIB * 1073741824 + 50 * 1073741824)) -gt "$size" ]; then
        fail "HDD: TM_SIZE_GIB=$TM_SIZE_GIB passt nicht auf $disk. Abbruch."
        return 1
    fi
    return 0
}

# storage_hdd_show DISK: what is on the disk right now (read-only)
storage_hdd_show() {
    local disk=$1 p
    say "Aktueller Inhalt von $disk"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS "$disk" 2>/dev/null | sed 's/^/  /' || true
    say "Signaturen (wipefs -n, nur lesen)"
    for p in "$disk" $(lsblk -nplo NAME "$disk" 2>/dev/null | tail -n +2); do
        wipefs -n "$p" 2>/dev/null | sed 's/^/  /' || true
    done
}

# storage_hdd_format DISK: GPT with two ext4 partitions. Caller ran the guard and
# the typed confirmation; the guard runs once more right before writing.
storage_hdd_format() {
    local disk=$1 tm mirror
    storage_hdd_guard "$disk" || return 1
    say "Partitioniere $disk (Time Machine ${TM_SIZE_GIB} GiB, Rest T7-Spiegel)"
    run parted -s -a optimal "$disk" \
        mklabel gpt \
        mkpart "$TM_PARTLABEL" ext4 1MiB "${TM_SIZE_GIB}GiB" \
        mkpart "$MIRROR_PARTLABEL" ext4 "${TM_SIZE_GIB}GiB" 100%
    if dry; then
        plan "mkfs.ext4 -L TIMEMACHINE -m 0 (Partition $TM_PARTLABEL auf $disk)"
        plan "mkfs.ext4 -L T7MIRROR -m 0 (Partition $MIRROR_PARTLABEL auf $disk)"
        return 0
    fi
    udevadm settle || true
    partprobe "$disk" 2>/dev/null || true
    udevadm settle || true
    tm=$(storage_part_by_label "$disk" "$TM_PARTLABEL") || { fail "Partition $TM_PARTLABEL nicht gefunden"; return 1; }
    mirror=$(storage_part_by_label "$disk" "$MIRROR_PARTLABEL") || { fail "Partition $MIRROR_PARTLABEL nicht gefunden"; return 1; }
    # Paranoia: both partitions must sit on the checked disk
    [ "$(storage_disk_of "$tm")" = "$disk" ] && [ "$(storage_disk_of "$mirror")" = "$disk" ] \
        || { fail "Neue Partitionen liegen nicht auf $disk. Abbruch."; return 1; }
    mkfs.ext4 -F -q -L TIMEMACHINE -m 0 "$tm"
    mkfs.ext4 -F -q -L T7MIRROR -m 0 "$mirror"
    udevadm settle || true
    ok "HDD eingerichtet: $tm (TIMEMACHINE), $mirror (T7MIRROR)"
}

# storage_hdd: sets TM_UUID and MIRROR_UUID when the HDD is ready
storage_hdd() {
    local disk tm mirror name answer=''
    if ! disk=$(find_disk_by_model "$HDD_MODEL"); then
        warn "Interne HDD ($HDD_MODEL) nicht gefunden."
        pending_set hdd "Interne HDD ($HDD_MODEL) nicht gefunden. Prüfen, ob sie erkannt wird (lsblk), dann sudo t3-worker-setup --phase storage"
        return 0
    fi
    name=$(basename "$disk")
    ok "HDD ($HDD_MODEL): $disk"

    # Checks that apply even to an already prepared disk
    local tran size
    tran=$(lsblk -dno TRAN "$disk" 2>/dev/null || true)
    size=$(lsblk -dnbo SIZE "$disk" 2>/dev/null | tr -d ' ' || true)
    if [ "$tran" = usb ]; then
        fail "$disk hängt an USB: wird nicht als interne HDD verwendet."
        pending_set hdd "Gefundene HDD $disk hängt an USB und wird nicht verwendet. Hardware prüfen."
        return 0
    fi
    if ! [[ "$size" =~ ^[0-9]+$ ]] || [ "$size" -lt "$HDD_MIN_BYTES" ] || [ "$size" -gt "$HDD_MAX_BYTES" ]; then
        fail "$disk hat ${size:-?} Bytes, erwartet 900-1100 GB: wird nicht verwendet."
        pending_set hdd "HDD $disk hat eine unerwartete Größe und wird nicht verwendet. Hardware prüfen."
        return 0
    fi

    tm=$(storage_part_by_label "$disk" "$TM_PARTLABEL" || true)
    mirror=$(storage_part_by_label "$disk" "$MIRROR_PARTLABEL" || true)
    if [ -n "$tm" ] && [ -n "$mirror" ] \
        && [ "$(blkid -s TYPE -o value "$tm" 2>/dev/null || true)" = ext4 ] \
        && [ "$(blkid -s TYPE -o value "$mirror" 2>/dev/null || true)" = ext4 ]; then
        TM_UUID=$(blkid -s UUID -o value "$tm" 2>/dev/null || true)
        MIRROR_UUID=$(blkid -s UUID -o value "$mirror" 2>/dev/null || true)
        ok "HDD bereits eingerichtet ($tm, $mirror)"
        pending_clear hdd
        return 0
    fi

    # Not prepared: formatting needs a person at the keyboard
    say "Die HDD ist noch nicht für t3-worker eingerichtet."
    storage_hdd_show "$disk"
    if ! storage_hdd_guard "$disk"; then
        pending_set hdd "HDD $disk kann nicht sicher formatiert werden (siehe Setup-Log). Prüfen, dann sudo t3-worker-setup --phase storage"
        return 0
    fi
    if dry; then
        plan "nach Eingabe von 'FORMAT $name': alle Daten auf $disk löschen, GPT anlegen"
        storage_hdd_format "$disk"
        return 0
    fi
    if ! have_tty; then
        pending_set hdd "HDD $disk ($HDD_MODEL) muss einmal formatiert werden (löscht alles darauf): sudo t3-worker-setup --phase storage und 'FORMAT $name' eintippen"
        return 0
    fi
    warn "ALLE Daten auf $disk ($HDD_MODEL, interne HDD) werden gelöscht. Die T7 wird nicht angefasst."
    ask answer "Zum Formatieren genau 'FORMAT $name' eintippen (alles andere bricht ab):" || answer=''
    if [ "$answer" != "FORMAT $name" ]; then
        warn "Nicht formatiert."
        pending_set hdd "HDD $disk ($HDD_MODEL) ist noch nicht formatiert: sudo t3-worker-setup --phase storage und 'FORMAT $name' eintippen"
        return 0
    fi
    storage_hdd_format "$disk" || die "Formatieren von $disk fehlgeschlagen."
    tm=$(storage_part_by_label "$disk" "$TM_PARTLABEL")
    mirror=$(storage_part_by_label "$disk" "$MIRROR_PARTLABEL")
    TM_UUID=$(blkid -s UUID -o value "$tm")
    MIRROR_UUID=$(blkid -s UUID -o value "$mirror")
    pending_clear hdd
}

# storage_mountpoint PATH: root:root 000 and immutable while nothing is mounted,
# so nothing can ever be written to the SSD underneath.
storage_mountpoint() {
    local path=$1
    mountpoint -q "$path" 2>/dev/null && return 0
    if [ -d "$path" ] && lsattr -d "$path" 2>/dev/null | awk '{ print $1 }' | grep -q i; then
        return 0
    fi
    [ -d "$path" ] || run mkdir -p "$path"
    if [ -d "$path" ] && [ -n "$(ls -A "$path" 2>/dev/null)" ]; then
        warn "$path enthält Dateien auf der SSD (ohne eingehängtes Laufwerk). Bitte prüfen."
    fi
    run chown root:root "$path"
    run chmod 000 "$path"
    run chattr +i "$path"
}

# storage_mount PATH NAME: mount from fstab if not mounted; returns 1 on failure
storage_mount() {
    local path=$1 what=$2
    if mountpoint -q "$path" 2>/dev/null; then
        ok "$what eingehängt: $path"
        return 0
    fi
    if dry; then plan "mount $path"; return 0; fi
    if mount "$path"; then
        ok "$what eingehängt: $path"
        return 0
    fi
    return 1
}

# storage_t7_fstab UUID FSTYPE UID GID: fstab line for the T7, kernel driver per
# file system. Both show every file as owned by the service user (neither stores
# Unix owners here). windows_names exists only in ntfs3. exFAT gets noauto: the
# exfat driver mounts a volume that was not cleanly removed, so boot must not
# mount it unchecked; setup and the health timer do it after t7_mount_refusal.
storage_t7_fstab() {
    local own="uid=$3,gid=$4,umask=002,iocharset=utf8" tail="nofail,x-systemd.device-timeout=10s 0 0"
    case "$2" in
        ntfs) printf '%s\n' "UUID=$1 $T7_PATH ntfs3 $own,windows_names,noatime,$tail" ;;
        exfat) printf '%s\n' "UUID=$1 $T7_PATH exfat $own,noatime,noauto,$tail" ;;
        *) return 1 ;;
    esac
}

# storage_fstab_retire FILE MOUNTPOINT: comment out active entries for MOUNTPOINT
# outside the managed block (e.g. a hand-written line with another type or UUID),
# so the managed entry is the only one for that mount point.
storage_fstab_retire() {
    local file=$1 tmp
    CHANGED=0
    [ -f "$file" ] || return 0
    tmp=$(mktemp)
    awk -v m="$2" '
        /^# >>> t3-worker storage >>>$/ { skip = 1 }
        /^# <<< t3-worker storage <<<$/ { skip = 0 }
        !skip && $1 !~ /^#/ && $2 == m { print "# t3-worker (ersetzt): " $0; next }
        { print }' "$file" >"$tmp"
    install_file "$tmp" "$file" "$(stat -c %a "$file")"
    rm -f "$tmp"
}

phase_storage() {
    local TM_UUID MIRROR_UUID T7_UUID T7_FSTYPE t7 uid gid line fstab='' changed=0
    TM_UUID=$(storage_env_get TM_UUID)
    MIRROR_UUID=$(storage_env_get MIRROR_UUID)
    T7_UUID=$(storage_env_get T7_UUID)
    T7_FSTYPE=$(storage_env_get T7_FSTYPE)
    # written by a version that knew only NTFS
    [ -z "$T7_UUID" ] || [ -n "$T7_FSTYPE" ] || T7_FSTYPE=ntfs

    say "Interne HDD"
    storage_hdd

    say "Samsung T7"
    if t7=$(find_t7); then
        T7_UUID=$(blkid -s UUID -o value "$t7" 2>/dev/null || true)
        T7_FSTYPE=$(t7_fstype "$t7" || true)
        ok "T7 ($T7_LABEL): $t7, $(t7_fs_name "$T7_FSTYPE")${T7_UUID:+ (UUID $T7_UUID)}"
    else
        t7=''
        warn "T7 ($T7_LABEL) nicht angeschlossen."
        pending_set t7 "T7 anstecken, dann sudo t3-worker-setup"
    fi

    write_file "$STORAGE_ENV" 0644 <<EOF
# t3-worker storage, written by setup.sh (phase storage). Do not edit.
TM_UUID=${TM_UUID}
MIRROR_UUID=${MIRROR_UUID}
T7_UUID=${T7_UUID}
T7_FSTYPE=${T7_FSTYPE}
EOF

    uid=$(id -u "$T3W_USER" 2>/dev/null || echo 1000)
    gid=$(id -g "$T3W_USER" 2>/dev/null || echo 1000)
    [ -z "$TM_UUID" ] || fstab+="UUID=$TM_UUID $TM_PATH ext4 defaults,noatime,nofail,x-systemd.device-timeout=15s 0 2"$'\n'
    [ -z "$MIRROR_UUID" ] || fstab+="UUID=$MIRROR_UUID $MIRROR_PATH ext4 defaults,noatime,nofail,x-systemd.device-timeout=15s 0 2"$'\n'
    if [ -n "$T7_UUID" ] && line=$(storage_t7_fstab "$T7_UUID" "$T7_FSTYPE" "$uid" "$gid"); then
        fstab+="$line"$'\n'
        storage_fstab_retire /etc/fstab "$T7_PATH"
        changed=$CHANGED
    fi
    if [ -n "$fstab" ]; then
        ensure_block /etc/fstab "t3-worker storage" <<<"${fstab%$'\n'}"
        [ "$CHANGED" = 1 ] && changed=1
    fi
    [ "$changed" = 1 ] && svc daemon-reload

    storage_mountpoint "$TM_PATH"
    storage_mountpoint "$MIRROR_PATH"
    storage_mountpoint "$T7_PATH"

    if [ -n "$TM_UUID" ] && [ -n "$MIRROR_UUID" ]; then
        if storage_mount "$TM_PATH" "Time Machine"; then
            if dry; then
                plan "chown $T3W_USER: $TM_PATH"
            elif [ "$(stat -c %U "$TM_PATH")" != "$T3W_USER" ]; then
                chown "$T3W_USER:" "$TM_PATH"
            fi
        else
            warn "Time-Machine-Partition ließ sich nicht einhängen."
            pending_set hdd "Time-Machine-Partition ließ sich nicht einhängen: journalctl -b und sudo t3-worker-setup --phase storage"
        fi
        if storage_mount "$MIRROR_PATH" "T7-Spiegel"; then
            [ -d "$MIRROR_PATH/current" ] || run mkdir -p "$MIRROR_PATH/current"
            [ -d "$MIRROR_PATH/deleted" ] || run mkdir -p "$MIRROR_PATH/deleted"
        else
            warn "Spiegel-Partition ließ sich nicht einhängen."
            pending_set hdd "Spiegel-Partition ließ sich nicht einhängen: journalctl -b und sudo t3-worker-setup --phase storage"
        fi
    fi

    if [ -n "$t7" ]; then
        local other reason fs
        fs=$(t7_fs_name "$T7_FSTYPE")
        other=$(findmnt -rno TARGET "$t7" 2>/dev/null | grep -vxF "$T7_PATH" | head -n1 || true)
        if [ -n "$other" ]; then
            warn "T7 ist bereits unter $other eingehängt."
            pending_set t7 "T7 ist unter $other eingehängt statt unter $T7_PATH: sudo umount '$other', dann sudo t3-worker-setup --phase storage"
        elif mountpoint -q "$T7_PATH" 2>/dev/null; then
            ok "T7 eingehängt: $T7_PATH"
            pending_clear t7
        # Never repair automatically: this volume holds the only copy of the data.
        elif reason=$(t7_mount_refusal "$t7"); then
            warn "T7 wird nicht eingehängt: $reason. Es wird nichts repariert."
            pending_set t7 "T7 wird nicht eingehängt: $reason. T7 an den Mac anschließen, im Festplattendienstprogramm 'Erste Hilfe' ausführen und sauber auswerfen (Windows: 'chkdsk X: /f'), danach wieder anstecken und sudo t3-worker-setup --phase storage. Nur zur Prüfung ohne Änderungen: sudo fsck.exfat -n $t7"
        elif storage_mount "$T7_PATH" "T7"; then
            pending_clear t7
        elif [ "$T7_FSTYPE" = ntfs ]; then
            warn "T7 ließ sich nicht einhängen (NTFS vermutlich nicht sauber getrennt). Es wird nichts repariert."
            pending_set t7 "T7 ließ sich nicht einhängen (NTFS nicht sauber getrennt). T7 an einen Windows-PC anschließen und dort 'chkdsk X: /f' ausführen (X: = Laufwerksbuchstabe der T7), danach wieder anstecken und sudo t3-worker-setup --phase storage. Nur zur Prüfung ohne Änderungen: sudo ntfsfix -n $t7"
        else
            warn "T7 ($fs) ließ sich nicht einhängen. Es wird nichts repariert."
            pending_set t7 "T7 ($fs) ließ sich nicht einhängen. Ursache: sudo journalctl -k -b | grep -i exfat. Nur zur Prüfung ohne Änderungen: sudo fsck.exfat -n $t7. Danach sudo t3-worker-setup --phase storage"
        fi
    fi
}

# --- samba: shares T7 and TimeMachine for the Mac -----------------------------------
# samba_render: print smb.conf from the template. The T7 share follows the file
# system found by the storage phase. exFAT has no extended attributes, and with
# streams_xattr on such a volume even a rename fails (NT_STATUS_NOT_SUPPORTED).
# Without a streams module the share does not announce named streams and macOS
# keeps its metadata in ._ files, as it does on exFAT locally. Unknown type: the
# variant that works on both.
samba_render() {
    local t7_type t7_vfs t7_ea
    t7_type=$(storage_env_get T7_FSTYPE)
    case "$t7_type" in
        ntfs) t7_vfs="catia fruit streams_xattr" t7_ea=yes ;;
        *) t7_vfs="catia fruit" t7_ea=no ;;
    esac
    sed -e "s|@@USER@@|$T3W_USER|g" \
        -e "s|@@T7_PATH@@|$T7_PATH|g" \
        -e "s|@@T7_FS@@|$(t7_fs_name "$t7_type")|g" \
        -e "s|@@T7_VFS@@|$t7_vfs|g" \
        -e "s|@@T7_EA@@|$t7_ea|g" \
        -e "s|@@TM_PATH@@|$TM_PATH|g" \
        -e "s|@@TM_QUOTA@@|$TM_QUOTA|g" \
        -e "s|@@LIB@@|$T3W_ROOT/lib|g" \
        "$T3W_ROOT/samba/smb.conf.tmpl"
}

phase_samba() {
    apt_install samba
    local tmp restart=0
    tmp=$(mktemp)
    samba_render >"$tmp"
    if grep -q '@@[A-Z0-9_]*@@' "$tmp"; then
        rm -f "$tmp"
        die "smb.conf.tmpl enthält unbekannte Platzhalter."
    fi
    if command -v testparm >/dev/null; then
        if ! testparm -s "$tmp" >/dev/null 2>&1; then
            testparm -s "$tmp" >/dev/null || true
            rm -f "$tmp"
            die "Samba-Konfiguration ungültig (testparm)."
        fi
        ok "testparm: Konfiguration gültig"
    elif dry; then
        plan "testparm -s /etc/samba/smb.conf"
    fi
    if [ -f /etc/samba/smb.conf ] && [ ! -e /etc/samba/smb.conf.debian-orig ] \
        && ! grep -q '^# t3-worker Samba configuration' /etc/samba/smb.conf; then
        run cp -a /etc/samba/smb.conf /etc/samba/smb.conf.debian-orig
    fi
    chmod 0644 "$tmp"
    install_file "$tmp" /etc/samba/smb.conf 0644
    [ "$CHANGED" = 1 ] && restart=1
    rm -f "$tmp"
    [ -x "$T3W_ROOT/lib/require-mount.sh" ] || run chmod 0755 "$T3W_ROOT/lib/require-mount.sh"

    install_file "$T3W_ROOT/config/avahi-smb.service" /etc/avahi/services/t3-worker-smb.service 0644
    install_file "$T3W_ROOT/config/avahi-device.service" /etc/avahi/services/t3-worker-device.service 0644

    svc enable smbd
    if [ "$restart" = 1 ]; then svc restart smbd; else svc start smbd; fi
    if systemctl list-unit-files nmbd.service >/dev/null 2>&1; then
        svc disable --now nmbd || warn "nmbd ließ sich nicht abschalten."
    fi

    if command -v pdbedit >/dev/null && pdbedit -L -u "$T3W_USER" >/dev/null 2>&1; then
        ok "Samba-Passwort für $T3W_USER gesetzt"
        pending_clear samba
    elif dry; then
        plan "Samba-Passwort für $T3W_USER setzen (smbpasswd -a $T3W_USER)"
    elif have_tty; then
        say "Samba-Passwort für $T3W_USER festlegen (für Finder und Time Machine)"
        if smbpasswd -a "$T3W_USER" </dev/tty >/dev/tty 2>&1; then
            ok "Samba-Passwort gesetzt"
            pending_clear samba
        else
            warn "Samba-Passwort nicht gesetzt."
            pending_set samba "Samba-Passwort setzen: sudo smbpasswd -a $T3W_USER"
        fi
    else
        pending_set samba "Samba-Passwort setzen: sudo smbpasswd -a $T3W_USER"
    fi
    ok "Freigaben: smb://$T3W_HOSTNAME.local/T7 und smb://$T3W_HOSTNAME.local/TimeMachine"
}
