#!/usr/bin/env bash
# Show the health of the t3-worker server: status.json, load, memory, disk,
# the T3 Code user service and the T7 mounts. Exits non-zero if unreachable.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=mac/lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
    cat <<EOF
Aufruf: $(basename "$0") [--lan] [--help]

Zeigt den Zustand von $T3W_HOST:
  - Statusdatei $T3W_STATUS_FILE (formatiert)
  - Laufzeit, Arbeitsspeicher, Speicherplatz auf /
  - T3-Code-Dienst ($T3W_SERVICE, Kurzform)
  - Einhängestatus der T7 (/srv/t7, /srv/timemachine, /srv/t7-mirror)

Optionen:
  --lan    direkt $T3W_LAN_HOST statt Tailscale verwenden
  --help   diese Hilfe

Exit-Code 1, wenn der Server nicht erreichbar ist.
EOF
}

RESOLVE_ARGS=()
while (($#)); do
    case "$1" in
        --lan) RESOLVE_ARGS=(--lan) ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unbekannte Option: $1" ;;
    esac
    shift
done

info "Suche Server ..."
t3w_require_host ${RESOLVE_ARGS[@]+"${RESOLVE_ARGS[@]}"}
ok "Verbunden mit $T3W_TARGET"

# --- status.json ------------------------------------------------------------
heading "Statusdatei"
if json=$(t3w_remote "cat $(printf '%q' "$T3W_STATUS_FILE")" </dev/null 2>/dev/null) && [[ -n "$json" ]]; then
    if command -v jq >/dev/null 2>&1; then
        printf '%s\n' "$json" | jq . 2>/dev/null || printf '%s\n' "$json"
    else
        printf '%s\n' "$json" | python3 -m json.tool 2>/dev/null || printf '%s\n' "$json"
    fi
else
    warn "$T3W_STATUS_FILE fehlt oder ist nicht lesbar (Health-Timer schon gelaufen?)."
fi

# --- system overview (rendered on the server) -------------------------------
# shellcheck disable=SC2016  # expanded on the server
remote_script='
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
section() { printf "\n\033[1m%s\033[0m\n" "$1"; }
section "Laufzeit"; uptime
section "Arbeitsspeicher"; free -h
section "Speicherplatz /"; df -h /
section "T3-Code-Dienst"
systemctl --user status "$1" --no-pager --lines=5 2>&1 | head -n 15 || true
section "T7"
for p in /srv/t7 /srv/timemachine /srv/t7-mirror; do
    if findmnt -n "$p" >/dev/null 2>&1; then
        findmnt -n -o TARGET,SOURCE,FSTYPE,SIZE,USE% "$p"
    else
        echo "$p: nicht eingehängt"
    fi
done
'
t3w_remote "bash -s -- $(printf '%q' "$T3W_SERVICE")" <<<"$remote_script" || warn "Systemübersicht unvollständig."
