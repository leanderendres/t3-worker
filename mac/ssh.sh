#!/usr/bin/env bash
# Open an SSH session on the t3-worker server (Tailscale first, LAN fallback).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=mac/lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
    cat <<EOF
Aufruf: $(basename "$0") [--lan] [--help] [BEFEHL ...]

Öffnet eine SSH-Sitzung auf $T3W_HOST (über Tailscale, sonst $T3W_LAN_HOST).
Weitere Argumente werden als Befehl auf dem Server ausgeführt, z. B.:
  $(basename "$0") t3 service status

Optionen:
  --lan    direkt $T3W_LAN_HOST verwenden
  --help   diese Hilfe
EOF
}

RESOLVE_ARGS=()
while (($#)); do
    case "$1" in
        --lan) RESOLVE_ARGS=(--lan) ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        *) break ;;
    esac
    shift
done

t3w_require_host ${RESOLVE_ARGS[@]+"${RESOLVE_ARGS[@]}"}
exec ssh "${T3W_SSH_OPTS[@]}" "$T3W_TARGET" "$@"
