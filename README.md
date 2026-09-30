# t3-worker

Turns an old laptop into a headless, always-on agent server for
[T3 Code](https://github.com/pingdotgg/t3code). Coding agents (Claude Code and
friends) run on the laptop; the Mac keeps the T3 Code desktop app as the UI and
connects to the laptop as a remote environment over Tailscale. T3's load
balancing sends new threads to whichever machine has more free CPU and memory.

The laptop also serves the Mac's Time Machine backups and shares an external
Samsung T7 drive, mirrored nightly to the internal HDD.

Script output is German, code and docs are English.

## Hardware this is written for

| Part | Model | Role |
|---|---|---|
| Laptop | Acer Swift 3 SF314-54G, i5-8250U, 8 GB RAM | host `t3-worker` |
| SSD | SK hynix `HFS128G39TND-N210A` 128 GB SATA M.2 | Debian, repos (Btrfs + snapper) |
| HDD | Toshiba `MQ04ABF100` 1 TB | ~600 GB Time Machine, ~400 GB T7 mirror |
| External | Samsung T7 Shield 2 TB, NTFS, label `T7 Shield` | shared as `T7`, never formatted |
| GPU | NVIDIA MX150 | blacklisted, runtime power-down |

The disk models are matched exactly; other hardware needs the constants in
`lib/common.sh` (or `/etc/t3-worker/config`) adjusted.

## Flow

### 1. Build the install stick (Mac)

```sh
brew install xorriso openssl@3 gnupg     # gnupg optional, verifies Debian's signature
./make-stick.sh --wifi                   # omit --wifi when using a USB Ethernet adapter
```

The script downloads the current Debian 13 amd64 netinst ISO into
`~/.cache/t3-worker` (SHA256 checked, `SHA256SUMS` signature checked with the
pinned Debian CD keys when gpg is available), asks for the `leander` password
(stored only as a SHA-512 hash) and optionally the Wi-Fi credentials, embeds
`installer/preseed.cfg`, the install helpers, this repository and
`~/.ssh/id_ed25519.pub` (offers to create the key if missing), and adds a default
boot entry `auto=true priority=critical preseed/file=/cdrom/preseed.cfg` for UEFI
(GRUB) and BIOS (isolinux). It then writes the stick with `dd`.

The Swift 3 has no Ethernet port. A USB Ethernet adapter (e.g. Realtek RTL8153)
can be plugged in at any time, before or after the install, with or without
`--wifi`: it gets DHCP automatically and is preferred over Wi-Fi (route metric
100 vs. 600); Wi-Fi stays as the fallback. Booting never waits for a cable.

The stick writer refuses internal disks, disks over 64 GB and anything with
"T7" in its name, and you have to type the disk identifier to confirm. The built
ISO contains the password hash (and the Wi-Fi password), so it is deleted after
writing unless `--keep-iso` is given. `--iso-only` only builds the ISO;
`--check-disk diskN` only runs the stick safety check.

### 2. BIOS (once, by hand)

- SATA mode **AHCI** (not RST/Optane), otherwise Linux cannot see the SSD.
- Secure Boot may stay on (Debian's shim is signed). If the Acer firmware
  refuses to boot the installed system, add `\EFI\debian\shimx64.efi` as a
  trusted file or turn Secure Boot off.
- Boot order: USB first for the install.
- Power-on after AC loss is a BIOS setting, not something Linux can do. The
  Swift 3's InsydeH2O BIOS usually has no such option; the battery bridges
  short outages instead. If the BIOS offers a battery charge limit, enable it,
  the laptop will sit on AC permanently.

### 3. Install (unattended, about 15-30 min)

Boot the stick. After 10 s the "t3-worker" entry starts automatically.
Before partitioning, `installer/select-disk.sh`:

- selects the SSD by model `HFS128G39TND` and hands only that disk to partman
  and GRUB,
- **aborts and powers off** if the SSD is not found exactly once, if any disk
  over 1.5 TB is attached, or if any USB disk other than the stick is attached
  (so unplug the T7),
- asks (default "no") before overwriting an existing t3-worker install.

The SSD gets GPT with an EFI partition and a Btrfs root (label `t3root`), no swap
partition (zram is used). The HDD is not touched by the installer. Locale
de_DE.UTF-8, keyboard de, timezone Europe/Berlin, user `leander` with sudo,
root login disabled, SSH key-only. The machine **powers off** when done: remove
the stick, then power on.

### 4. First boot (automatic)

`t3-worker-firstboot.service` runs once after the network is up: it clones the
current repository from GitHub (retrying for about 5 minutes; the copy on the
stick is the fallback) to `/opt/t3-worker` and runs `setup.sh --unattended`.
That installs and configures everything that needs no decision. Steps that need
a person are recorded as open items and shown at SSH login (motd), in Cockpit and
in `status.json`.

### 5. Finish over SSH

```sh
ssh leander@t3-worker.local
sudo t3-worker-setup
```

`t3-worker-setup` first updates `/opt/t3-worker` from GitHub (`git pull
--ff-only`, or replaces the stick copy with a clone) and restarts itself, then
runs all phases again. Already-done steps are skipped. Interactive steps:

| Step | What happens |
|---|---|
| HDD | shows the disk, formats only after you type `FORMAT sdX` (GPT: `t3w-timemachine` 560 GiB ≈ 600 GB, `t3w-t7mirror` the rest ≈ 371 GiB ≈ 400 GB, ext4) |
| Samba | `smbpasswd -a leander` |
| Tailscale | `tailscale up --ssh --hostname t3-worker --operator leander`, prints the login URL |
| T3 Code | `t3 service install` (systemd user unit, linger enabled), then `t3 pair --tailscale` prints a pairing link (terminal only, never logged) |
| Claude | per account: `claude auth login`, then `cswap add`; afterwards `cswap auto` runs as a user service |
| GitHub + agent-home | `gh auth login`, clone the private agent-home repo, run its `install.sh`, enable its sync timer |

Setup can also be started without the stick on any fresh Debian 13:
`curl -fsSL https://raw.githubusercontent.com/leanderendres/t3-worker/main/setup.sh | bash`.

Other modes: `sudo t3-worker-setup --check` (detect and print planned actions,
change nothing), `--unattended`, `--phase NAME` (see `--list`). Log:
`/var/log/t3-worker-setup.log`.

### 6. On the Mac

- T3 Code: Settings → Connections → Add environment → paste the pairing link
  (`mac/pair.sh` fetches a fresh one over SSH). Tailnet HTTPS certificates must be
  enabled in the Tailscale admin console for `t3 pair --tailscale`.
- Settings → Connections → Load balancing: set t3-worker to **Prefer** and the Mac
  to **Less often** (T3 uses preferences, not numeric weights).
- Optionally switch off the Mac's local environment so no agents run there.
- Time Machine: add `smb://t3-worker.local/TimeMachine` as backup disk (also
  advertised via Bonjour).
- `mac/status.sh` shows the laptop's `status.json`; Cockpit is at
  `https://t3-worker.local:9090` (page "t3-worker").
- `mac/push-accounts.sh` copies claude-swap accounts from the Mac. Fallback only:
  the same OAuth refresh token on two machines can log one side out when it
  rotates, so fresh logins on the server (step 5) are preferred.

## What runs on the laptop

| Area | Details |
|---|---|
| System | Debian 13 minimal, network: Wi-Fi (or the install-time port) via ifupdown with metric 600 (wired 100), every other wired port incl. hotplugged USB Ethernet via systemd-networkd (DHCP, IPv6 RA, metric 100, not required for boot, `systemd-networkd-wait-online` masked, foreign routes of Tailscale/Docker left alone), Btrfs root with snapper snapshots before/after every apt run (Debian's `/etc/apt/apt.conf.d/80snapper`; grub-btrfs is not in Debian 13, so no boot menu for snapshots), nested subvolumes for `/var/lib/docker`, `~/Sites`, `~/.cache` (kept out of snapshots), zram swap (zstd, 50 %), unattended-upgrades (security only, reboot only at 04:00), systemd hardware watchdog, lid switch ignored, suspend/hibernate masked, NVIDIA blacklisted, console blanks after 60 s |
| Access | OpenSSH key-only, Tailscale with Tailscale SSH, avahi (`t3-worker.local`), Cockpit (socket-activated); reachable over Wi-Fi and any wired/USB Ethernet link, the cable being preferred when plugged in |
| Firewall | own nftables table: Samba (139/445) and Cockpit (9090) only from loopback, `tailscale0` and private ranges; nothing else is filtered |
| Tools | Docker (official repo), git, gh, build-essential, mise with Node LTS and pnpm, uv, claude-swap, Claude Code (native installer), T3 Code CLI (`t3.codes/install.sh`), Chromium + Playwright system deps |
| Storage | T7 via kernel `ntfs3` by UUID (`nofail`, no automount), HDD partitions by UUID; a T7 plugged in later is mounted by the health timer within 5 minutes; empty mount points are immutable, and Samba refuses a share whose disk is not mounted, so nothing lands on the SSD by mistake. A dirty NTFS volume is never repaired automatically (open item with instructions instead) |
| Shares | `T7` (read/write) and `TimeMachine` (vfs_fruit, quota 540 GB) for user leander |

### Timers

| Timer | When | Does |
|---|---|---|
| `t3-worker-health` | every 5 min | checks Tailscale, T3 service, Docker, Samba, Cockpit, T7 mount, disk space, memory, temperature; restarts what is down (max. 3 times per hour per service), mounts the T7; writes `/var/lib/t3-worker/status.json` (the unit always succeeds, problems are in the JSON) |
| `t3-worker-tool-update` | daily 04:30 | apt upgrade (snapshotted), `claude update`, mise/Node/pnpm, uv tools, npm globals, `t3 update --yes` |
| `t3-worker-t7-mirror` | daily 02:30 | rsync T7 → HDD mirror, result in `/var/lib/t3-worker/t7-mirror.json` |
| agent-home sync | hourly | user timer shipped by the agent-home repo |

### T7 mirror: deletion policy

The mirror propagates deletions (`--delete`) so it stays a true mirror, with
guards: nothing runs unless both sides are mounted and the source is non-empty;
the run is skipped if the source has less than half the files of the last good
run (a half-empty or damaged T7 is never mirrored); it stops when the data on the
T7 exceeds 95 % of the mirror partition (≈ 371 GiB, so the T7 can grow from 290 GB
to roughly 380 GB before the mirror needs more space); `--max-delete=5000` caps
deletions per run. The T7 is only ever read. Deleted or overwritten files are not lost: they move to
`/srv/t7-mirror/deleted/<date>/` and are kept for 30 days.

## Repository layout

```
make-stick.sh              Mac: build the ISO and write the stick
installer/preseed.cfg      Debian installer answers (placeholders filled by make-stick.sh)
installer/select-disk.sh   partman/early_command: pick the SSD, abort on unexpected disks
installer/late.sh          copy repo + SSH key into the target, enable first boot
setup.sh                   phased, idempotent setup (run as root)
lib/common.sh              shared helpers (output, dry-run, files, apt, user, disks, open items)
lib/phases-*.sh            setup phases
lib/firstboot.sh           first boot: fetch repo, run unattended setup
lib/health.sh, tool-update.sh, t7-mirror.sh, motd.sh, require-mount.sh
systemd/                   units and timers (systemd/user: user units)
config/                    system config snippets installed by setup.sh
samba/smb.conf.tmpl        Samba configuration template
cockpit/t3-worker/         Cockpit status page
mac/                       Mac helpers: pair.sh, status.sh, push-accounts.sh
tests/container-check.sh   local checks in a Debian 13 container
```

## Testing

`tests/container-check.sh` runs in a throwaway `debian:trixie` amd64 container:
preseed syntax (`debconf-set-selections -c`), POSIX syntax of the installer
helpers, `setup.sh --check`, `testparm` on the rendered Samba config,
the unattended-upgrades origin override, `nft -c` on the firewall and
`systemd-analyze verify` on the units. All scripts pass `shellcheck -x`.

Only the real hardware can show: disk detection in the installer, Wi-Fi
firmware, UEFI/Secure Boot on the Acer, the watchdog device, NVIDIA power-down,
ntfs3 with the actual T7, Time Machine over SMB, Tailscale/T3 pairing and the
systemd services and timers.

## License

MIT
