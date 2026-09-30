# shellcheck shell=bash
# setup.sh phases: repos, tools, browser. Sourced by setup.sh.

# --- repos: official vendor apt repositories ----------------------------------------------
REPOS_CHANGED=0

# fetch_key URL DEST [--dearmor]: download a vendor signing key and install it if it
# differs from the current one. Sets REPOS_CHANGED=1 on change.
fetch_key() {
    local url=$1 dest=$2 mode=${3:-} tmp
    tmp=$(mktemp)
    if ! curl -fsSL --retry 3 -o "$tmp" "$url"; then
        rm -f "$tmp"
        if dry; then plan "Schlüssel laden: $url -> $dest"; return 0; fi
        die "Schlüssel nicht ladbar: $url"
    fi
    if [ "$mode" = --dearmor ]; then
        if ! command -v gpg >/dev/null 2>&1; then
            rm -f "$tmp"
            if dry; then plan "Schlüssel laden (gpg --dearmor): $url -> $dest"; return 0; fi
            die "gpg fehlt (Paket gnupg, Phase base)."
        fi
        gpg --dearmor --batch --yes -o "$tmp.gpg" "$tmp"
        mv -f "$tmp.gpg" "$tmp"
    fi
    install_file "$tmp" "$dest" 0644
    rm -f "$tmp"
    [ "$CHANGED" = 0 ] || REPOS_CHANGED=1
}

# write_source DEST <<< content: like write_file, but tracks REPOS_CHANGED
write_source() {
    write_file "$1" 0644
    [ "$CHANGED" = 0 ] || REPOS_CHANGED=1
}

phase_repos() {
    local arch
    arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
    REPOS_CHANGED=0
    [ -d /etc/apt/keyrings ] || run install -m 0755 -d /etc/apt/keyrings

    say "Docker (download.docker.com)"
    fetch_key https://download.docker.com/linux/debian/gpg /etc/apt/keyrings/docker.asc
    write_source /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    [ -e /etc/apt/sources.list.d/docker.list ] &&
        warn "Alte /etc/apt/sources.list.d/docker.list gefunden: bitte entfernen (doppelte Quelle mit anderem Signed-By)."

    say "Tailscale (pkgs.tailscale.com)"
    fetch_key https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg /usr/share/keyrings/tailscale-archive-keyring.gpg
    write_source /etc/apt/sources.list.d/tailscale.list <<'EOF'
# Tailscale packages for debian trixie
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian trixie main
EOF

    say "GitHub CLI (cli.github.com)"
    fetch_key https://cli.github.com/packages/githubcli-archive-keyring.gpg /etc/apt/keyrings/githubcli-archive-keyring.gpg
    write_source /etc/apt/sources.list.d/github-cli.list <<EOF
deb [arch=$arch signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main
EOF

    say "mise (mise.jdx.dev)"
    fetch_key https://mise.jdx.dev/gpg-key.pub /etc/apt/keyrings/mise-archive-keyring.gpg --dearmor
    write_source /etc/apt/sources.list.d/mise.list <<EOF
deb [signed-by=/etc/apt/keyrings/mise-archive-keyring.gpg arch=$arch] https://mise.jdx.dev/deb stable main
EOF

    if [ "$REPOS_CHANGED" = 1 ]; then
        apt_update --force
    else
        ok "Paketquellen unverändert"
        apt_update
    fi
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
        tailscale gh mise

    say "Docker einrichten"
    install_file "$T3W_ROOT/config/docker-daemon.json" /etc/docker/daemon.json 0644
    if [ "$CHANGED" = 1 ] && systemctl is-active -q docker 2>/dev/null; then
        svc restart docker
    fi
    if id -nG "$T3W_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        ok "$T3W_USER ist in der Gruppe docker"
    elif dry || { id "$T3W_USER" >/dev/null 2>&1 && getent group docker >/dev/null; }; then
        run usermod -aG docker "$T3W_USER"
    else
        warn "Gruppe docker oder Benutzer $T3W_USER fehlt: Docker-Gruppe übersprungen."
    fi
    svc enable --now docker.service tailscaled.service
}

# --- tools: user-level toolchain (as the service user) ----------------------------------------
# Every user command gets ~/.local/bin and the mise shims on PATH, independent of
# whether ~/.profile was already sourced.
# shellcheck disable=SC2016 # expanded in the user's shell
T3W_USER_PATH='export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH" MISE_YES=1;'

# user_tool NAME CHECK INSTALL: run INSTALL as the user unless CHECK succeeds
user_tool() {
    local name=$1 check=$2 install=$3
    if as_user_check "$T3W_USER_PATH $check"; then
        ok "$name vorhanden"
        return 0
    fi
    say "Installiere $name"
    as_user "$T3W_USER_PATH $install" ||
        warn "$name konnte nicht installiert werden. Erneut: sudo t3-worker-setup --phase tools"
}

phase_tools() {
    local home
    home=$(user_home 2>/dev/null || true)
    [ -n "$home" ] || home=/home/$T3W_USER
    if [ ! -d "$home" ] && ! dry; then
        die "Home-Verzeichnis von $T3W_USER fehlt: $home"
    fi

    # the T3 Code binary links against libatomic.so.1 (missing on minimal installs)
    apt_install libatomic1

    say "Shell-Umgebung von $T3W_USER"
    ensure_block "$home/.profile" "t3-worker PATH" <<'EOF'
case ":$PATH:" in *":$HOME/.local/share/mise/shims:"*) ;; *) PATH="$HOME/.local/share/mise/shims:$PATH" ;; esac
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
export PATH
EOF
    [ "$CHANGED" = 1 ] && run chown "$T3W_USER:$T3W_USER" "$home/.profile"
    ensure_block "$home/.bashrc" "t3-worker mise" <<'EOF'
if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate bash)"
fi
EOF
    [ "$CHANGED" = 1 ] && run chown "$T3W_USER:$T3W_USER" "$home/.bashrc"

    if ! command -v mise >/dev/null 2>&1 && ! dry; then
        warn "mise fehlt (Phase repos): Node und pnpm werden übersprungen."
    else
        user_tool "Node LTS und pnpm (mise)" \
            'mise which node && mise which pnpm' \
            'mise use -g node@lts pnpm@latest'
    fi
    user_tool uv 'command -v uv' \
        'curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh'
    user_tool claude-swap 'command -v cswap' \
        'uv tool install claude-swap'
    user_tool "Claude Code" 'command -v claude' \
        'curl -fsSL https://claude.ai/install.sh | bash'
    # shellcheck disable=SC2016 # expanded in the user's shell
    user_tool "T3 Code" 'test -x "$HOME/.local/bin/t3"' \
        'curl -fsSL https://t3.codes/install.sh | sh'

    dry && return 0
    say "Versionen"
    # shellcheck disable=SC2016 # expanded in the user's shell
    as_user "$T3W_USER_PATH"'
        for c in mise node pnpm uv claude-swap claude t3; do
            if command -v "$c" >/dev/null 2>&1; then
                printf "  %-12s %s\n" "$c" "$("$c" --version 2>/dev/null | head -n1)"
            else
                printf "  %-12s fehlt\n" "$c"
            fi
        done' || true
}

# --- browser: Chromium and the Playwright system dependencies ---------------------------------
phase_browser() {
    apt_install chromium fonts-liberation fonts-noto-color-emoji

    local marker=$T3W_STATE/playwright-deps.done node_bin=''
    if [ -f "$marker" ]; then
        ok "Playwright-Abhängigkeiten installiert ($(cat "$marker" 2>/dev/null))"
        return 0
    fi
    # read-only lookup, also in --check
    # shellcheck disable=SC2016 # expanded in the user's shell
    node_bin=$(DRY_RUN=0 as_user "$T3W_USER_PATH"' mise which node' 2>/dev/null | tail -n1) || node_bin=''
    if [ -z "$node_bin" ] || [ ! -x "$node_bin" ]; then
        if dry; then
            plan "npx -y playwright@latest install-deps chromium (mit Node aus mise von $T3W_USER)"
        else
            warn "Node von $T3W_USER nicht gefunden (Phase tools): Playwright-Abhängigkeiten übersprungen."
        fi
        return 0
    fi
    say "Playwright-Abhängigkeiten für Chromium"
    if run env PATH="$(dirname "$node_bin"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        npx -y playwright@latest install-deps chromium; then
        dry && return 0
        date -Iseconds >"$marker"
        ok "Playwright-Abhängigkeiten installiert"
    else
        warn "playwright install-deps fehlgeschlagen. Erneut: sudo t3-worker-setup --phase browser"
    fi
}
