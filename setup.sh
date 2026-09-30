#!/usr/bin/env bash
# t3-worker setup: turns a fresh Debian 13 install into a headless, always-on
# agent server for T3 Code. Idempotent: safe to run again at any time.
#
#   sudo /opt/t3-worker/setup.sh              all phases (asks where needed)
#   sudo /opt/t3-worker/setup.sh --unattended skip everything that needs input
#   sudo /opt/t3-worker/setup.sh --check      detect hardware, print planned actions only
#   sudo /opt/t3-worker/setup.sh --phase samba --phase t3
#   curl -fsSL https://raw.githubusercontent.com/leanderendres/t3-worker/main/setup.sh | bash
#
# Log: /var/log/t3-worker-setup.log (pairing links are never written to it).

set -Eeuo pipefail

REPO_URL_DEFAULT=https://github.com/leanderendres/t3-worker.git
INSTALL_DIR=/opt/t3-worker

# --- bootstrap: piped through curl, or not yet running from /opt/t3-worker ----
self=${BASH_SOURCE[0]:-}
# resolve the /usr/local/sbin/t3-worker-setup symlink
[ -z "$self" ] || [ ! -e "$self" ] || self=$(readlink -f "$self")
if [ -z "$self" ] || [ ! -f "$self" ] || [ ! -f "$(dirname "$self")/lib/common.sh" ]; then
    SUDO=""
    [ "$(id -u)" -eq 0 ] || SUDO=sudo
    echo "t3-worker: hole die Setup-Skripte nach $INSTALL_DIR ..."
    if ! command -v git >/dev/null 2>&1; then
        $SUDO apt-get -q update && $SUDO apt-get -y -q install git ca-certificates
    fi
    if [ -d "$INSTALL_DIR/.git" ]; then
        $SUDO git -C "$INSTALL_DIR" pull --ff-only
    else
        tmp=$($SUDO mktemp -d)
        $SUDO git clone --depth 1 "${T3W_REPO_URL:-$REPO_URL_DEFAULT}" "$tmp/t3-worker"
        [ -d "$INSTALL_DIR" ] && $SUDO mv "$INSTALL_DIR" "$INSTALL_DIR.old-$(date +%Y%m%d-%H%M%S)"
        $SUDO mv "$tmp/t3-worker" "$INSTALL_DIR"
        $SUDO rmdir "$tmp"
    fi
    if { : </dev/tty; } 2>/dev/null; then
        exec $SUDO bash "$INSTALL_DIR/setup.sh" "$@" </dev/tty
    fi
    exec $SUDO bash "$INSTALL_DIR/setup.sh" "$@"
fi

T3W_ROOT=$(cd "$(dirname "$self")" && pwd)
export T3W_ROOT
# shellcheck source=lib/common.sh
. "$T3W_ROOT/lib/common.sh"
for f in "$T3W_ROOT"/lib/phases-*.sh; do
    # shellcheck source=/dev/null
    . "$f"
done
# shellcheck disable=SC2034  # used by phase_repo to re-exec after an update
ORIG_ARGS=("$@")

ALL_PHASES=(repo preflight base system repos tools browser firewall cockpit storage samba timers tailscale t3 claude agenthome summary)

describe_phase() {
    case "$1" in
        preflight) echo "Voraussetzungen und Hardware erkennen" ;;
        repo)      echo "Setup-Repo auf Git-Stand bringen" ;;
        base)      echo "Grundpakete aus Debian" ;;
        system)    echo "Btrfs/Snapper, zram, Watchdog, Deckel, Updates, SSH, NVIDIA aus" ;;
        repos)     echo "Docker, Tailscale, GitHub CLI, mise (offizielle Paketquellen)" ;;
        tools)     echo "Node LTS, pnpm, uv, claude-swap, Claude Code, T3 Code (als $T3W_USER)" ;;
        browser)   echo "Chromium und Playwright-Abhängigkeiten" ;;
        firewall)  echo "Samba/Cockpit nur aus LAN und Tailscale" ;;
        cockpit)   echo "Cockpit mit Statusseite" ;;
        storage)   echo "HDD (Time Machine + Spiegel) und T7 einbinden" ;;
        samba)     echo "Freigaben T7 und TimeMachine" ;;
        timers)    echo "Health-, Update- und Spiegel-Timer" ;;
        tailscale) echo "Tailscale anmelden (SSH, Hostname t3-worker)" ;;
        t3)        echo "T3-Code-Dienst und Pairing-Link" ;;
        claude)    echo "Claude-Konten anmelden (claude-swap, automatischer Wechsel)" ;;
        agenthome) echo "agent-home (gemeinsame Agenten-Regeln) klonen und synchronisieren" ;;
        summary)   echo "Zusammenfassung und nächste Schritte" ;;
    esac
}

usage() {
    cat <<EOF
Aufruf: sudo $T3W_ROOT/setup.sh [--check] [--unattended] [--phase NAME ...] [--list]

  --check, --dry-run  nur erkennen und geplante Schritte zeigen, nichts ändern
  --unattended        alle Schritte ohne Rückfragen; Interaktives wird übersprungen
  --phase NAME        nur diese Phase(n) ausführen (mehrfach möglich)
  --list              Phasen auflisten
EOF
}

SELECTED=()
while [ $# -gt 0 ]; do
    case "$1" in
        --check|--dry-run) DRY_RUN=1 ;;
        --unattended) UNATTENDED=1 ;;
        --phase) SELECTED+=("${2:?Phase fehlt}"); shift ;;
        --list)
            for p in "${ALL_PHASES[@]}"; do printf '  %-10s %s\n' "$p" "$(describe_phase "$p")"; done
            exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unbekannte Option: $1" ;;
    esac
    shift
done
export DRY_RUN UNATTENDED
[ ${#SELECTED[@]} -gt 0 ] || SELECTED=("${ALL_PHASES[@]}")
for p in "${SELECTED[@]}"; do
    declare -F "phase_$p" >/dev/null || die "Unbekannte Phase: $p (siehe --list)"
done

if [ "$(id -u)" -ne 0 ]; then
    if dry; then
        warn "Nicht als root: Prüfung läuft eingeschränkt."
    else
        exec sudo bash "$self" "${ORIG_ARGS[@]}"
    fi
fi

# --- logging and locking --------------------------------------------------------
if ! dry && [ "$(id -u)" -eq 0 ] && [ "${T3W_REEXEC:-0}" != 1 ]; then
    touch "$T3W_LOG" && chmod 0640 "$T3W_LOG"
    exec > >(tee -a "$T3W_LOG") 2>&1
    exec 9>/run/t3-worker-setup.lock
    if ! flock -n 9; then
        say "Ein anderes Setup läuft gerade (z. B. die Ersteinrichtung nach dem ersten Start). Warte ..."
        flock 9
    fi
fi

trap 'fail "Abbruch in Zeile $LINENO (Phase ${CURRENT_PHASE:-?}). Log: $T3W_LOG"' ERR

printf '\n%st3-worker Setup%s  %s  %s\n' "$C_B" "$C_0" "$(date '+%Y-%m-%d %H:%M')" \
    "$( dry && echo '(Prüfmodus, es wird nichts geändert)' )$( [ "$UNATTENDED" = 1 ] && echo '(ohne Rückfragen)' )"

state_dir
for p in "${SELECTED[@]}"; do
    CURRENT_PHASE=$p
    phase "$p: $(describe_phase "$p")"
    "phase_$p"
done
CURRENT_PHASE=""
dry || date -Iseconds >"$T3W_STATE/setup.last" 2>/dev/null || true
printf '\n%sFertig.%s\n' "$C_G" "$C_0"
