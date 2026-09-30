#!/usr/bin/env bash
# Nightly one-way mirror of the Samsung T7 to the internal HDD (timer 02:30).
#
#   $T7_PATH/  --rsync-->  $MIRROR_PATH/current/
#   files deleted or overwritten on the T7 -> $MIRROR_PATH/deleted/<YYYY-MM-DD>/ (kept 30 days)
#
# The T7 is the SOURCE and is only ever read. Safety gates (no rsync if any fails):
#   - both paths are mountpoints on different filesystems
#   - the source is not empty
#   - the source file count is at least 50 % of the last successful run
#   - the source uses at most 95 % of the mirror filesystem size
# Result: $T3W_STATE/t7-mirror.json {finished, ok, reason, files, bytes, duration_s}
#
#   sudo /opt/t3-worker/lib/t7-mirror.sh             run
#   sudo DRY_RUN=1 /opt/t3-worker/lib/t7-mirror.sh   run all checks, skip rsync and pruning
set -uo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"

LOCK_FILE=${T7_MIRROR_LOCK:-/run/lock/t3-worker-t7-mirror.lock}
KEEP_DAYS=30
MIN_FILE_RATIO=50     # percent of the last successful file count
MAX_FILL=95           # percent of the mirror filesystem size
MAX_DELETE=5000
# shellcheck disable=SC2016  # literal Windows folder name
EXCLUDES=('$RECYCLE.BIN' 'System Volume Information' '.Trashes' '.Spotlight-V100' '.fseventsd')

STARTED=$(date +%s)
FILES=0
BYTES=0
LAST_COUNT_FILE="$T3W_STATE/t7-mirror.last-files"

json_str() {
    local s=${1//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

# finish OK REASON: write the result file and exit
finish() {
    local okv=$1 reason=$2
    if [ "$okv" = true ]; then ok "$reason"; else fail "$reason"; fi
    if dry; then
        plan "Ergebnis nach $T3W_STATE/t7-mirror.json schreiben (ok=$okv)"
        exit 0
    fi
    state_dir
    write_json "$T3W_STATE/t7-mirror.json" <<EOF
{"finished":"$(date -Iseconds)","ok":$okv,"reason":$(json_str "$reason"),"files":$FILES,"bytes":$BYTES,"duration_s":$(($(date +%s) - STARTED))}
EOF
    [ "$okv" = true ] && exit 0
    exit 1
}

# count_files DIR: regular files below DIR, excluded folders not counted
count_files() {
    local prune=() e
    for e in "${EXCLUDES[@]}"; do prune+=(-name "$e" -o); done
    unset 'prune[${#prune[@]}-1]'
    find "$1" -xdev \( "${prune[@]}" \) -prune -o -type f -printf '.' 2>/dev/null | wc -c
}

# assert_not_source PATH: abort if PATH is the T7 or lies on/inside it. Every
# path the script writes to or deletes from passes through here.
assert_not_source() {
    local target src
    src=$(readlink -f "$T7_PATH")
    target=$(readlink -m "$1")
    case "$target/" in
        "$src"/*) finish false "Abbruch: Schreibziel $1 liegt auf der T7 (Quelle wird nie beschrieben)" ;;
    esac
    case "$src/" in
        "$target"/*) finish false "Abbruch: Schreibziel $1 enthält die T7" ;;
    esac
    if [ -e "$target" ] && [ "$(stat -c %d "$target")" = "$(stat -c %d "$src")" ]; then
        finish false "Abbruch: Schreibziel $1 liegt auf demselben Dateisystem wie die T7"
    fi
}

prune_deleted() {
    local base="$MIRROR_PATH/deleted" cutoff d name
    [ -d "$base" ] || return 0
    assert_not_source "$base"
    cutoff=$(date -d "$KEEP_DAYS days ago" +%F)
    for d in "$base"/*/; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
        if [[ "$name" < "$cutoff" ]]; then
            if dry; then plan "entfernen: $base/$name"; else rm -rf -- "${base:?}/$name" && ok "entfernt: deleted/$name"; fi
        fi
    done
}

main() {
    local src dst backup last used size rc=0 stats e args=()

    if ! dry && [ "$(id -u)" -ne 0 ]; then die "t7-mirror.sh muss als root laufen"; fi

    # never run twice at the same time
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        warn "T7-Spiegelung läuft bereits, dieser Lauf wird übersprungen"
        exit 0
    fi

    phase "T7-Spiegelung $(date '+%F %H:%M')"
    src="${T7_PATH%/}"
    dst="${MIRROR_PATH%/}/current"
    backup="${MIRROR_PATH%/}/deleted/$(date +%F)"

    mountpoint -q "$src" || finish false "T7 nicht eingebunden ($src)"
    mountpoint -q "$MIRROR_PATH" || finish false "Spiegel-Partition nicht eingebunden ($MIRROR_PATH)"
    assert_not_source "$MIRROR_PATH"
    assert_not_source "$dst"
    assert_not_source "$backup"

    say "Zähle Dateien auf der T7"
    FILES=$(count_files "$src")
    [ "$FILES" -gt 0 ] || finish false "Abbruch: T7 ist leer (keine Dateien in $src)"

    # baseline: last successful run, else what the mirror currently holds
    last=''
    if [ -r "$LAST_COUNT_FILE" ]; then last=$(tr -dc '0-9' <"$LAST_COUNT_FILE"); fi
    if [ -z "$last" ] && [ -d "$dst" ]; then last=$(count_files "$dst"); fi
    if [ -n "$last" ] && [ "$last" -gt 0 ] && [ $((FILES * 100)) -lt $((last * MIN_FILE_RATIO)) ]; then
        finish false "Abbruch: T7 hat nur $FILES Dateien, zuletzt $last (unter $MIN_FILE_RATIO %)"
    fi
    ok "T7: $FILES Dateien (zuletzt ${last:-unbekannt})"

    used=$(df -B1 --output=used "$src" | tail -n1 | tr -dc '0-9')
    size=$(df -B1 --output=size "$MIRROR_PATH" | tail -n1 | tr -dc '0-9')
    if [ $((used * 100)) -gt $((size * MAX_FILL)) ]; then
        finish false "Abbruch: T7 belegt $used Bytes, mehr als $MAX_FILL % des Spiegels ($size Bytes)"
    fi
    BYTES=$used

    for e in "${EXCLUDES[@]}"; do args+=(--exclude="/$e"); done
    args+=(-a -x --delete --delete-after --max-delete="$MAX_DELETE"
        --backup --backup-dir="$backup" --stats --no-human-readable)

    # final guard right before rsync: the destination argument is never the T7
    [ "$dst" != "$src" ] || finish false "Abbruch: Ziel gleich Quelle"
    assert_not_source "$dst"

    if dry; then
        plan "rsync ${args[*]} $src/ $dst/"
        prune_deleted
        finish true "Prüfungen bestanden (Probelauf, nichts kopiert)"
    fi

    state_dir
    mkdir -p "$dst"
    stats=$(mktemp)
    say "Spiegele $src/ -> $dst/"
    LC_ALL=C nice -n 15 ionice -c3 rsync "${args[@]}" "$src/" "$dst/" >"$stats" 2>&1 || rc=$?
    grep -E '^(Number of (regular )?files|Number of deleted files|Total file size|Total transferred file size)' "$stats" || true
    e=$(sed -nE 's/^Total file size: ([0-9,.]+).*/\1/p' "$stats" | tr -dc '0-9')
    [ -z "$e" ] || BYTES=$e
    if [ "$rc" != 0 ]; then
        tail -n 20 "$stats" >&2
    fi
    rm -f "$stats"

    prune_deleted

    case "$rc" in
        0)  printf '%s\n' "$FILES" >"$LAST_COUNT_FILE"
            finish true "Spiegel aktuell: $FILES Dateien" ;;
        24) printf '%s\n' "$FILES" >"$LAST_COUNT_FILE"
            finish true "Spiegel aktuell: $FILES Dateien (einige verschwanden während des Laufs)" ;;
        25) finish false "Abbruch: mehr als $MAX_DELETE Löschungen, Spiegel nur teilweise abgeglichen" ;;
        *)  finish false "rsync fehlgeschlagen (Code $rc)" ;;
    esac
}

main "$@"
