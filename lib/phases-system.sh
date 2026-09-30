# shellcheck shell=bash
# shellcheck disable=SC2153  # CHANGED, constants and helpers come from lib/common.sh
# setup.sh phases: repo, preflight, base, system. Sourced by setup.sh.

# --- repo: bring /opt/t3-worker up to date, then re-exec the new setup.sh --------------
phase_repo() {
    run ln -sfn "$T3W_ROOT/setup.sh" /usr/local/sbin/t3-worker-setup
    if [ "${T3W_REEXEC:-0}" = 1 ]; then
        ok "Setup-Repo aktuell ($(git -C "$T3W_ROOT" rev-parse --short HEAD 2>/dev/null || echo Stick-Kopie))"
        return 0
    fi
    export GIT_TERMINAL_PROMPT=0
    if [ -d "$T3W_ROOT/.git" ]; then
        if dry; then plan "git -C $T3W_ROOT pull --ff-only, danach Neustart des Setups"; return 0; fi
        local before after
        before=$(git -C "$T3W_ROOT" rev-parse HEAD)
        if ! git -C "$T3W_ROOT" pull -q --ff-only; then
            warn "git pull nicht möglich (offline oder lokale Änderungen). Weiter mit dem vorhandenen Stand."
            return 0
        fi
        after=$(git -C "$T3W_ROOT" rev-parse HEAD)
        if [ "$before" = "$after" ]; then
            ok "Setup-Repo aktuell (${after:0:7})"
            return 0
        fi
        say "Setup-Repo aktualisiert (${before:0:7} -> ${after:0:7}). Starte das neue Setup ..."
    else
        if dry; then plan "Stick-Kopie durch git clone $T3W_REPO_URL ersetzen, danach Neustart"; return 0; fi
        local tmp
        tmp=$(mktemp -d)
        if ! git clone -q --depth 1 "$T3W_REPO_URL" "$tmp/t3-worker" 2>/dev/null; then
            rm -rf "$tmp"
            warn "GitHub nicht erreichbar: verwende die Kopie vom Installationsstick."
            return 0
        fi
        rm -rf "$T3W_ROOT.stick"
        mv "$T3W_ROOT" "$T3W_ROOT.stick"
        mv "$tmp/t3-worker" "$T3W_ROOT"
        rm -rf "$tmp" "$T3W_ROOT.stick"
        say "Stick-Kopie durch aktuelles GitHub-Repo ersetzt. Starte das neue Setup ..."
    fi
    chmod 0755 "$T3W_ROOT/setup.sh" "$T3W_ROOT"/lib/*.sh
    export T3W_REEXEC=1
    exec bash "$T3W_ROOT/setup.sh" "${ORIG_ARGS[@]}"
}

# --- preflight -------------------------------------------------------------------------
phase_preflight() {
    local codename="" arch
    if [ -r /etc/os-release ]; then
        # shellcheck source=/dev/null
        codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
    fi
    if [ "$codename" = trixie ]; then
        ok "Debian 13 (trixie)"
    elif dry; then
        warn "Kein Debian 13 (gefunden: ${codename:-unbekannt})"
    else
        die "Dieses Setup ist für Debian 13 (trixie), gefunden: ${codename:-unbekannt}"
    fi
    arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    case "$arch" in amd64|x86_64) ok "Architektur $arch" ;; *) die "Nur amd64 unterstützt (gefunden: $arch)" ;; esac

    if id "$T3W_USER" >/dev/null 2>&1; then
        ok "Benutzer $T3W_USER vorhanden"
    elif dry; then
        warn "Benutzer $T3W_USER fehlt (im Prüfmodus ignoriert)"
    else
        die "Benutzer $T3W_USER fehlt."
    fi

    say "Hardware"
    printf '  CPU: %s\n' "$(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo 2>/dev/null || echo ?)"
    printf '  RAM: %s MB\n' "$(awk '/^MemTotal/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null || echo ?)"
    if command -v lsblk >/dev/null; then
        lsblk -dno NAME,SIZE,TRAN,MODEL 2>/dev/null | sed 's/^/  Laufwerk: /' || true
    fi
    local d
    if d=$(find_disk_by_model "$SSD_MODEL"); then ok "SSD ($SSD_MODEL): $d"; else warn "SSD $SSD_MODEL nicht gefunden"; fi
    if d=$(find_disk_by_model "$HDD_MODEL"); then ok "HDD ($HDD_MODEL): $d"; else warn "HDD $HDD_MODEL nicht gefunden"; fi
    if d=$(find_t7); then ok "T7 ($T7_LABEL): $d"; else warn "T7 ($T7_LABEL) nicht angeschlossen"; fi
    printf '  Root-Dateisystem: %s\n' "$(findmnt -no FSTYPE / 2>/dev/null || echo ?)"
    if [ -e /dev/watchdog0 ] || [ -e /dev/watchdog ]; then ok "Hardware-Watchdog vorhanden"; else warn "Kein /dev/watchdog (iTCO_wdt?)"; fi
    if curl -fsS -m 10 -o /dev/null https://deb.debian.org/debian/dists/trixie/Release 2>/dev/null; then
        ok "Internet erreichbar"
    else
        warn "deb.debian.org nicht erreichbar"
    fi
}

# --- base packages -----------------------------------------------------------------------
BASE_PACKAGES=(
    ca-certificates curl wget gnupg git jq rsync unzip zip xz-utils file less
    htop tmux vim-tiny bash-completion man-db
    build-essential pkg-config python3 python3-venv
    sudo openssh-server avahi-daemon libnss-mdns
    btrfs-progs snapper zram-tools nftables
    unattended-upgrades apt-listchanges
    smartmontools parted gdisk ntfs-3g exfatprogs lm-sensors
)

phase_base() {
    apt_update
    apt_install "${BASE_PACKAGES[@]}"
}

# --- system -------------------------------------------------------------------------------
# ensure_subvol PATH OWNER: nested Btrfs subvolume (excluded from root snapshots)
ensure_subvol() {
    local path=$1 owner=$2
    if [ "$(findmnt -no FSTYPE / 2>/dev/null)" != btrfs ]; then return 0; fi
    if [ -d "$path" ] && [ "$(stat -c %i "$path")" = 256 ]; then
        ok "Subvolume vorhanden: $path"
        return 0
    fi
    if [ -e "$path" ] && [ -n "$(ls -A "$path" 2>/dev/null)" ]; then
        warn "$path ist kein Subvolume und nicht leer: bleibt in den Root-Snapshots."
        return 0
    fi
    run mkdir -p "$(dirname "$path")"
    [ -d "$path" ] && run rmdir "$path"
    run btrfs -q subvolume create "$path"
    run chown "$owner" "$path"
}

phase_system() {
    local rootfs home
    rootfs=$(findmnt -no FSTYPE / 2>/dev/null || echo "?")
    home=$(user_home 2>/dev/null || echo "/home/$T3W_USER")

    say "Btrfs und Snapshots"
    if [ "$rootfs" = btrfs ]; then
        local tmp
        tmp=$(mktemp)
        awk '$1 !~ /^#/ && $2 == "/" && $3 == "btrfs" && $4 !~ /compress=/ { $4 = $4 ",noatime,compress=zstd:1" } { print }' /etc/fstab >"$tmp"
        install_file "$tmp" /etc/fstab 0644
        rm -f "$tmp"
        if [ "$CHANGED" = 1 ]; then run mount -o remount,noatime,compress=zstd:1 /; fi
        ensure_subvol /var/lib/docker root:root
        ensure_subvol "$home/Sites" "$T3W_USER:$T3W_USER"
        ensure_subvol "$home/.cache" "$T3W_USER:$T3W_USER"
        if [ ! -f /etc/snapper/configs/root ]; then
            run snapper -c root create-config /
        fi
        run snapper -c root set-config NUMBER_LIMIT=10 NUMBER_LIMIT_IMPORTANT=5 TIMELINE_CREATE=no NUMBER_CLEANUP=yes
        svc enable --now snapper-cleanup.timer
        svc disable --now snapper-timeline.timer
        if [ -f /etc/apt/apt.conf.d/80snapper ]; then
            ok "Snapper-Snapshots vor/nach jedem apt-Lauf aktiv (/etc/apt/apt.conf.d/80snapper)"
        else
            warn "/etc/apt/apt.conf.d/80snapper fehlt: keine automatischen apt-Snapshots"
        fi
    else
        warn "Root ist $rootfs, nicht Btrfs: Snapper wird übersprungen"
    fi

    say "zram-Swap und Kernel-Parameter"
    install_file "$T3W_ROOT/config/zramswap" /etc/default/zramswap
    [ "$CHANGED" = 1 ] && svc restart zramswap.service
    svc enable zramswap.service
    install_file "$T3W_ROOT/config/sysctl-t3-worker.conf" /etc/sysctl.d/90-t3-worker.conf
    [ "$CHANGED" = 1 ] && run sysctl -q --system

    say "Immer an: Deckel, Suspend, Watchdog"
    install_file "$T3W_ROOT/config/logind-t3-worker.conf" /etc/systemd/logind.conf.d/t3-worker.conf
    [ "$CHANGED" = 1 ] && svc reload systemd-logind
    install_file "$T3W_ROOT/config/sleep-t3-worker.conf" /etc/systemd/sleep.conf.d/t3-worker.conf
    svc mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
    install_file "$T3W_ROOT/config/watchdog-t3-worker.conf" /etc/systemd/system.conf.d/t3-worker-watchdog.conf
    [ "$CHANGED" = 1 ] && run systemctl daemon-reexec
    install_file "$T3W_ROOT/config/journald-t3-worker.conf" /etc/systemd/journald.conf.d/t3-worker.conf
    [ "$CHANGED" = 1 ] && svc restart systemd-journald

    say "NVIDIA MX150 aus, Konsole dunkel"
    local initramfs=0 grub=0
    install_file "$T3W_ROOT/config/modprobe-nvidia.conf" /etc/modprobe.d/t3-worker-nvidia.conf
    [ "$CHANGED" = 1 ] && initramfs=1
    install_file "$T3W_ROOT/config/udev-nvidia-pm.rules" /etc/udev/rules.d/80-t3-worker-nvidia-pm.rules
    install_file "$T3W_ROOT/config/grub-t3-worker.cfg" /etc/default/grub.d/t3-worker.cfg
    [ "$CHANGED" = 1 ] && grub=1
    [ "$initramfs" = 1 ] && run update-initramfs -u
    [ "$grub" = 1 ] && command -v update-grub >/dev/null && run update-grub

    say "Sicherheitsupdates (nur Security, Neustart nur 04:00)"
    install_file "$T3W_ROOT/config/unattended-upgrades-t3-worker.conf" /etc/apt/apt.conf.d/52t3-worker-unattended-upgrades
    install_file "$T3W_ROOT/config/auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
    svc enable --now unattended-upgrades.service

    say "SSH nur mit Schlüssel"
    if [ -s "$home/.ssh/authorized_keys" ]; then
        install_file "$T3W_ROOT/config/sshd-t3-worker.conf" /etc/ssh/sshd_config.d/10-t3-worker.conf
        if [ "$CHANGED" = 1 ]; then
            run sshd -t
            svc reload ssh
        fi
    else
        warn "Kein ~/.ssh/authorized_keys für $T3W_USER: Passwort-Login bleibt vorerst an."
        pending_set ssh "SSH-Schlüssel des Macs fehlt in $home/.ssh/authorized_keys"
    fi

    say "Hostname und mDNS ($T3W_HOSTNAME.local)"
    if [ "$(hostname 2>/dev/null)" != "$T3W_HOSTNAME" ]; then
        run hostnamectl set-hostname "$T3W_HOSTNAME"
    else
        ok "Hostname $T3W_HOSTNAME"
    fi
    if ! grep -qE "^127\.0\.1\.1[[:space:]].*\b$T3W_HOSTNAME\b" /etc/hosts 2>/dev/null; then
        local tmp
        tmp=$(mktemp)
        grep -v '^127\.0\.1\.1[[:space:]]' /etc/hosts >"$tmp" 2>/dev/null || true
        printf '127.0.1.1\t%s\n' "$T3W_HOSTNAME" >>"$tmp"
        install_file "$tmp" /etc/hosts 0644
        rm -f "$tmp"
    fi
    svc enable --now avahi-daemon.service

    say "Login-Hinweis (motd)"
    install_file "$T3W_ROOT/lib/motd.sh" /etc/update-motd.d/60-t3-worker 0755
}
