#!/usr/bin/env bash
# require-mount.sh MOUNTPOINT: exit 0 only if MOUNTPOINT is a mounted filesystem.
# Used as Samba "root preexec": the share refuses connections while its drive is
# not mounted, so nothing is ever written to the SSD underneath.
set -uo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"

if [ $# -ne 1 ] || [ -z "$1" ]; then
    fail "Aufruf: require-mount.sh MOUNTPOINT"
    exit 2
fi
if mountpoint -q -- "$1"; then
    exit 0
fi
logger -t t3-worker "Freigabe abgelehnt: $1 ist nicht eingehängt" 2>/dev/null || true
fail "$1 ist nicht eingehängt"
exit 1
