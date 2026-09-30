#!/usr/bin/env bash
# Copy the Claude Code accounts managed by claude-swap (cswap) from this Mac
# to the t3-worker server. The export file holds OAuth credentials: it only
# ever lives in 0700 temp dirs with 0600 perms and is wiped on every exit path.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=mac/lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
    cat <<EOF
Aufruf: $(basename "$0") [--account NUM] [--force] [--yes] [--lan] [--help]

Überträgt die mit claude-swap (cswap) verwalteten Claude-Code-Konten vom Mac
auf den Server $T3W_HOST:
  1. zeigt die Kontenliste (E-Mail-Adressen maskiert) und fragt nach
  2. exportiert die Konten in eine geschützte temporäre Datei
  3. kopiert sie per scp in ein geschütztes Temp-Verzeichnis auf dem Server
  4. importiert sie dort mit "cswap import" und zeigt "cswap list"
  5. löscht die Datei auf Server und Mac (auch bei Abbruch oder Fehler)

Optionen:
  --account NUM   nur ein Konto übertragen (Nummer aus "cswap list")
  --force         vorhandene Konten auf dem Server überschreiben
  --yes           ohne Rückfrage fortfahren
  --lan           direkt $T3W_LAN_HOST statt Tailscale verwenden
  --help          diese Hilfe

Hinweis: Die Anmeldungen werden kopiert, nicht verschoben. Erneuert eine Seite
ihr Token, kann die Anmeldung auf der anderen Seite ungültig werden; dann das
Konto dort neu anmelden oder dieses Skript mit --force erneut ausführen.
EOF
}

ACCOUNT=""
FORCE=0
RESOLVE_ARGS=()
while (($#)); do
    case "$1" in
        --account) [[ $# -ge 2 ]] || die "--account braucht eine Kontonummer."; ACCOUNT=$2; shift ;;
        --force) FORCE=1 ;;
        --yes) T3W_YES=1 ;;
        --lan) RESOLVE_ARGS=(--lan) ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unbekannte Option: $1" ;;
    esac
    shift
done

CSWAP=$(command -v cswap || true)
[[ -z "$CSWAP" && -x "$HOME/.local/bin/cswap" ]] && CSWAP="$HOME/.local/bin/cswap"
[[ -n "$CSWAP" ]] || die "cswap nicht gefunden. Installation: uv tool install claude-swap"

LOCAL_DIR=""
LOCAL_FILE=""
REMOTE_DIR=""

# Wipe a local file without printing it: rm -P overwrites before unlinking.
_wipe_local() {
    [[ -n "$1" && -e "$1" ]] || return 0
    rm -P "$1" 2>/dev/null || rm -f "$1"
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP
    if [[ -n "$REMOTE_DIR" ]]; then
        # shred -u if available, else rm -P, else rm; then drop the dir.
        if t3w_remote "d=$(printf '%q' "$REMOTE_DIR"); for f in \"\$d\"/*; do [ -e \"\$f\" ] || continue; shred -u \"\$f\" 2>/dev/null || rm -P \"\$f\" 2>/dev/null || rm -f \"\$f\"; done; rmdir \"\$d\"" </dev/null; then
            dim "Temporäre Datei auf dem Server gelöscht."
        else
            err "Konnte $REMOTE_DIR auf dem Server nicht löschen. Bitte manuell entfernen: ssh $T3W_TARGET 'shred -u $REMOTE_DIR/*; rmdir $REMOTE_DIR'"
            rc=1
        fi
    fi
    if [[ -n "$LOCAL_DIR" ]]; then
        _wipe_local "$LOCAL_FILE"
        rm -rf "$LOCAL_DIR"
        dim "Temporäre Datei auf dem Mac gelöscht."
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# --- 1. Show and confirm ----------------------------------------------------
heading "Konten auf diesem Mac"
"$CSWAP" list 2>&1 | mask_emails
echo

info "Suche Server ..."
t3w_require_host ${RESOLVE_ARGS[@]+"${RESOLVE_ARGS[@]}"}
ok "Ziel: $T3W_TARGET"

what="alle Konten"
[[ -n "$ACCOUNT" ]] && what="Konto $ACCOUNT"
confirm "Sollen $what auf $T3W_TARGET übertragen werden?" || { info "Abgebrochen, nichts übertragen."; exit 0; }

# --- 2. Export --------------------------------------------------------------
umask 077
LOCAL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/t3w-accounts.XXXXXX")
chmod 700 "$LOCAL_DIR"
LOCAL_FILE="$LOCAL_DIR/accounts.json"
: >"$LOCAL_FILE"
chmod 600 "$LOCAL_FILE"

export_args=(export "$LOCAL_FILE")
[[ -n "$ACCOUNT" ]] && export_args+=(--account "$ACCOUNT")
info "Exportiere Konten ..."
"$CSWAP" "${export_args[@]}" 2>&1 | mask_emails
[[ -s "$LOCAL_FILE" ]] || die "Export ist leer; Abbruch."
chmod 600 "$LOCAL_FILE"

# --- 3. Copy ----------------------------------------------------------------
info "Lege geschütztes Temp-Verzeichnis auf dem Server an ..."
# shellcheck disable=SC2016  # expanded on the server
REMOTE_DIR=$(t3w_remote 'umask 077; d=$(mktemp -d "${TMPDIR:-/tmp}/t3w-accounts.XXXXXX") && chmod 700 "$d" && printf "%s\n" "$d"' </dev/null)
[[ "$REMOTE_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || { REMOTE_DIR=""; die "Unerwartete Antwort beim Anlegen des Temp-Verzeichnisses."; }
REMOTE_FILE="$REMOTE_DIR/accounts.json"

info "Kopiere Exportdatei (scp) ..."
scp -q -p "${T3W_SSH_OPTS[@]}" "$LOCAL_FILE" "$T3W_TARGET:$REMOTE_FILE"
t3w_remote "chmod 600 $(printf '%q' "$REMOTE_FILE")" </dev/null

# --- 4. Import and verify ---------------------------------------------------
import_cmd="cswap import $(printf '%q' "$REMOTE_FILE")"
((FORCE)) && import_cmd+=" --force"
info "Importiere auf dem Server ..."
t3w_remote "$T3W_REMOTE_PATH command -v cswap >/dev/null || { echo 'cswap fehlt auf dem Server (uv tool install claude-swap)' >&2; exit 127; }; $import_cmd" </dev/null 2>&1 | mask_emails

heading "Konten auf dem Server"
t3w_remote "$T3W_REMOTE_PATH cswap list" </dev/null 2>&1 | mask_emails
echo
ok "Übertragung abgeschlossen."
# cleanup runs via the EXIT trap.
