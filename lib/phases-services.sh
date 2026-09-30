# shellcheck shell=bash
# shellcheck disable=SC2153  # CHANGED, constants and helpers come from lib/common.sh
# setup.sh phases: firewall, cockpit, timers, summary. Sourced by setup.sh.

# --- firewall: Samba and Cockpit only from loopback, Tailscale and private LAN ---------
phase_firewall() {
    apt_install nftables
    local dirty=0
    install_file "$T3W_ROOT/config/firewall.nft" /etc/t3-worker/firewall.nft 0644
    [ "$CHANGED" = 1 ] && dirty=1
    install_file "$T3W_ROOT/systemd/t3-worker-firewall.service" /etc/systemd/system/t3-worker-firewall.service
    [ "$CHANGED" = 1 ] && dirty=1
    if ! dry && command -v nft >/dev/null; then
        nft -c -f /etc/t3-worker/firewall.nft || die "firewall.nft ist ungültig."
    fi
    svc daemon-reload
    svc enable t3-worker-firewall.service
    if [ "$dirty" = 1 ]; then
        svc restart t3-worker-firewall.service
    else
        svc start t3-worker-firewall.service
    fi
    ok "Ports 139/445 (Samba) und 9090 (Cockpit) nur aus LAN und Tailscale"
}

# --- cockpit: web admin (socket-activated) plus the t3-worker status page ---------------
phase_cockpit() {
    # No recommends: they would pull in NetworkManager and PackageKit
    apt_install --no-recommends cockpit cockpit-storaged
    local f
    for f in "$T3W_ROOT"/cockpit/t3-worker/*; do
        [ -f "$f" ] || continue
        install_file "$f" "/usr/share/cockpit/t3-worker/$(basename "$f")" 0644
    done
    svc enable --now cockpit.socket
    ok "Cockpit: https://$T3W_HOSTNAME.local:9090 (Anmeldung als $T3W_USER mit Passwort), Seite 't3-worker'"
}

# --- timers: health (5 min), tool update (04:30), T7 mirror (02:30) --------------------
T3W_TIMERS=(t3-worker-health t3-worker-tool-update t3-worker-t7-mirror)

phase_timers() {
    local t dirty=0
    for t in "${T3W_TIMERS[@]}"; do
        install_file "$T3W_ROOT/systemd/$t.service" "/etc/systemd/system/$t.service"
        [ "$CHANGED" = 1 ] && dirty=1
        install_file "$T3W_ROOT/systemd/$t.timer" "/etc/systemd/system/$t.timer"
        [ "$CHANGED" = 1 ] && dirty=1
    done
    install_file "$T3W_ROOT/systemd/t3-worker-firstboot.service" /etc/systemd/system/t3-worker-firstboot.service
    [ "$dirty" = 1 ] && svc daemon-reload
    for t in "${T3W_TIMERS[@]}"; do
        svc enable --now "$t.timer"
    done
    # First status right away, so motd and Cockpit have data
    if ! dry && [ -x "$T3W_ROOT/lib/health.sh" ]; then
        "$T3W_ROOT/lib/health.sh" >/dev/null 2>&1 || warn "Erste Gesundheitsprüfung meldet Probleme (siehe Zusammenfassung)."
    fi
    ok "Timer aktiv: Gesundheit alle 5 min, Werkzeug-Update 04:30, T7-Spiegel 02:30"
}

# --- summary --------------------------------------------------------------------------------
status_line() { # status_line LABEL STATE
    case "$2" in
        active|Running|ja|yes|ok) printf '  %s✓%s %-22s %s\n' "$C_G" "$C_0" "$1" "$2" ;;
        *) printf '  %s✗%s %-22s %s\n' "$C_Y" "$C_0" "$1" "${2:-unbekannt}" ;;
    esac
}

phase_summary() {
    if dry; then
        ok "Prüfmodus beendet: es wurde nichts verändert."
        return 0
    fi
    say "Status"
    status_line "Tailscale" "$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null || true)"
    status_line "T3-Code-Dienst" "$(user_systemctl is-active t3code.service 2>/dev/null || true)"
    status_line "Docker" "$(systemctl is-active docker 2>/dev/null || true)"
    status_line "Samba" "$(systemctl is-active smbd 2>/dev/null || true)"
    status_line "Cockpit (Socket)" "$(systemctl is-active cockpit.socket 2>/dev/null || true)"
    status_line "T7 eingebunden" "$(mountpoint -q "$T7_PATH" 2>/dev/null && echo ja || echo nein)"
    status_line "Time Machine (HDD)" "$(mountpoint -q "$TM_PATH" 2>/dev/null && echo ja || echo nein)"
    status_line "T7-Spiegel (HDD)" "$(mountpoint -q "$MIRROR_PATH" 2>/dev/null && echo ja || echo nein)"

    local items=() f
    for f in "$T3W_STATE"/pending/*; do
        [ -f "$f" ] && items+=("$(cat "$f")")
    done
    echo
    if [ ${#items[@]} -eq 0 ]; then
        ok "Keine offenen Schritte."
    else
        say "Offene Schritte (brauchen dich)"
        for f in "${items[@]}"; do printf '  - %s\n' "$f"; done
        echo
        echo "  Danach erneut: sudo t3-worker-setup"
    fi
    echo
    say "Auf dem Mac"
    echo "  - T3 Code: Settings -> Connections -> Add environment -> Pairing-Link (mac/pair.sh)"
    echo "  - Settings -> Connections -> Load balancing: t3-worker 'Prefer', Mac 'Less often'"
    echo "  - Time Machine: Systemeinstellungen -> Time Machine -> smb://$T3W_HOSTNAME.local/TimeMachine"
    echo "  - Status jederzeit: mac/status.sh oder https://$T3W_HOSTNAME.local:9090"
}
