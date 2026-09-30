#!/usr/bin/env bash
# Prepare this Mac for the t3-worker server: Tailscale app, SSH config block,
# SSH key check. Idempotent; safe to run again.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=mac/lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
    cat <<EOF
Aufruf: $(basename "$0") [--dry-run] [--ssh-only] [--help]

Richtet den Mac für den t3-worker ein:
  - installiert die Tailscale-App über Homebrew, falls sie fehlt
  - ergänzt ~/.ssh/config um einen Block für "$T3W_HOST $T3W_LAN_HOST"
    (nur wenn noch keiner existiert; vorher wird eine Sicherung angelegt)
  - prüft, ob der SSH-Schlüssel ~/.ssh/id_ed25519 vorhanden ist

Optionen:
  --dry-run   nur anzeigen, was passieren würde; nichts ändern
  --ssh-only  Tailscale-Schritt überspringen (nur SSH-Konfiguration und Schlüssel)
  --help      diese Hilfe

Umgebung: T3W_SSH_CONFIG überschreibt den Pfad zur SSH-Konfiguration
          (Standard: ~/.ssh/config).
EOF
}

DRY_RUN=0
SSH_ONLY=0
while (($#)); do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --ssh-only) SSH_ONLY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unbekannte Option: $1" ;;
    esac
    shift
done

SSH_DIR="$HOME/.ssh"
SSH_CONFIG=${T3W_SSH_CONFIG:-$SSH_DIR/config}
SSH_KEY="$SSH_DIR/id_ed25519"
BLOCK_BEGIN="# >>> t3-worker (managed by t3-worker/mac/install-mac.sh) >>>"
BLOCK_END="# <<< t3-worker <<<"

# run CMD...: execute, or only print in dry-run mode.
run() {
    if ((DRY_RUN)); then
        printf '%s[dry-run]%s %s\n' "$_C_DIM" "$_C_RESET" "$*"
    else
        "$@"
    fi
}

(( DRY_RUN )) && info "Probelauf: es wird nichts verändert."

# --- 1. Tailscale -----------------------------------------------------------
heading "1. Tailscale"
if ((SSH_ONLY)); then
    dim "Übersprungen (--ssh-only)."
elif [[ -d /Applications/Tailscale.app ]] || command -v tailscale >/dev/null 2>&1; then
    ok "Tailscale ist bereits installiert."
else
    BREW=$(command -v brew || true)
    [[ -z "$BREW" && -x /opt/homebrew/bin/brew ]] && BREW=/opt/homebrew/bin/brew
    [[ -n "$BREW" ]] || die "Homebrew fehlt. Installation: https://brew.sh"
    info "Installiere die Tailscale-App (Homebrew-Cask tailscale-app) ..."
    run "$BREW" install --cask tailscale-app
    ((DRY_RUN)) || ok "Tailscale installiert."
fi
if ((!SSH_ONLY)); then
    cat <<EOF
   Nächster Schritt: Tailscale öffnen (Programme → Tailscale), in der Menüleiste
   anmelden und mit demselben Konto wie der Server verbinden.
EOF
fi

# --- 2. SSH config ----------------------------------------------------------
heading "2. SSH-Konfiguration"
if [[ ! -d "$SSH_DIR" ]]; then
    info "Lege $SSH_DIR an."
    run mkdir -p "$SSH_DIR"
    run chmod 700 "$SSH_DIR"
fi

if [[ -f "$SSH_CONFIG" ]] && grep -Eiq "^[[:space:]]*Host([[:space:]]+[^#]*)?[[:space:]]${T3W_HOST//./\\.}([[:space:]]|$)" "$SSH_CONFIG"; then
    ok "$SSH_CONFIG enthält bereits einen Eintrag für $T3W_HOST; keine Änderung."
else
    BLOCK=$(cat <<EOF

$BLOCK_BEGIN
Host $T3W_HOST $T3W_LAN_HOST
    User $T3W_USER
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
$BLOCK_END
EOF
)
    if [[ -f "$SSH_CONFIG" ]]; then
        BACKUP="$SSH_CONFIG.bak.$(date +%Y%m%d-%H%M%S)"
        info "Sichere $SSH_CONFIG nach $BACKUP."
        run cp -p "$SSH_CONFIG" "$BACKUP"
    else
        info "Lege $SSH_CONFIG neu an."
        run touch "$SSH_CONFIG"
        run chmod 600 "$SSH_CONFIG"
    fi
    info "Ergänze folgenden Block in $SSH_CONFIG:"
    printf '%s\n' "$BLOCK" | sed 's/^/     /'
    if ((DRY_RUN)); then
        printf '%s[dry-run]%s Block an %s anhängen\n' "$_C_DIM" "$_C_RESET" "$SSH_CONFIG"
    else
        printf '%s\n' "$BLOCK" >>"$SSH_CONFIG"
        ok "SSH-Eintrag ergänzt."
    fi
fi

# --- 3. SSH key -------------------------------------------------------------
heading "3. SSH-Schlüssel"
if [[ -f "$SSH_KEY" && -f "$SSH_KEY.pub" ]]; then
    ok "Schlüssel $SSH_KEY vorhanden."
    cat <<EOF
   Über Tailscale SSH ist kein Schlüssel auf dem Server nötig. Für den
   LAN-Weg ($T3W_LAN_HOST) den öffentlichen Schlüssel einmalig hinterlegen:
     ssh-copy-id -i $SSH_KEY.pub $T3W_USER@$T3W_LAN_HOST
EOF
else
    warn "Schlüssel $SSH_KEY fehlt."
    cat <<EOF
   Anlegen mit:
     ssh-keygen -t ed25519 -f $SSH_KEY
   und danach dieses Skript erneut ausführen.
EOF
fi

heading "Fertig"
if ((DRY_RUN)); then
    info "Probelauf beendet. Ohne --dry-run ausführen, um die Änderungen anzuwenden."
else
    ok "Mac vorbereitet. Verbindung testen mit: $SCRIPT_DIR/status.sh"
fi
