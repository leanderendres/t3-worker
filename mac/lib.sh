#!/usr/bin/env bash
# Shared helpers for the Mac-side t3-worker scripts.
# Source this file; do not execute it directly.
#
# Environment overrides:
#   T3W_HOST       Tailscale / MagicDNS host name   (default: t3-worker)
#   T3W_LAN_HOST   LAN fallback host name           (default: t3-worker.local)
#   T3W_USER       SSH user on the server           (default: leander)
#   T3W_YES=1      answer every confirm prompt with "yes"
#   NO_COLOR=1     disable colored output

# shellcheck shell=bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "lib.sh ist eine Bibliothek und wird von den anderen Skripten eingebunden." >&2
    exit 1
fi

T3W_HOST=${T3W_HOST:-t3-worker}
T3W_LAN_HOST=${T3W_LAN_HOST:-t3-worker.local}
T3W_USER=${T3W_USER:-leander}
T3W_STATUS_FILE=${T3W_STATUS_FILE:-/var/lib/t3-worker/status.json}
T3W_SERVICE=${T3W_SERVICE:-t3code.service}

# Common ssh options: fail fast, keep long sessions alive.
T3W_SSH_OPTS=(-o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=3)

# Resolved "user@host" after t3w_resolve_host succeeded.
T3W_TARGET=""

# --- colored output ---------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    _C_RESET=$'\033[0m'; _C_BOLD=$'\033[1m'; _C_DIM=$'\033[2m'
    _C_RED=$'\033[31m'; _C_GREEN=$'\033[32m'; _C_YELLOW=$'\033[33m'; _C_BLUE=$'\033[34m'
else
    _C_RESET=""; _C_BOLD=""; _C_DIM=""; _C_RED=""; _C_GREEN=""; _C_YELLOW=""; _C_BLUE=""
fi

info()    { printf '%s==>%s %s\n' "$_C_BLUE" "$_C_RESET" "$*"; }
ok()      { printf '%s✓%s %s\n' "$_C_GREEN" "$_C_RESET" "$*"; }
warn()    { printf '%s!%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
err()     { printf '%s✗%s %s\n' "$_C_RED" "$_C_RESET" "$*" >&2; }
die()     { err "$*"; exit 1; }
heading() { printf '\n%s%s%s\n' "$_C_BOLD" "$*" "$_C_RESET"; }
dim()     { printf '%s%s%s\n' "$_C_DIM" "$*" "$_C_RESET"; }

# confirm "Frage": returns 0 on yes, 1 otherwise. Default is "no".
confirm() {
    local prompt=${1:-"Fortfahren?"} reply
    if [[ "${T3W_YES:-}" == "1" ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        warn "Keine interaktive Eingabe möglich; setze T3W_YES=1, um ohne Rückfrage fortzufahren."
        return 1
    fi
    read -r -p "$prompt [j/N] " reply
    [[ "$reply" =~ ^([jJyY]|[jJ]a|[yY]es)$ ]]
}

# mask_emails: stdin filter that hides e-mail addresses (a***@e***.com).
mask_emails() {
    sed -E 's/([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9])[A-Za-z0-9.-]*\.([A-Za-z]{2,})/\1***@\2***.\3/g'
}

# --- host resolution --------------------------------------------------------

# Print the path of the Tailscale CLI, if any.
_t3w_tailscale_cli() {
    if command -v tailscale >/dev/null 2>&1; then
        command -v tailscale
    elif [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
        echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
    else
        return 1
    fi
}

# Succeeds if the host answers a non-interactive ssh within the timeout.
_t3w_ssh_probe() {
    ssh "${T3W_SSH_OPTS[@]}" -o BatchMode=yes "${T3W_USER}@$1" true >/dev/null 2>&1
}

# Succeeds if `tailscale status` lists the host as a peer that is not offline.
_t3w_tailscale_online() {
    local cli
    cli=$(_t3w_tailscale_cli) || return 1
    "$cli" status 2>/dev/null | awk -v h="$1" '$2 == h && $0 !~ /offline/ { found = 1 } END { exit !found }'
}

# t3w_resolve_host [--lan]: sets T3W_TARGET to a reachable user@host.
# Tries the Tailscale name first, then the LAN name. Returns 1 if neither works.
t3w_resolve_host() {
    local lan_only=0
    [[ "${1:-}" == "--lan" ]] && lan_only=1

    if (( ! lan_only )); then
        if _t3w_tailscale_cli >/dev/null; then
            if _t3w_tailscale_online "$T3W_HOST"; then
                if _t3w_ssh_probe "$T3W_HOST"; then
                    T3W_TARGET="${T3W_USER}@${T3W_HOST}"
                    return 0
                fi
                warn "$T3W_HOST ist im Tailnet online, SSH antwortet aber nicht (Tailscale-SSH-Freigabe im Browser nötig?)."
            else
                dim "$T3W_HOST ist laut Tailscale nicht online."
            fi
        elif _t3w_ssh_probe "$T3W_HOST"; then
            T3W_TARGET="${T3W_USER}@${T3W_HOST}"
            return 0
        fi
    fi

    if _t3w_ssh_probe "$T3W_LAN_HOST"; then
        (( lan_only )) || dim "Nutze LAN-Verbindung über $T3W_LAN_HOST."
        T3W_TARGET="${T3W_USER}@${T3W_LAN_HOST}"
        return 0
    fi
    return 1
}

# Print German fallback hints for an unreachable server.
t3w_unreachable_hints() {
    err "Server nicht erreichbar (weder $T3W_HOST noch $T3W_LAN_HOST)."
    cat >&2 <<EOF

Was du prüfen kannst:
  1. Tailscale auf dem Mac läuft und ist angemeldet (Menüleisten-Symbol).
  2. Web-Konsole (Cockpit): https://${T3W_HOST}:9090  oder  https://${T3W_LAN_HOST}:9090
  3. Im selben WLAN/LAN direkt: ssh ${T3W_USER}@${T3W_LAN_HOST}
  4. Laptop-Server: Deckel öffnen bzw. Netzteil prüfen, dann eine Minute warten.
EOF
}

# t3w_require_host [--lan]: resolve or exit with hints.
t3w_require_host() {
    t3w_resolve_host "$@" || { t3w_unreachable_hints; exit 1; }
}

# t3w_remote CMD...: run a command on the resolved server.
t3w_remote() {
    [[ -n "$T3W_TARGET" ]] || die "Interner Fehler: Zielhost nicht aufgelöst."
    # shellcheck disable=SC2029  # callers pass pre-quoted remote command strings
    ssh "${T3W_SSH_OPTS[@]}" "$T3W_TARGET" "$@"
}

# Remote PATH prefix so user-installed CLIs (uv tools, t3 launcher) are found
# in non-login ssh sessions.
# shellcheck disable=SC2034,SC2016  # used by sourcing scripts; expanded remotely
T3W_REMOTE_PATH='export PATH="$HOME/.local/bin:$HOME/.t3/bin:$HOME/bin:/usr/local/bin:$PATH";'
