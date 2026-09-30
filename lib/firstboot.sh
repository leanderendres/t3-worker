#!/bin/sh
# First boot of a freshly installed t3-worker (installed by installer/late.sh as
# /usr/local/sbin/t3-worker-firstboot, started once by t3-worker-firstboot.service).
#
# 1. fetch the current setup repository from GitHub (retries for ~5 minutes);
#    the copy embedded on the install stick is only the fallback
# 2. run setup.sh --unattended: everything that needs no input. Steps that need
#    a person (HDD format confirmation, Tailscale login, Samba password, pairing)
#    are recorded as open items and shown in the SSH login message (motd).

export GIT_TERMINAL_PROMPT=0
REPO_URL=${T3W_REPO_URL:-https://github.com/leanderendres/t3-worker.git}
DIR=/opt/t3-worker
NEW=/opt/t3-worker.fetch

log() { echo "t3-worker-firstboot: $*"; }

fetched=0
for delay in 5 10 15 30 30 60 60 60 60; do
    rm -rf "$NEW"
    if git clone -q --depth 1 "$REPO_URL" "$NEW" 2>/dev/null && [ -f "$NEW/setup.sh" ]; then
        fetched=1
        break
    fi
    log "GitHub nicht erreichbar, neuer Versuch in ${delay}s ..."
    sleep "$delay"
done

if [ "$fetched" = 1 ]; then
    rm -rf "$DIR.stick"
    [ -d "$DIR" ] && mv "$DIR" "$DIR.stick"
    mv "$NEW" "$DIR"
    rm -rf "$DIR.stick"
    log "aktuelles Setup-Repo von GitHub geholt ($(git -C "$DIR" rev-parse --short HEAD))."
else
    rm -rf "$NEW"
    log "GitHub nicht erreichbar: verwende die Kopie vom Installationsstick."
fi

chmod 0755 "$DIR/setup.sh" "$DIR"/lib/*.sh
exec "$DIR/setup.sh" --unattended
