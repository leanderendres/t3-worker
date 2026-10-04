# shellcheck shell=bash
# shellcheck disable=SC2153  # CHANGED, constants and helpers come from lib/common.sh
# setup.sh phases: tailscale, t3, claude, agenthome. Sourced by setup.sh.
#
# Everything that shows login URLs, codes, tokens or pairing links runs with
# its I/O on /dev/tty, so none of it reaches the setup log.

TS_AUTHKEY_FILE=/etc/t3-worker/tailscale-authkey

# User tools (claude, cswap, t3) live in ~/.local/bin; do not rely on ~/.profile.
# shellcheck disable=SC2016  # expanded by the user's shell
ACCESS_PATH='export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH";'

# tty_as_user 'code': run as the service user with all I/O on the terminal
tty_as_user() {
    if dry; then plan "als $T3W_USER (Terminal): $1"; return 0; fi
    as_user "$ACCESS_PATH $1" </dev/tty >/dev/tty 2>&1
}

# user_has 'code': read-only check as the service user (runs in --check too)
user_has() { as_user_check "$ACCESS_PATH $1"; }

ts_state() {
    command -v tailscale >/dev/null 2>&1 || return 0
    tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null || true
}

# --- tailscale: join the tailnet with Tailscale SSH and a fixed hostname -----------------
phase_tailscale() {
    if ! command -v tailscale >/dev/null 2>&1; then
        if dry; then plan "Tailscale fehlt noch (kommt aus Phase repos)"; return 0; fi
        warn "tailscale ist nicht installiert (Phase repos)."
        pending_set tailscale "Tailscale anmelden: sudo t3-worker-setup --phase repos --phase tailscale"
        return 0
    fi
    svc enable --now tailscaled.service
    local st flags
    st=$(ts_state)
    # --accept-dns=false: dhcpcd rewrites /etc/resolv.conf with every router advertisement and
    # Tailscale wrote it back each time; in between its forwarder had no upstream and every
    # lookup failed. Nothing on this machine needs tailnet names, so the system resolver stays.
    flags=(--ssh "--hostname=$T3W_HOSTNAME" "--operator=$T3W_USER" --accept-dns=false)
    say "Tailscale-Status: ${st:-unbekannt}"

    if [ "$st" = Running ]; then
        run tailscale set "${flags[@]}"
        pending_clear tailscale
        ok "Tailscale verbunden als $T3W_HOSTNAME (Tailscale SSH an, Operator $T3W_USER)"
        return 0
    fi

    if [ -s "$TS_AUTHKEY_FILE" ]; then
        say "Melde Tailscale mit Auth-Key aus $TS_AUTHKEY_FILE an ..."
        if run tailscale up "${flags[@]}" "--auth-key=file:$TS_AUTHKEY_FILE"; then
            pending_clear tailscale
            ok "Tailscale angemeldet (Auth-Key). Den Schlüssel kann man jetzt löschen: sudo rm $TS_AUTHKEY_FILE"
            return 0
        fi
        warn "Anmeldung mit Auth-Key fehlgeschlagen (abgelaufen oder bereits verbraucht?)."
    fi

    if dry; then
        plan "sonst: tailscale up ${flags[*]} interaktiv am Terminal, oder offen: tailscale"
        return 0
    fi
    if have_tty; then
        say "Tailscale-Anmeldung: den angezeigten Link im Browser öffnen (erscheint nur hier, nicht im Log)."
        if tailscale up "${flags[@]}" </dev/tty >/dev/tty 2>&1; then
            pending_clear tailscale
            ok "Tailscale angemeldet als $T3W_HOSTNAME"
            return 0
        else
            warn "Tailscale-Anmeldung abgebrochen oder fehlgeschlagen."
        fi
    fi

    pending_set tailscale "Tailscale anmelden: sudo t3-worker-setup --phase tailscale (oder Auth-Key in $TS_AUTHKEY_FILE legen)"
}

# --- t3: T3 Code as a systemd user service plus the pairing link --------------------------
phase_t3() {
    local uid bus _
    uid=$(user_uid)
    bus=/run/user/$uid/bus
    if [ -e "/var/lib/systemd/linger/$T3W_USER" ]; then
        ok "Linger für $T3W_USER aktiv"
    else
        run loginctl enable-linger "$T3W_USER"
    fi
    if ! dry; then
        for _ in $(seq 1 30); do
            [ -S "$bus" ] && break
            sleep 1
        done
        [ -S "$bus" ] || warn "User-Bus $bus fehlt noch; user@$uid.service prüfen."
    fi

    if ! user_has 'command -v t3'; then
        if dry; then plan "t3 fehlt noch (kommt aus Phase tools)"; return 0; fi
        warn "t3 ist nicht installiert (Phase tools)."
        pending_set t3pair "T3 Code einrichten: sudo t3-worker-setup --phase tools --phase t3"
        return 0
    fi

    if user_systemctl is-active --quiet t3code.service 2>/dev/null; then
        ok "T3-Code-Dienst läuft"
    else
        say "Installiere den T3-Code-Dienst (t3 service install) ..."
        as_user "$ACCESS_PATH t3 service install </dev/null" || warn "t3 service install meldet einen Fehler; siehe t3 service status."
    fi
    dry || as_user "$ACCESS_PATH t3 service status" || warn "t3 service status meldet Probleme."

    say "Hinweis: Für https://$T3W_HOSTNAME.<tailnet>.ts.net müssen in der Tailscale-Admin-Konsole (DNS) MagicDNS und HTTPS-Zertifikate aktiviert sein."

    if dry; then
        plan "Kopplung: t3 pair --tailscale am Terminal (nur mit Tailscale und Rückfrage), sonst offen: t3pair"
        return 0
    fi
    if [ "$(ts_state)" = Running ] && have_tty \
        && confirm "Jetzt einen Kopplungslink für T3 Code erzeugen (t3 pair --tailscale)?"; then
        say "Kopplungslink (einmalig, wie ein Passwort behandeln; erscheint nur hier, nicht im Log):"
        if tty_as_user 't3 pair --tailscale'; then
            pending_clear t3pair
            ok "Link in T3 Code unter Settings → Connections → Add environment einfügen."
            return 0
        fi
        warn "t3 pair --tailscale fehlgeschlagen (HTTPS-Zertifikate im Tailnet aktiv?)."
    fi
    pending_set t3pair "T3 Code koppeln: am Mac mac/pair.sh ausführen"
}

# --- claude: log in Claude Code accounts and hand them to claude-swap -----------------------
cswap_count() {
    local n
    n=$(DRY_RUN=0 as_user "$ACCESS_PATH cswap list --json 2>/dev/null" 2>/dev/null \
        | jq -r '(.accounts // []) | length' 2>/dev/null || true)
    echo "${n:-0}"
}

phase_claude() {
    if ! user_has 'command -v claude && command -v cswap'; then
        if dry; then plan "claude/cswap fehlen noch (kommen aus Phase tools)"; return 0; fi
        warn "claude oder cswap fehlt (Phase tools)."
        pending_set claude "Claude-Konten anmelden: sudo t3-worker-setup --phase tools --phase claude"
        return 0
    fi

    local n q
    n=$(cswap_count)
    say "claude-swap kennt $n Konto/Konten."
    if [ "$n" -gt 0 ]; then
        q="Ein weiteres Claude-Konto anmelden?"
    else
        q="Jetzt ein Claude-Konto anmelden (Link im Browser öffnen, Code hier einfügen)?"
    fi
    if dry; then
        plan "je Konto: claude auth login, dann cswap add (am Terminal, mit Rückfrage)"
    fi
    while ! dry && have_tty && confirm "$q"; do
        # No logout between accounts: it may revoke the token cswap just stored.
        say "Claude-Anmeldung (Link und Code erscheinen nur hier, nicht im Log):"
        if tty_as_user 'claude auth login' && tty_as_user 'cswap add'; then
            ok "Konto zu claude-swap hinzugefügt"
        else
            warn "Anmeldung oder cswap add fehlgeschlagen."
        fi
        n=$(cswap_count)
        q="Noch ein Claude-Konto anmelden?"
    done

    if [ "$n" -lt 1 ] && ! dry; then
        pending_set claude "Claude-Konten anmelden: sudo t3-worker-setup --phase claude (Notlösung: am Mac mac/push-accounts.sh)"
        return 0
    fi

    # Automatic account switching before rate limits
    local unit_dir
    unit_dir="$(user_home)/.config/systemd/user"
    as_user "mkdir -p '$unit_dir'"
    install_file "$T3W_ROOT/systemd/user/cswap-auto.service" "$unit_dir/cswap-auto.service" 0644
    if [ "$CHANGED" = 1 ]; then
        run chown "$T3W_USER:" "$unit_dir/cswap-auto.service"
        run user_systemctl daemon-reload
        run user_systemctl restart cswap-auto.service
    fi
    run user_systemctl enable --now cswap-auto.service
    pending_clear claude
    ok "claude-swap wechselt Konten automatisch (cswap-auto.service, $n Konto/Konten)"
}

# --- agenthome: GitHub login, shared agent rules and their hourly sync ----------------------
phase_agenthome() {
    local home repo
    home=$(user_home)
    repo=$home/Sites/agent-home

    if ! user_has 'command -v gh'; then
        if dry; then plan "gh fehlt noch (kommt aus Phase repos/tools)"; return 0; fi
        warn "GitHub CLI (gh) fehlt."
        pending_set github "GitHub anmelden: sudo t3-worker-setup --phase repos --phase agenthome"
        return 0
    fi

    if user_has 'gh auth status --hostname github.com'; then
        ok "GitHub CLI angemeldet"
    elif dry; then
        plan "gh auth login --hostname github.com --git-protocol https --web (am Terminal, mit Rückfrage)"
    elif have_tty && confirm "Jetzt bei GitHub anmelden (Code im Browser eingeben)?"; then
        say "GitHub-Anmeldung (Code und Link erscheinen nur hier, nicht im Log):"
        tty_as_user 'gh auth login --hostname github.com --git-protocol https --web' \
            || warn "GitHub-Anmeldung abgebrochen oder fehlgeschlagen."
    fi
    if ! dry && ! user_has 'gh auth status --hostname github.com'; then
        pending_set github "GitHub anmelden: sudo t3-worker-setup --phase agenthome"
        return 0
    fi
    pending_clear github
    as_user 'gh auth setup-git --hostname github.com' || warn "gh auth setup-git fehlgeschlagen."

    if [ -d "$repo/.git" ]; then
        ok "agent-home vorhanden: $repo"
    else
        say "Klone agent-home nach $repo ..."
        if ! as_user "mkdir -p '$home/Sites' && git clone -q '$T3W_AGENT_HOME_URL' '$repo'"; then
            warn "agent-home ließ sich nicht klonen (Zugriff auf das private Repo?)."
            pending_set github "agent-home klonen: sudo t3-worker-setup --phase agenthome"
            return 0
        fi
    fi
    if [ -x "$repo/install.sh" ] || dry; then
        as_user "cd '$repo' && ./install.sh" || warn "agent-home install.sh meldet einen Fehler."
    else
        warn "$repo/install.sh fehlt."
    fi

    local u src dst
    for u in agent-home-sync.service agent-home-sync.timer devsrv-reap.service devsrv-reap.timer; do
        src=$repo/platform/linux/$u
        dst=$home/.config/systemd/user/$u
        if [ "$(readlink "$dst" 2>/dev/null)" = "$src" ]; then
            continue
        fi
        run user_systemctl link "$src" || warn "Konnte $u nicht verlinken ($dst existiert?)."
    done
    run user_systemctl daemon-reload
    run user_systemctl enable --now agent-home-sync.timer
    run user_systemctl enable --now devsrv-reap.timer
    ok "agent-home verlinkt, stündlicher Abgleich aktiv (agent-home-sync.timer), verwaiste Dev-Server werden alle 10 min beendet (devsrv-reap.timer)"

    if [ -n "$(ls -A "$home/.agents/skills" 2>/dev/null)" ]; then
        pending_clear skills
    else
        pending_set skills "29 Skills vom Mac (~/.agents/skills) installieren, Quelle noch unklar"
    fi
}
