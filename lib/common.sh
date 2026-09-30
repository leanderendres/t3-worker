# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are consumed by the scripts that source this file
# Shared helpers for setup.sh and the timer scripts. Source, do not execute.
#
# User-facing output is German, code and comments are English.

T3W_ROOT=${T3W_ROOT:-/opt/t3-worker}
T3W_USER=${T3W_USER:-leander}
T3W_HOSTNAME=${T3W_HOSTNAME:-t3-worker}
T3W_STATE=${T3W_STATE:-/var/lib/t3-worker}
T3W_LOG=${T3W_LOG:-/var/log/t3-worker-setup.log}
T3W_REPO_URL=${T3W_REPO_URL:-https://github.com/leanderendres/t3-worker.git}
T3W_AGENT_HOME_URL=${T3W_AGENT_HOME_URL:-https://github.com/leanderendres/agent-home.git}

# Hardware (see README). Override in /etc/t3-worker/config if needed.
SSD_MODEL=${SSD_MODEL:-HFS128G39TND}
HDD_MODEL=${HDD_MODEL:-MQ04ABF100}
T7_LABEL=${T7_LABEL:-T7 Shield}

# Mount points and sizes
T7_PATH=${T7_PATH:-/srv/t7}
TM_PATH=${TM_PATH:-/srv/timemachine}
MIRROR_PATH=${MIRROR_PATH:-/srv/t7-mirror}
TM_SIZE_GIB=${TM_SIZE_GIB:-560}   # ~600 GB for Time Machine, rest (~400 GB) for the T7 mirror
TM_QUOTA=${TM_QUOTA:-540G}

DRY_RUN=${DRY_RUN:-0}
UNATTENDED=${UNATTENDED:-0}

if [ -r /etc/t3-worker/config ]; then
    # shellcheck source=/dev/null
    . /etc/t3-worker/config
fi

# --- output ---------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_B=$'\033[1m' C_BL=$'\033[1;34m' C_G=$'\033[32m' C_Y=$'\033[33m' C_R=$'\033[31m' C_0=$'\033[0m'
else
    C_B='' C_BL='' C_G='' C_Y='' C_R='' C_0=''
fi
phase() { printf '\n%s== %s ==%s\n' "$C_BL" "$*" "$C_0"; }
say()   { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()    { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn()  { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
fail()  { printf '  %s✗%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()   { printf '%sFehler:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
plan()  { printf '  [Plan] %s\n' "$*"; }

dry() { [ "$DRY_RUN" = 1 ]; }

# run CMD...: execute, or only print in dry-run mode
run() {
    if dry; then plan "$*"; else "$@"; fi
}

# svc ARGS...: systemctl (only printed in dry-run mode)
svc() { run systemctl "$@"; }

# --- files ----------------------------------------------------------------
# CHANGED is set to 1 by install_file/write_file when the target changed.
CHANGED=0

# install_file SRC DEST [MODE]
install_file() {
    local src=$1 dest=$2 mode=${3:-0644}
    CHANGED=0
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        return 0
    fi
    CHANGED=1
    if dry; then
        plan "Datei schreiben: $dest"
        return 0
    fi
    install -D -m "$mode" "$src" "$dest"
    ok "geschrieben: $dest"
}

# write_file DEST [MODE] <<< content
write_file() {
    local dest=$1 mode=${2:-0644} tmp
    tmp=$(mktemp)
    cat >"$tmp"
    install_file "$tmp" "$dest" "$mode"
    rm -f "$tmp"
}

# ensure_block FILE MARKER <<< content: keep a managed block inside a file
ensure_block() {
    local file=$1 marker=$2 tmp body
    body=$(cat)
    tmp=$(mktemp)
    if [ -f "$file" ]; then
        awk -v b="# >>> $marker >>>" -v e="# <<< $marker <<<" '
            $0 == b { skip = 1; next }
            $0 == e { skip = 0; next }
            !skip { print }' "$file" >"$tmp"
    fi
    printf '# >>> %s >>>\n%s\n# <<< %s <<<\n' "$marker" "$body" "$marker" >>"$tmp"
    install_file "$tmp" "$file" "$(stat -c %a "$file" 2>/dev/null || echo 0644)"
    rm -f "$tmp"
}

# --- packages ---------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

# apt_install [--no-recommends] PKG...: install only what is missing
apt_install() {
    local extra=() missing=() p
    if [ "${1:-}" = "--no-recommends" ]; then extra=(--no-install-recommends); shift; fi
    for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
    if [ ${#missing[@]} -eq 0 ]; then
        ok "Pakete vorhanden: $*"
        return 0
    fi
    if dry; then
        plan "apt-get install ${missing[*]}"
        return 0
    fi
    say "Installiere: ${missing[*]}"
    apt-get "${APT_OPTS[@]}" install "${extra[@]}" "${missing[@]}"
}

APT_UPDATED=0
apt_update() {
    if dry; then plan "apt-get update"; return 0; fi
    if [ "$APT_UPDATED" = 0 ] || [ "${1:-}" = "--force" ]; then
        apt-get -q update
        APT_UPDATED=1
    fi
}

# --- service user -------------------------------------------------------------
user_home() { getent passwd "$T3W_USER" | cut -d: -f6; }
user_uid() { id -u "$T3W_USER"; }

# as_user 'shell code': run in a login shell of the service user, with access
# to the user's systemd instance (needs linger or an active session).
as_user() {
    if dry; then plan "als $T3W_USER: $*"; return 0; fi
    local home uid
    home=$(user_home)
    uid=$(user_uid)
    runuser -u "$T3W_USER" -- env -i \
        HOME="$home" USER="$T3W_USER" LOGNAME="$T3W_USER" SHELL=/bin/bash \
        PATH=/usr/local/bin:/usr/bin:/bin LANG="${LANG:-de_DE.UTF-8}" TERM="${TERM:-dumb}" \
        XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        bash -lc "$1"
}

# as_user_quiet: like as_user, but always executes (used for read-only checks)
as_user_check() {
    local saved=$DRY_RUN rc=0
    DRY_RUN=0
    as_user "$1" >/dev/null 2>&1 || rc=$?
    DRY_RUN=$saved
    return $rc
}

# --- interaction ----------------------------------------------------------------
have_tty() { [ "$UNATTENDED" != 1 ] && { : </dev/tty; } 2>/dev/null; }

# ask VAR "Frage": read one line from the terminal (not from a curl pipe)
ask() {
    local __var=$1 __prompt=$2 __answer=''
    have_tty || return 1
    read -r -p "$__prompt " __answer </dev/tty || return 1
    printf -v "$__var" '%s' "$__answer"
}

# confirm "Frage": yes/no, default no
confirm() {
    local a=''
    ask a "$1 [j/N]" || return 1
    case "$a" in j|J|ja|Ja|y|Y|yes) return 0 ;; *) return 1 ;; esac
}

# --- disks ------------------------------------------------------------------------
# lsblk_field KEY LINE: extract KEY="value" from `lsblk -P` output
lsblk_field() { sed -nE "s/.*(^| )$1=\"([^\"]*)\".*/\2/p" <<<"$2"; }

# find_disk_by_model MODEL: print /dev/sdX of the single non-USB disk whose model
# (full udev model or truncated sysfs model) contains MODEL.
find_disk_by_model() {
    local want=$1 line name model tran hits=()
    while IFS= read -r line; do
        name=$(lsblk_field NAME "$line")
        tran=$(lsblk_field TRAN "$line")
        model=$(lsblk_field MODEL "$line")
        [ "$tran" = "usb" ] && continue
        case "$model" in *"$want"*) hits+=("$name") ;; esac
    done < <(lsblk -dnpP -o NAME,TRAN,MODEL 2>/dev/null)
    if [ ${#hits[@]} -eq 0 ]; then
        local link dev
        for link in /dev/disk/by-id/ata-*"$want"*; do
            [ -e "$link" ] || continue
            case "$link" in *-part*) continue ;; esac
            dev=$(readlink -f "$link")
            hits+=("$dev")
        done
    fi
    [ ${#hits[@]} -eq 1 ] || return 1
    printf '%s\n' "${hits[0]}"
}

# find_t7: print the partition device of the NTFS volume labelled $T7_LABEL
find_t7() {
    local dev
    dev=$(blkid -t LABEL="$T7_LABEL" -t TYPE=ntfs -o device 2>/dev/null | head -n1)
    [ -n "$dev" ] || return 1
    printf '%s\n' "$dev"
}

# --- state ------------------------------------------------------------------------
state_dir() { mkdir -p "$T3W_STATE" 2>/dev/null || true; }

# write_json FILE < json: atomic write
write_json() {
    local file=$1 tmp
    tmp=$(mktemp "${file}.XXXXXX")
    cat >"$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$file"
}

# --- open items (shown in motd, status.json and the summary) ------------------------
# pending_set KEY "Text": record a step that needs a person
pending_set() {
    local key=$1; shift
    if dry; then plan "offen: $*"; return 0; fi
    mkdir -p "$T3W_STATE/pending"
    printf '%s\n' "$*" >"$T3W_STATE/pending/$key"
    warn "Offen: $*"
}
pending_clear() { dry || rm -f "$T3W_STATE/pending/$1"; }

# systemctl for the service user's systemd instance
user_systemctl() { systemctl --user -M "$T3W_USER@" "$@"; }
