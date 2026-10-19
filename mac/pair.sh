#!/usr/bin/env bash
# Create a fresh T3 Code pairing link on the server and explain how to add
# the server as an environment in the T3 Code desktop app.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=mac/lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
    cat <<EOF
Aufruf: $(basename "$0") [--phone] [--no-tailscale] [--lan] [--help]

Erzeugt auf $T3W_HOST einen neuen, einmaligen Kopplungslink für T3 Code
("t3 pair --tailscale", ersatzweise "t3 pair") und zeigt die nächsten Schritte.

Optionen:
  --phone         Link für das iPhone: QR-Code im Terminal, 15 Minuten gültig,
                  Bezeichnung "iPhone" in der Verbindungsliste des Servers
  --no-tailscale  direkt "t3 pair" verwenden (ohne Tailscale HTTPS)
  --lan           direkt $T3W_LAN_HOST statt Tailscale verwenden
  --help          diese Hilfe

Den Link wie ein Passwort behandeln: nicht teilen, nicht in Chats einfügen.
EOF
}

USE_TAILSCALE=1
PHONE=0
RESOLVE_ARGS=()
while (($#)); do
    case "$1" in
        --phone) PHONE=1 ;;
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
pair_flags=""
((PHONE)) && pair_flags=" --ttl 15m --label iPhone"

output=""
if ((USE_TAILSCALE)); then
    info "Erzeuge Kopplungslink (t3 pair --tailscale) ..."
    if ! output=$(t3w_remote "$remote_check NO_COLOR=1 t3 pair --tailscale$pair_flags" </dev/null 2>&1); then
        warn "\"t3 pair --tailscale\" fehlgeschlagen; versuche \"t3 pair\"."
        printf '%s\n' "$output" | tail -n 5 | sed 's/^/   /' >&2
        output=""
    fi
fi
if [[ -z "$output" ]]; then
    info "Erzeuge Kopplungslink (t3 pair) ..."
    output=$(t3w_remote "$remote_check NO_COLOR=1 t3 pair$pair_flags" </dev/null 2>&1) || {
        printf '%s\n' "$output" >&2
        die "Kopplungslink konnte nicht erzeugt werden. Läuft der Dienst? Prüfen mit: $SCRIPT_DIR/status.sh"
    }
fi

# Strip ANSI colour codes first: a trailing escape sequence made the pasted link invalid.
output=$(printf '%s\n' "$output" | LC_ALL=C sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g')
link=$(printf '%s\n' "$output" | LC_ALL=C grep -Eao 'https?://[A-Za-z0-9.:-]+/pair#token=[A-Za-z0-9_-]+' | tail -n 1 || true)
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

if ((PHONE)); then
    # t3 pair prints the QR code as block characters; show only those lines.
    heading "QR-Code (mit der T3-Code-App auf dem iPhone scannen)"
    printf '%s\n' "$output" | grep -E '[█▀▄]' || dim "   (kein QR-Code in der Ausgabe, Link über die Zwischenablage nutzen)"
    heading "So geht es weiter"
    cat <<EOF
  1. Auf dem iPhone Tailscale einschalten (gleiches Konto wie der Mac).
  2. T3-Code-App (Version 2) öffnen → Settings → Environments → Add environment.
  3. QR-Code scannen oder den Link einfügen (gemeinsame Zwischenablage von
     Mac und iPhone). Der Link gilt 15 Minuten und nur einmal.
EOF
    exit 0
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
