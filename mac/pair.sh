#!/usr/bin/env bash
# Create a fresh T3 Code pairing link on the server and explain how to add
# the server as an environment in the T3 Code desktop app.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=mac/lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
    cat <<EOF
Aufruf: $(basename "$0") [--no-tailscale] [--lan] [--help]

Erzeugt auf $T3W_HOST einen neuen, einmaligen Kopplungslink für T3 Code
("t3 pair --tailscale", ersatzweise "t3 pair") und zeigt die nächsten Schritte.

Optionen:
  --no-tailscale  direkt "t3 pair" verwenden (ohne Tailscale HTTPS)
  --lan           direkt $T3W_LAN_HOST statt Tailscale verwenden
  --help          diese Hilfe

Den Link wie ein Passwort behandeln: nicht teilen, nicht in Chats einfügen.
EOF
}

USE_TAILSCALE=1
RESOLVE_ARGS=()
while (($#)); do
    case "$1" in
        --no-tailscale) USE_TAILSCALE=0 ;;
        --lan) RESOLVE_ARGS=(--lan) ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unbekannte Option: $1" ;;
    esac
    shift
done

info "Suche Server ..."
t3w_require_host ${RESOLVE_ARGS[@]+"${RESOLVE_ARGS[@]}"}
ok "Verbunden mit $T3W_TARGET"

remote_check="$T3W_REMOTE_PATH command -v t3 >/dev/null || { echo 't3 fehlt auf dem Server' >&2; exit 127; };"

output=""
if ((USE_TAILSCALE)); then
    info "Erzeuge Kopplungslink (t3 pair --tailscale) ..."
    if ! output=$(t3w_remote "$remote_check t3 pair --tailscale" </dev/null 2>&1); then
        warn "\"t3 pair --tailscale\" fehlgeschlagen; versuche \"t3 pair\"."
        printf '%s\n' "$output" | tail -n 5 | sed 's/^/   /' >&2
        output=""
    fi
fi
if [[ -z "$output" ]]; then
    info "Erzeuge Kopplungslink (t3 pair) ..."
    output=$(t3w_remote "$remote_check t3 pair" </dev/null 2>&1) || {
        printf '%s\n' "$output" >&2
        die "Kopplungslink konnte nicht erzeugt werden. Läuft der Dienst? Prüfen mit: $SCRIPT_DIR/status.sh"
    }
fi

link=$(printf '%s\n' "$output" | grep -Eo 'https?://[^[:space:]"<>]+' | tail -n 1 || true)
if [[ -z "$link" ]]; then
    warn "Kein Link in der Ausgabe gefunden. Vollständige Ausgabe:"
    printf '%s\n' "$output"
    exit 1
fi

heading "Kopplungslink (einmalig gültig, wie ein Passwort behandeln)"
printf '\n   %s%s%s\n' "$_C_BOLD" "$link" "$_C_RESET"
if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$link" | pbcopy
    dim "   (in die Zwischenablage kopiert)"
fi

heading "So geht es weiter"
cat <<EOF
  1. T3 Code öffnen → Settings → Connections.
  2. "Add environment" wählen und den Link einfügen.
  3. Danach "Load balancing" aktivieren und die Vorlieben setzen:
       $T3W_HOST   Prefer
       MacBook     Less often
     So laufen neue Aufgaben überwiegend auf dem Server.
EOF
