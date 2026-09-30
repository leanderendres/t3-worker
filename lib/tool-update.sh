#!/usr/bin/env bash
# Daily update of the system packages and the agent tooling (timer 04:30).
# Every step runs independently with its own timeout; one failing step never
# stops the others. Result: $T3W_STATE/tool-update.json
#   {"finished": ISO-8601, "ok": bool, "steps": [{"name": str, "ok": bool}, ...]}
#
#   sudo /opt/t3-worker/lib/tool-update.sh             run
#   sudo DRY_RUN=1 /opt/t3-worker/lib/tool-update.sh   print the plan only
set -uo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"

STEP_NAMES=()
STEP_OKS=()

record() {
    STEP_NAMES+=("$1")
    STEP_OKS+=("$2")
    if [ "$2" = true ]; then ok "$1"; else fail "$1 fehlgeschlagen"; fi
}

# root_step NAME TIMEOUT CMD...: run a command as root with a time limit
root_step() {
    local name=$1 limit=$2 rc=0
    shift 2
    say "$name"
    if dry; then plan "timeout $limit $*"; record "$name" true; return 0; fi
    timeout --kill-after=2m "$limit" "$@" || rc=$?
    if [ "$rc" = 0 ]; then record "$name" true; else record "$name" false; fi
}

# The login shell of the service user does not necessarily have the user-local
# tool directories on PATH when started from a timer.
# shellcheck disable=SC2016  # expanded later by the user's shell
USER_PATH_PREFIX='export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"; '

# user_step NAME TIMEOUT 'shell code': run as $T3W_USER with a time limit
user_step() {
    local name=$1 limit=$2 code=$3 rc=0
    say "$name"
    if dry; then plan "als $T3W_USER: timeout $limit: $code"; record "$name" true; return 0; fi
    as_user "${USER_PATH_PREFIX}timeout --kill-after=1m $limit bash -c $(printf '%q' "$code")" || rc=$?
    if [ "$rc" = 0 ]; then record "$name" true; else record "$name" false; fi
}

# user_out 'shell code': read-only query as $T3W_USER, prints stdout (also in dry-run)
user_out() {
    local saved=$DRY_RUN out=''
    DRY_RUN=0
    out=$(as_user "${USER_PATH_PREFIX}$1" 2>/dev/null) || out=''
    DRY_RUN=$saved
    printf '%s' "$out"
}

main() {
    local started t3_before t3_after all_ok=true i steps_json='' sep=''

    if ! dry && [ "$(id -u)" -ne 0 ]; then die "tool-update.sh muss als root laufen"; fi
    if ! getent passwd "$T3W_USER" >/dev/null; then
        if dry; then warn "Benutzer $T3W_USER fehlt (Nutzer-Schritte nur geplant)"; else die "Benutzer $T3W_USER fehlt"; fi
    fi
    started=$(date +%s)
    phase "Werkzeug-Update $(date '+%F %H:%M')"

    # System packages. The snapper apt hooks (/etc/apt/apt.conf.d/80snapper)
    # take pre/post snapshots around the upgrade automatically.
    root_step "apt-get update" 20m apt-get -q -o DPkg::Lock::Timeout=600 update
    root_step "apt-get upgrade" 90m apt-get "${APT_OPTS[@]}" -o DPkg::Lock::Timeout=600 upgrade

    # User tooling
    user_step "claude update" 20m 'claude update'
    user_step "mise upgrade" 45m 'mise upgrade --yes'
    user_step "mise prune" 10m 'mise prune -y'
    # uv self update only works for the standalone installer; a mise-managed
    # uv was already upgraded by `mise upgrade`.
    user_step "uv self update" 10m 'if mise which uv >/dev/null 2>&1; then echo "uv wird von mise verwaltet"; else uv self update; fi'
    user_step "uv tool upgrade" 30m 'uv tool upgrade --all'
    user_step "npm update -g" 30m 'mise exec -- npm update -g'

    # T3 Code. `t3 update --yes` downloads the newest release on the current
    # channel and restarts the installed background service itself when the
    # version changed (no prompt without --yes in a script).
    t3_before=$(user_out 't3 --version')
    user_step "t3 update" 20m 't3 update --yes'
    t3_after=$(user_out 't3 --version')
    if dry; then
        :
    elif [ -n "$t3_after" ] && [ "$t3_after" != "$t3_before" ]; then
        ok "T3 Code aktualisiert: ${t3_before:-?} -> $t3_after (Dienst von t3 update neu gestartet)"
    else
        ok "T3 Code unverändert: ${t3_after:-unbekannt}"
    fi

    for i in "${!STEP_NAMES[@]}"; do
        [ "${STEP_OKS[$i]}" = true ] || all_ok=false
        steps_json+="$sep{\"name\":\"${STEP_NAMES[$i]}\",\"ok\":${STEP_OKS[$i]}}"
        sep=','
    done

    if dry; then
        plan "Ergebnis nach $T3W_STATE/tool-update.json schreiben"
        return 0
    fi
    state_dir
    write_json "$T3W_STATE/tool-update.json" <<EOF
{"finished":"$(date -Iseconds)","ok":$all_ok,"duration_s":$(($(date +%s) - started)),"steps":[$steps_json]}
EOF
    if [ "$all_ok" = true ]; then
        ok "Alle Schritte erfolgreich"
    else
        warn "Mindestens ein Schritt fehlgeschlagen, siehe journalctl -u t3-worker-tool-update"
        return 1
    fi
}

main "$@"
