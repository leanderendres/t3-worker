#!/bin/sh
# t3-worker login message, installed as /etc/update-motd.d/60-t3-worker.
# POSIX sh, runs as root on every SSH login via pam_motd. Reads the status that
# health.sh writes every 5 minutes; must stay fast and must never fail.

STATE=${T3W_STATE:-/var/lib/t3-worker}
STATUS=$STATE/status.json

echo
if [ -r "$STATUS" ] && command -v jq >/dev/null 2>&1; then
    jq -r '
        def mark(s): if s == "active" then "✓" elif s == "missing" then "–" else "✗" end;
        def name(m): {"/": "System", "/srv/timemachine": "Time Machine",
                      "/srv/t7-mirror": "T7-Spiegel", "/srv/t7": "T7"}[m] // m;
        (now - (.generated | fromdateiso8601? // 0)) as $age |
        "t3-worker: " + (if .ok then "alles in Ordnung" else "Probleme erkannt" end)
          + " (Stand " + ((.generated | fromdateiso8601? // 0) | localtime | strftime("%d.%m. %H:%M")) + ")"
          + (if $age > 900 then ", Status veraltet" else "" end),
        "  Dienste:  Tailscale "
          + (if .services.tailscale == "active" and .services.tailscale_state and .services.tailscale_state != "Running"
             then "✗ (" + (if .services.tailscale_state == "NeedsLogin" then "nicht angemeldet"
                           else .services.tailscale_state end) + ")"
             else mark(.services.tailscale) end)
          + "  T3 Code " + mark(.services.t3) + "  Docker " + mark(.services.docker)
          + "  Samba " + mark(.services.smbd) + "  Cockpit " + mark(.services.cockpit),
        "  System:   Last " + (.load[0] | tostring)
          + ", RAM frei " + (.mem.avail_mb | tostring) + " von " + (.mem.total_mb | tostring) + " MB"
          + (if .temperature_c then ", " + (.temperature_c | tostring) + " °C" else "" end),
        "  Speicher: " + ([.disks[] | select(.mounted) | name(.mount) + " " + (.used_pct | tostring) + " %"] | join(", ")),
        "  T7:       " + (if .t7.mounted then "eingebunden"
                          elif .t7.present then "angeschlossen, nicht eingebunden"
                          else "nicht angeschlossen" end)
          + ({"ntfs": " (NTFS)", "exfat": " (exFAT)"}[.t7.fstype // ""] // "")
          + (if (.mirror | type) == "object" and (.mirror.ok == false or .mirror.success == false)
             then ", letzte Spiegelung fehlgeschlagen" + (if .mirror.reason then " (" + .mirror.reason + ")" else "" end)
             else "" end),
        (if (.tool_update | type) == "object" and .tool_update.ok == false
         then "  Updates:  letztes Werkzeug-Update mit Fehlern ("
              + ([.tool_update.steps[]? | select(.ok == false) | .name] | join(", ")) + ")"
         else empty end),
        (.problems // [] | .[] | "  ! " + .),
        (.repairs // [] | .[] | "  Reparatur: " + .)
    ' "$STATUS" 2>/dev/null || echo "t3-worker: Status nicht lesbar ($STATUS)"
else
    echo "t3-worker: noch kein Status (Gesundheitsprüfung läuft alle 5 Minuten)"
fi

# Open items: read the files directly, they are fresher than status.json
found=0
for f in "$STATE"/pending/*; do
    [ -f "$f" ] || continue
    if [ "$found" = 0 ]; then
        echo
        echo "Offene Schritte:"
        found=1
    fi
    printf '  - %s\n' "$(cat "$f")"
done
if [ "$found" = 1 ]; then
    echo
    echo "Weiter mit: sudo t3-worker-setup"
fi
echo
exit 0
