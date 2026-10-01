#!/usr/bin/env bash
# t3-worker health check and self-healing. Run every 5 minutes as root by
# t3-worker-health.timer. Writes $T3W_STATE/status.json for the login message
# (motd), the Cockpit status page and mac/status.sh.
#
#   DRY_RUN=1 health.sh   detect only: no restarts, no mounts, JSON on stdout
#
# Always exits 0 once status.json is written: problems are reported in the JSON
# (ok=false, problems[]), so the timer unit does not flap between failed/ok.
set -uo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"

RESTART_LIMIT=${RESTART_LIMIT:-3}       # restarts per service ...
RESTART_WINDOW=${RESTART_WINDOW:-3600}  # ... within this many seconds
DISK_WARN_PCT=${DISK_WARN_PCT:-90}

ST=''         # result of check_unit/check_t3
REPAIRS=()   # German texts: what was repaired (or could not be)
PROBLEMS=()  # German texts: what is still wrong after repairs
NOW=$(date +%s)

# Skip repairs while setup.sh runs (it holds this lock and restarts services itself).
SETUP_RUNNING=0
if [ -e /run/t3-worker-setup.lock ] && ! flock -n /run/t3-worker-setup.lock true 2>/dev/null; then
    SETUP_RUNNING=1
fi

command -v jq >/dev/null 2>&1 || die "jq fehlt (wird von der Setup-Phase base installiert)."

# --- rate limit ------------------------------------------------------------------------
# may_restart NAME: true if NAME was restarted fewer than RESTART_LIMIT times
# within RESTART_WINDOW seconds; records the attempt (not in dry-run mode).
may_restart() {
    local name=$1 file t recent=()
    file="$T3W_STATE/restarts/$name"
    if [ -f "$file" ]; then
        while IFS= read -r t; do
            case "$t" in ''|*[!0-9]*) continue ;; esac
            [ $((NOW - t)) -lt "$RESTART_WINDOW" ] && recent+=("$t")
        done <"$file"
    fi
    [ "${#recent[@]}" -lt "$RESTART_LIMIT" ] || return 1
    if ! dry; then
        mkdir -p "$T3W_STATE/restarts"
        printf '%s\n' "${recent[@]}" "$NOW" | sed '/^$/d' >"$file"
    fi
    return 0
}

# repair NAME WHAT DONE CMD...: rate-limited repair, e.g.
#   repair docker "Docker" "neu gestartet" systemctl restart docker.service
# Results go to REPAIRS and, outside dry-run mode, to $T3W_STATE/repairs.log.
repair() {
    local name=$1 what=$2 done=$3 msg rc=1; shift 3
    if [ "$SETUP_RUNNING" = 1 ]; then
        warn "$what: Reparatur übersprungen, Setup läuft gerade."
        return 1
    fi
    if ! may_restart "$name"; then
        msg="$what: Reparatur-Limit erreicht ($RESTART_LIMIT pro Stunde), bitte selbst prüfen"
        warn "$msg"
    elif dry; then
        plan "$*"
        REPAIRS+=("$what $done (Prüfmodus, nicht ausgeführt)")
        return 0
    elif "$@" >/dev/null 2>&1; then
        msg="$what $done"
        ok "$msg"
        rc=0
    else
        msg="$what konnte nicht $done werden"
        fail "$msg"
    fi
    REPAIRS+=("$msg")
    log_repair "$msg"
    return $rc
}

# log_repair TEXT: keep the last 50 repairs with timestamps (tab separated)
log_repair() {
    local log="$T3W_STATE/repairs.log"
    dry && return 0
    printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"$log"
    tail -n 50 "$log" >"$log.tmp" && mv -f "$log.tmp" "$log"
}

# recent_repairs_json: last 10 logged repairs, newest first, as [{time, text}]
recent_repairs_json() {
    local log="$T3W_STATE/repairs.log"
    [ -s "$log" ] || { echo '[]'; return; }
    tail -n 10 "$log" | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {time: .[0], text: (.[1:] | join("\t"))}) | reverse'
}

# state_de STATE: German wording for systemd states in problem texts
state_de() {
    case "$1" in
        inactive) echo "gestoppt" ;;
        failed) echo "fehlgeschlagen" ;;
        missing) echo "nicht installiert" ;;
        unknown) echo "Zustand unbekannt" ;;
        *) echo "$1" ;;
    esac
}

# --- services ----------------------------------------------------------------------------
unit_exists() { [ "$(systemctl show -p LoadState --value "$1" 2>/dev/null)" = loaded ]; }

# sys_state UNIT: active/inactive/failed/... or "missing"
sys_state() {
    unit_exists "$1" || { echo missing; return; }
    systemctl is-active "$1" 2>/dev/null || true
}

# check_unit KEY UNIT LABEL: restart a system unit that should run but does not.
# Result in ST (no command substitution: REPAIRS must survive).
check_unit() {
    local key=$1 unit=$2 label=$3
    ST=$(sys_state "$unit")
    case "$ST" in
        active|activating|reloading|missing) ;;
        *)
            if repair "$key" "$label" "neu gestartet" systemctl restart "$unit"; then
                dry || ST=$(sys_state "$unit")
            fi
            ;;
    esac
}

t3_state() {
    local st
    getent passwd "$T3W_USER" >/dev/null 2>&1 || { echo missing; return; }
    st=$(user_systemctl show -p LoadState --value t3code.service 2>/dev/null) || { echo unknown; return; }
    [ "$st" = loaded ] || { echo missing; return; }
    user_systemctl is-active t3code.service 2>/dev/null || true
}

check_t3() { # result in ST
    ST=$(t3_state)
    case "$ST" in
        active|activating|reloading|missing|unknown) ;;
        *)
            if repair t3code "T3-Code-Dienst" "neu gestartet" user_systemctl restart t3code.service; then
                dry || ST=$(t3_state)
            fi
            ;;
    esac
}

# --- disks ---------------------------------------------------------------------------------
in_fstab() { awk -v m="$1" '$1 !~ /^#/ && $2 == m { f = 1 } END { exit !f }' /etc/fstab 2>/dev/null; }

# disk_json MOUNT: {mount, mounted, size_gb, used_pct}
disk_json() {
    local m=$1 mounted=false size=null pct=null line
    if [ "$m" = / ] || mountpoint -q "$m" 2>/dev/null; then
        mounted=true
        line=$(df -P -B1 "$m" 2>/dev/null | awk 'NR == 2 { print $2, $5 }')
        if [ -n "$line" ]; then
            size=$(awk -v b="${line%% *}" 'BEGIN { printf "%.1f", b / 1e9 }')
            pct=${line##* }
            pct=${pct%\%}
            case "$pct" in ''|*[!0-9]*) pct=null ;; esac
        fi
    fi
    jq -cn --arg m "$m" --argjson mounted "$mounted" --argjson size "$size" --argjson pct "$pct" \
        '{mount: $m, mounted: $mounted, size_gb: $size, used_pct: $pct}'
}

# ensure_mounted PATH LABEL: mount a path from /etc/fstab if it is not mounted
ensure_mounted() {
    local p=$1 label=$2
    mountpoint -q "$p" 2>/dev/null && return 0
    in_fstab "$p" || return 1
    repair "mount-$(basename "$p")" "$label ($p)" "eingebunden" mount "$p" || return 1
    dry || mountpoint -q "$p" 2>/dev/null
}

# --- system figures ----------------------------------------------------------------------------
meminfo_mb() { awk -v k="$1:" '$1 == k { printf "%d", $2 / 1024; f = 1 } END { if (!f) print 0 }' /proc/meminfo; }

zram_json() {
    local d total=0 orig=0 compr=0 n=0 size stats
    for d in /sys/block/zram*; do
        [ -e "$d/disksize" ] || continue
        size=$(cat "$d/disksize" 2>/dev/null || echo 0)
        [ "${size:-0}" -gt 0 ] 2>/dev/null || continue
        n=$((n + 1))
        total=$((total + size))
        # mm_stat: orig_data_size compr_data_size mem_used_total ...
        stats=$(cat "$d/mm_stat" 2>/dev/null || echo "0 0 0")
        orig=$((orig + $(awk '{ print $1 + 0 }' <<<"$stats")))
        compr=$((compr + $(awk '{ print $3 + 0 }' <<<"$stats")))
    done
    jq -cn --argjson n "$n" --argjson t "$((total / 1048576))" --argjson o "$((orig / 1048576))" \
        --argjson c "$((compr / 1048576))" '{devices: $n, size_mb: $t, data_mb: $o, used_mb: $c}'
}

# temperature_c: highest CPU/board temperature in degrees C, or null
temperature_c() {
    local f v max=''
    for f in /sys/class/thermal/thermal_zone*/temp /sys/class/hwmon/hwmon*/temp*_input; do
        [ -r "$f" ] || continue
        v=$(cat "$f" 2>/dev/null) || continue
        case "$v" in ''|*[!0-9]*) continue ;; esac
        [ "$v" -gt 0 ] && [ "$v" -lt 150000 ] || continue
        if [ -z "$max" ] || [ "$v" -gt "$max" ]; then max=$v; fi
    done
    if [ -z "$max" ] && command -v sensors >/dev/null 2>&1; then
        max=$(sensors -j 2>/dev/null | jq '[.. | objects | to_entries[] | select(.key | test("^temp[0-9]+_input$")) | .value] | max // empty | . * 1000 | floor' 2>/dev/null)
    fi
    if [ -n "$max" ]; then awk -v t="$max" 'BEGIN { printf "%.1f", t / 1000 }'; else echo null; fi
}

# json_or_null FILE: file content if it is valid JSON, else null
json_or_null() {
    if [ -s "$1" ] && jq -e . "$1" >/dev/null 2>&1; then jq -c . "$1"; else echo null; fi
}

strings_json() { # strings_json STR...: JSON array of strings
    if [ $# -eq 0 ]; then echo '[]'; return; fi
    printf '%s\0' "$@" | jq -Rsc 'split("\u0000") | map(select(length > 0))'
}

# --- checks ---------------------------------------------------------------------------------------
main() {
    local ts_state ts_backend t3 docker smbd cockpit t7_present=false t7_mounted=false
    local pending=() f d disks=() ok=true pct t7_dev t7_fs='' t7_reason

    state_dir

    # Tailscale: daemon plus login state
    check_unit tailscaled tailscaled.service "Tailscale-Dienst"; ts_state=$ST
    ts_backend=null
    if command -v tailscale >/dev/null 2>&1 && [ "$ts_state" = active ]; then
        ts_backend=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null)
        ts_backend=${ts_backend:-unknown}
    fi
    [ "$ts_state" = active ] || PROBLEMS+=("Tailscale-Dienst: $(state_de "$ts_state")")
    case "$ts_backend" in
        Running|null) ;;
        NeedsLogin) PROBLEMS+=("Tailscale nicht angemeldet") ;;
        *) PROBLEMS+=("Tailscale: $ts_backend") ;;
    esac

    check_t3; t3=$ST
    [ "$t3" = active ] || PROBLEMS+=("T3-Code-Dienst: $(state_de "$t3")")
    check_unit docker docker.service "Docker"; docker=$ST
    [ "$docker" = active ] || PROBLEMS+=("Docker: $(state_de "$docker")")
    check_unit smbd smbd.service "Samba"; smbd=$ST
    [ "$smbd" = active ] || PROBLEMS+=("Samba: $(state_de "$smbd")")
    check_unit cockpit cockpit.socket "Cockpit-Socket"; cockpit=$ST
    [ "$cockpit" = active ] || PROBLEMS+=("Cockpit: $(state_de "$cockpit")")

    # T7: present but not mounted -> mount it from fstab, unless the volume was
    # not cleanly removed (never mounted or repaired automatically)
    if t7_dev=$(find_t7 2>/dev/null); then
        t7_present=true
        t7_fs=$(t7_fstype "$t7_dev" || true)
        if mountpoint -q "$T7_PATH" 2>/dev/null; then
            t7_mounted=true
        elif t7_reason=$(t7_mount_refusal "$t7_dev"); then
            PROBLEMS+=("T7 wird nicht eingebunden: $t7_reason. Anleitung: sudo t3-worker-setup --phase storage")
        elif ensure_mounted "$T7_PATH" "T7"; then
            dry || t7_mounted=true
        else
            PROBLEMS+=("T7 angeschlossen, aber nicht eingebunden ($T7_PATH)")
        fi
    fi
    # HDD volumes: remount if they dropped out (both are in fstab after the storage phase)
    for d in "$TM_PATH:Time Machine" "$MIRROR_PATH:T7-Spiegel"; do
        if in_fstab "${d%%:*}" && ! mountpoint -q "${d%%:*}" 2>/dev/null; then
            ensure_mounted "${d%%:*}" "${d#*:}" || PROBLEMS+=("${d#*:} nicht eingebunden (${d%%:*})")
        fi
    done

    for d in / "$TM_PATH" "$MIRROR_PATH" "$T7_PATH"; do
        disks+=("$(disk_json "$d")")
        pct=$(jq -r '.used_pct // 0' <<<"${disks[-1]}")
        [ "$pct" -ge "$DISK_WARN_PCT" ] && PROBLEMS+=("Speicher fast voll: $d ($pct %)")
    done

    for f in "$T3W_STATE"/pending/*; do
        [ -f "$f" ] && pending+=("$(cat "$f")")
    done

    [ ${#PROBLEMS[@]} -eq 0 ] || ok=false

    local json
    json=$(jq -n \
        --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg hostname "$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname)" \
        --argjson ok "$ok" \
        --argjson uptime "$(awk '{ printf "%d", $1 }' /proc/uptime)" \
        --argjson load "$(awk '{ printf "[%s,%s,%s]", $1, $2, $3 }' /proc/loadavg)" \
        --argjson mem_total "$(meminfo_mb MemTotal)" --argjson mem_avail "$(meminfo_mb MemAvailable)" \
        --argjson swap_total "$(meminfo_mb SwapTotal)" --argjson swap_free "$(meminfo_mb SwapFree)" \
        --argjson zram "$(zram_json)" \
        --argjson temp "$(temperature_c)" \
        --argjson disks "$(printf '%s\n' "${disks[@]}" | jq -sc .)" \
        --arg ts "$ts_state" --arg ts_backend "$ts_backend" --arg t3 "$t3" \
        --arg docker "$docker" --arg smbd "$smbd" --arg cockpit "$cockpit" \
        --argjson t7_present "$t7_present" --argjson t7_mounted "$t7_mounted" \
        --arg t7_fstype "$t7_fs" \
        --argjson mirror "$(json_or_null "$T3W_STATE/t7-mirror.json")" \
        --argjson tool_update "$(json_or_null "$T3W_STATE/tool-update.json")" \
        --argjson pending "$(strings_json "${pending[@]}")" \
        --argjson repairs "$(strings_json "${REPAIRS[@]}")" \
        --argjson recent_repairs "$(recent_repairs_json)" \
        --argjson problems "$(strings_json "${PROBLEMS[@]}")" \
        --argjson setup_running "$([ "$SETUP_RUNNING" = 1 ] && echo true || echo false)" \
        '{
            generated: $generated,
            hostname: $hostname,
            ok: $ok,
            uptime_s: $uptime,
            load: $load,
            mem: {total_mb: $mem_total, avail_mb: $mem_avail},
            swap: {total_mb: $swap_total, used_mb: ($swap_total - $swap_free)},
            zram: $zram,
            temperature_c: $temp,
            disks: $disks,
            services: {
                tailscale: $ts,
                tailscale_state: (if $ts_backend == "null" then null else $ts_backend end),
                t3: $t3, docker: $docker, smbd: $smbd, cockpit: $cockpit
            },
            t7: {present: $t7_present, mounted: $t7_mounted, fstype: (if $t7_fstype == "" then null else $t7_fstype end)},
            mirror: $mirror,
            tool_update: $tool_update,
            pending: $pending,
            repairs: $repairs,
            recent_repairs: $recent_repairs,
            problems: $problems,
            setup_running: $setup_running
        }') || die "status.json konnte nicht erzeugt werden."

    if dry; then
        plan "Datei schreiben: $T3W_STATE/status.json"
        printf '%s\n' "$json"
    else
        write_json "$T3W_STATE/status.json" <<<"$json"
    fi

    if [ "$ok" = true ]; then
        ok "Gesund: alle Dienste laufen."
        return 0
    fi
    for f in "${PROBLEMS[@]}"; do warn "$f"; done
    return 0
}

main "$@"
