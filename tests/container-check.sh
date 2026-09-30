#!/usr/bin/env bash
# Local checks in a short-lived Debian 13 amd64 container (run on the Mac or any
# Docker host). Nothing here touches real disks; systemd does not run in the
# container, so services, timers, mounts and logins are NOT exercised.
#
#   tests/container-check.sh            all checks
#   tests/container-check.sh --quick    preseed + setup --check only (no package installs)
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

docker run --rm --platform linux/amd64 --cap-add NET_ADMIN \
    -e QUICK="$QUICK" -v "$REPO:/src:ro" debian:trixie bash -euo pipefail -c '
cp -a /src /opt/t3-worker
cd /opt/t3-worker
result() { printf "%-48s %s\n" "$1" "$2"; }

# 1. Preseed syntax (repo file and a rendered variant with Wi-Fi block)
debconf-set-selections -c installer/preseed.cfg && result "preseed.cfg (Repo) debconf-set-selections -c" OK
sed -e "s|@@PASSWORD_HASH@@|\$6\$salt\$hash|" \
    -e "s|^#@@WIFI@@|d-i netcfg/wireless_essid string Test Net\nd-i netcfg/wireless_wpa string pass phrase 123|" \
    installer/preseed.cfg >/tmp/rendered.cfg
debconf-set-selections -c /tmp/rendered.cfg && result "preseed.cfg (gerendert, WLAN) -c" OK

# 2. Installer helpers parse with a POSIX shell
for f in installer/select-disk.sh installer/late.sh lib/firstboot.sh lib/motd.sh; do
    [ -f "$f" ] || continue
    dash -n "$f" && result "dash -n $f" OK
done

# 3. setup.sh --check (dry run: detection + planned actions), with the service user present
useradd -m -s /bin/bash leander
./setup.sh --check >/tmp/check.log 2>&1 && result "setup.sh --check" "OK (Exit 0)" || { cat /tmp/check.log; result "setup.sh --check" FEHLER; exit 1; }
grep -c "\[Plan\]" /tmp/check.log | xargs -I{} printf "%-48s %s\n" "  geplante Aktionen" "{}"
cp /tmp/check.log /tmp/check-output.log

[ "$QUICK" = 1 ] && exit 0

# 4. Config files against real Debian packages
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update >/dev/null
apt-get -qq install -y --no-install-recommends samba nftables unattended-upgrades systemd jq util-linux mount >/dev/null

T3W_ROOT=/opt/t3-worker
sed -e "s|@@USER@@|leander|g" -e "s|@@T7_PATH@@|/srv/t7|g" -e "s|@@TM_PATH@@|/srv/timemachine|g" \
    -e "s|@@TM_QUOTA@@|540G|g" -e "s|@@LIB@@|$T3W_ROOT/lib|g" samba/smb.conf.tmpl >/tmp/smb.conf
mkdir -p /srv/t7 /srv/timemachine
testparm -s /tmp/smb.conf >/tmp/testparm.log 2>&1 && result "testparm smb.conf" OK || { cat /tmp/testparm.log; result "testparm" FEHLER; }
grep -iE "unknown|error|ignoring" /tmp/testparm.log || true
for m in fruit streams_xattr catia; do
    ls /usr/lib/x86_64-linux-gnu/samba/vfs/$m.so >/dev/null 2>&1 && result "Samba VFS-Modul $m" vorhanden || result "Samba VFS-Modul $m" FEHLT
done

cp config/unattended-upgrades-t3-worker.conf /etc/apt/apt.conf.d/52t3-worker-unattended-upgrades
apt-config dump | grep -A3 "^Unattended-Upgrade::Origins-Pattern " | sed "s/^/  /"
n=$(apt-config dump | grep -c "^Unattended-Upgrade::Origins-Pattern:: ")
[ "$n" = 2 ] && result "unattended-upgrades: nur 2 Security-Quellen" OK || result "unattended-upgrades Quellen" "FEHLER ($n)"

nft -c -f config/firewall.nft && result "nft -c firewall.nft" OK

# 5. Timer scripts in dry-run mode, motd rendering of the resulting status
mkdir -p /var/lib/t3-worker/pending
echo "Beispiel: offener Schritt" >/var/lib/t3-worker/pending/test
DRY_RUN=1 lib/health.sh >/tmp/health.out 2>&1; rc=$?
[ "$rc" = 0 ] && result "health.sh (Prüfmodus)" "OK (Exit 0)" || { cat /tmp/health.out; result "health.sh" "FEHLER ($rc)"; }
sed -n "/^{/,/^}/p" /tmp/health.out >/var/lib/t3-worker/status.json
jq -e ".services and .disks and .pending" /var/lib/t3-worker/status.json >/dev/null && result "status.json Schema" OK
sh lib/motd.sh >/tmp/motd.out 2>&1 && result "motd.sh" OK && sed "s/^/  | /" /tmp/motd.out
DRY_RUN=1 lib/t7-mirror.sh >/tmp/mirror.out 2>&1; grep -q "T7 nicht eingebunden" /tmp/mirror.out && result "t7-mirror.sh bricht ohne T7 ab" OK || { cat /tmp/mirror.out; result "t7-mirror.sh" FEHLER; }
DRY_RUN=1 lib/tool-update.sh >/tmp/tu.out 2>&1 && result "tool-update.sh (Prüfmodus)" OK || { tail -5 /tmp/tu.out; result "tool-update.sh" FEHLER; }
lib/require-mount.sh /srv/t7 >/dev/null 2>&1 && result "require-mount.sh ohne Mount" "FEHLER (Exit 0)" || result "require-mount.sh lehnt ungemountet ab" OK

for u in systemd/*.service systemd/*.timer systemd/user/*.service; do
    systemd-analyze verify --man=no "$u" >/tmp/verify.log 2>&1 || true
    if grep -vE "Failed to|not found|No such file|ExecStart=.*(opt/t3-worker|usr/local/sbin|cswap)|is not executable|Unit .*user" /tmp/verify.log | grep -q .; then
        cat /tmp/verify.log; result "systemd-analyze $u" WARNUNG
    else
        result "systemd-analyze $u" OK
    fi
done
'
