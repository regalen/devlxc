#!/usr/bin/env bash
#
# provision-devlxc.sh  -  runs INSIDE the Fedora LXC as root.
#
# Non-interactive. Reads its answers from /run/devlxc-answers.env and
# /run/devlxc-repos.txt, which create-devlxc.sh pushes in.
#
# It is also standalone: if you want to provision a Fedora VM or a box that
# was not built by create-devlxc.sh, write those two files yourself and run
# this directly. Idempotent, so re-running it is safe.
#
set -euo pipefail

ANSWERS=/run/devlxc-answers.env
REPOLIST=/run/devlxc-repos.txt
PATFILE=/run/gh-pat

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*"; }

[[ -r "$ANSWERS" ]] || { echo "Missing $ANSWERS" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ANSWERS"

DEV_USER="${DEV_USER:?answers file must set DEV_USER}"
DEV_TZ="${DEV_TZ:-Australia/Melbourne}"
DEV_HOME="/home/${DEV_USER}"
SRC_DIR="${DEV_HOME}/src"

# runuser -l does not set XDG_RUNTIME_DIR or the DBus address, so anything
# using `systemctl --user` fails with "$DBUS_SESSION_BUS_ADDRESS and
# $XDG_RUNTIME_DIR not defined". Supply both on every call.
as_user() {
  local uid
  uid="$(id -u "$DEV_USER" 2>/dev/null || echo 0)"
  runuser -l "$DEV_USER" -c \
    "export XDG_RUNTIME_DIR=/run/user/${uid} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus; $*"
}

# ---------------------------------------------------------------------------
# 1. Base system
# ---------------------------------------------------------------------------
log "Base packages"

# bubblewrap is in the base set rather than tied to the Codex toggle: Codex
# uses it to sandbox the commands it runs and warns on every launch without
# it, and it is small enough that conditionally installing it is not worth
# the branch.

# SELinux is inert in an LXC guest anyway (the Proxmox host kernel runs
# AppArmor and loads no SELinux policy), but Fedora userspace tools get noisy
# about the mismatch. Make the config agree with reality.
if [[ -f /etc/selinux/config ]]; then
  sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config || true
fi

dnf -y --setopt=install_weak_deps=False upgrade

dnf -y --setopt=install_weak_deps=False install \
  git curl wget tar xz unzip jq which findutils procps-ng iproute hostname \
  ca-certificates openssl openssl-libs libicu tzdata \
  tmux ripgrep vim rsync bash-completion ncdu htop \
  bubblewrap \
  sudo shadow-utils passwd \
  gh \
  podman podman-docker fuse-overlayfs slirp4netns \
  python3 python3-pip \
  gcc-c++ make

timedatectl set-timezone "$DEV_TZ" 2>/dev/null || ln -sf "/usr/share/zoneinfo/${DEV_TZ}" /etc/localtime

# ---------------------------------------------------------------------------
# 2. User
# ---------------------------------------------------------------------------
log "User ${DEV_USER}"

if ! id "$DEV_USER" &>/dev/null; then
  useradd -m -G wheel -s /bin/bash "$DEV_USER"
fi
echo "${DEV_USER}:${DEV_PASSWORD}" | chpasswd
unset DEV_PASSWORD

# wheel already has sudo on Fedora, but be explicit rather than assume.
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/90-wheel
chmod 440 /etc/sudoers.d/90-wheel

# Password-only SSH was the choice, so make sure sshd allows it and root does not.
dnf -y --setopt=install_weak_deps=False install openssh-server
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl enable --now sshd

# Subordinate ID ranges for rootless podman. Fedora's useradd normally does
# this, but confirm rather than trust it, because the failure mode is a
# confusing "no subuid ranges found" three steps later.
# Subordinate ID ranges for rootless podman. Fedora's useradd allocates these
# starting at 524288, which is outside the 200000-wide ID range of an
# unprivileged LXC, so newuidmap gets EPERM writing the map. Rewrite the entry
# rather than only adding one when missing.
for f in /etc/subuid /etc/subgid; do
  if grep -q "^${DEV_USER}:" "$f"; then
    sed -i "s|^${DEV_USER}:.*|${DEV_USER}:100000:65536|" "$f"
  else
    echo "${DEV_USER}:100000:65536" >> "$f"
  fi
done

# Keep the user's systemd instance alive after SSH disconnects, otherwise the
# podman socket dies with your shell and Testcontainers can find nothing.
loginctl enable-linger "$DEV_USER"

# ---------------------------------------------------------------------------
# 3. Podman as the Docker endpoint
# ---------------------------------------------------------------------------
log "Rootless podman"

DEV_UID="$(id -u "$DEV_USER")"

# enable-linger starts the user manager asynchronously, so /run/user/<uid>
# may not exist for a second or two after it returns.
for _ in $(seq 1 30); do
  [[ -d "/run/user/${DEV_UID}" ]] && break
  sleep 1
done
[[ -d "/run/user/${DEV_UID}" ]] || warn "/run/user/${DEV_UID} never appeared; is lingering enabled?"

as_user "systemctl --user enable --now podman.socket" \
  || warn "Could not enable the user podman socket; container tests will fail"
cat > /etc/profile.d/devlxc.sh <<EOF
# Point Docker-speaking tooling at the rootless podman socket.
export DOCKER_HOST=unix:///run/user/${DEV_UID}/podman.sock

# Testcontainers' Ryuk reaper wants a privileged sidecar with access to the
# daemon socket, which rootless podman will not give it. Disable it and let
# the test host clean up its own containers.
export TESTCONTAINERS_RYUK_DISABLED=true

export PATH="\$HOME/.local/bin:\$HOME/.dotnet/tools:\$PATH"
EOF
chmod 644 /etc/profile.d/devlxc.sh

# Sanity check the runtime now, not halfway through a test run later.
# Errors are shown rather than swallowed, because the failure modes here
# (bad subuid range, missing keyctl, no /dev/fuse) all look identical from
# the outside and the message is the only thing that distinguishes them.
as_user "podman system migrate" &>/dev/null || true
if as_user "source /etc/profile.d/devlxc.sh && podman run --rm docker.io/library/hello-world"; then
  echo "podman: ok"
else
  warn "podman could not run a test container. See the error above."
  warn "Check: features nesting=1,keyctl=1 / lxc.idmap width / the user's range in /etc/subuid"
fi

# ---------------------------------------------------------------------------
# 4. .NET 10
# ---------------------------------------------------------------------------
log ".NET SDK 10"

# Fedora ships dotnet-sdk-10.0 in its own repos. Do not add
# packages-microsoft-prod as well; mixing the two feeds breaks the SDK.
if dnf -y --setopt=install_weak_deps=False install dotnet-sdk-10.0; then
  echo "dotnet: from Fedora repos"
else
  warn "dotnet-sdk-10.0 not in the repos, falling back to dotnet-install.sh"
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  chmod +x /tmp/dotnet-install.sh
  as_user "/tmp/dotnet-install.sh --channel 10.0 --install-dir \$HOME/.dotnet"
  echo 'export PATH="$HOME/.dotnet:$PATH"' >> /etc/profile.d/devlxc.sh
fi

# ---------------------------------------------------------------------------
# 5. Node 22
# ---------------------------------------------------------------------------
log "Node.js 22"

if ! command -v node &>/dev/null || [[ "$(node -v 2>/dev/null | cut -c2-3)" != "22" ]]; then
  if curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -; then
    dnf -y --setopt=install_weak_deps=False install nodejs
  else
    warn "NodeSource failed, trying Fedora's versioned package"
    dnf -y --setopt=install_weak_deps=False install nodejs22 npm
  fi
fi
node -v; npm -v

# ---------------------------------------------------------------------------
# 6. Agent CLIs
# ---------------------------------------------------------------------------
log "Agent CLIs"

# All three installers fetch the current release by default, so a rebuild
# always lands on the latest version rather than a pinned one.

if [[ "${AGENT_CLAUDE:-false}" == "true" ]]; then
  # Native installer, no Node dependency, lands in ~/.local/bin.
  as_user "curl -fsSL https://claude.ai/install.sh | bash" || warn "Claude Code install failed"
fi

if [[ "${AGENT_CODEX:-false}" == "true" ]]; then
  as_user "curl -fsSL https://chatgpt.com/codex/install.sh | sh" || warn "Codex install failed"
fi

if [[ "${AGENT_AGY:-false}" == "true" ]]; then
  # Single binary, installs agy to ~/.local/bin. It prefers the OS keyring and
  # falls back to a printed URL over SSH. There is no Secret Service daemon on
  # a headless box, so the fallback is the normal path here.
  as_user "curl -fsSL https://antigravity.google/cli/install.sh | bash" || warn "Antigravity install failed"
fi

if [[ "${AGENT_CLAUDE:-false}" != "true" \
   && "${AGENT_CODEX:-false}"  != "true" \
   && "${AGENT_AGY:-false}"    != "true" ]]; then
  echo "  none selected"
fi

# ---------------------------------------------------------------------------
# 7. GitHub auth
# ---------------------------------------------------------------------------
log "GitHub auth"

if [[ -r "$PATFILE" ]]; then
  install -o "$DEV_USER" -g "$DEV_USER" -m 600 "$PATFILE" "${DEV_HOME}/.ghpat"
  as_user "gh auth login --with-token < \$HOME/.ghpat" || warn "gh auth failed"
  as_user "gh auth setup-git" || true
  as_user "shred -u \$HOME/.ghpat" || rm -f "${DEV_HOME}/.ghpat"
  shred -u "$PATFILE" || rm -f "$PATFILE"
  if as_user "gh auth status" &>/dev/null; then
    echo "  gh: authenticated"
  else
    warn "gh is NOT authenticated. Private repo clones below will fail."
  fi
else
  warn "No PAT reached the container. Private repo clones below WILL fail."
fi

# Identity from the answers file. Set globally because the container is
# disposable, and make sure nothing appends co-author or generated-by trailers.
as_user "git config --global user.name  '${GIT_USER_NAME}'"
as_user "git config --global user.email '${GIT_USER_EMAIL}'"
as_user 'git config --global init.defaultBranch main'
as_user 'git config --global pull.rebase true'

# ---------------------------------------------------------------------------
# 8. Optional extras
# ---------------------------------------------------------------------------
if [[ "${OPT_FIXTURES:-false}" == "true" ]]; then
  log "Fixture inspection tools"
  dnf -y --setopt=install_weak_deps=False install poppler-utils python3-openpyxl python3-xlrd
  # Fedora is PEP 668 externally managed, so pdfplumber goes in a venv.
  as_user "python3 -m venv \$HOME/.venvs/bidparser"
  as_user "\$HOME/.venvs/bidparser/bin/pip install --quiet --upgrade pip pdfplumber"
fi

if [[ "${OPT_ROSLYNMCP:-false}" == "true" ]]; then
  log "roslyn-mcp"
  as_user "source /etc/profile.d/devlxc.sh && dotnet tool install --global roslynmcp.server --version 0.4.0" \
    || warn "roslynmcp.server did not resolve. If it is not on nuget.org you need to add the original source."
fi

if [[ "${OPT_PLAYWRIGHT:-false}" == "true" ]]; then
  log "Playwright browsers"
  # No --with-deps: Playwright only knows how to install system libraries via
  # apt, so it errors out on Fedora. Pull the matching libs from dnf instead.
  dnf -y --setopt=install_weak_deps=False install \
    nss nspr atk at-spi2-atk cups-libs libdrm libxkbcommon at-spi2-core \
    libXcomposite libXdamage libXfixes libXrandr mesa-libgbm alsa-lib \
    || warn "Playwright system libraries incomplete"
  as_user "npx -y playwright install chromium" || warn "Playwright install failed"
fi

if [[ "${OPT_UV:-false}" == "true" ]]; then
  log "uv"
  as_user "curl -fsSL https://astral.sh/uv/install.sh | sh" || warn "uv install failed"
fi

# Helper: fetch a named asset from a GitHub project's latest release.
gh_release_asset() { # gh_release_asset <owner/repo> <grep pattern> <dest>
  local repo="$1" pattern="$2" dest="$3" url
  url="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | jq -r --arg p "$pattern" '.assets[] | select(.name | test($p)) | .browser_download_url' \
    | head -n1)"
  [[ -n "$url" ]] || return 1
  curl -fsSL "$url" -o "$dest"
}

if [[ "${OPT_ACT:-false}" == "true" ]]; then
  log "act"
  # act is not packaged for Fedora. Its own installer drops a static binary.
  if curl -fsSL https://raw.githubusercontent.com/nektos/act/master/install.sh \
     | bash -s -- -b /usr/local/bin; then
    echo "  act: $(act --version 2>/dev/null || echo installed)"
  else
    warn "act install failed"
  fi
fi

if [[ "${OPT_SQLCMD:-false}" == "true" ]]; then
  log "sqlcmd"
  # Deliberately the standalone go-sqlcmd binary, NOT the mssql-tools18 package.
  # That package only comes from packages.microsoft.com, whose repo also carries
  # dotnet builds that collide with Fedora's own dotnet-sdk-10.0. Adding the
  # repo means either an excludepkgs rule you have to maintain or a broken SDK
  # on the next upgrade. One static binary avoids the whole problem.
  TMPD="$(mktemp -d)"
  if gh_release_asset microsoft/go-sqlcmd 'linux-amd64\.tar\.bz2$' "${TMPD}/sqlcmd.tar.bz2"; then
    tar -xjf "${TMPD}/sqlcmd.tar.bz2" -C "$TMPD"
    install -m 755 "${TMPD}/sqlcmd" /usr/local/bin/sqlcmd
    echo "  sqlcmd: $(sqlcmd --version 2>/dev/null | head -n1 || echo installed)"
  else
    warn "sqlcmd download failed"
  fi
  rm -rf "$TMPD"
fi

if [[ "${OPT_DBCLIENTS:-false}" == "true" ]]; then
  log "sqlite3 and psql"
  # sqlcmd speaks TDS only, so these are separate clients for separate engines.
  dnf -y --setopt=install_weak_deps=False install sqlite postgresql \
    || warn "db client install failed"
fi

if [[ "${OPT_LINT:-false}" == "true" ]]; then
  log "shellcheck and hadolint"
  dnf -y --setopt=install_weak_deps=False install ShellCheck || warn "shellcheck install failed"
  # hadolint ships a static binary only. Match case-insensitively, since the
  # project has renamed its release assets between Linux and linux before.
  if gh_release_asset hadolint/hadolint '(?i)linux-x86_64$' /usr/local/bin/hadolint; then
    chmod 755 /usr/local/bin/hadolint
    echo "  hadolint: $(hadolint --version 2>/dev/null || echo installed)"
  else
    warn "hadolint download failed"
  fi
fi

# ---------------------------------------------------------------------------
# 9. Clone repos
# ---------------------------------------------------------------------------
log "Repositories"

install -d -o "$DEV_USER" -g "$DEV_USER" "$SRC_DIR"

if [[ -s "$REPOLIST" ]]; then
  while IFS= read -r REPO; do
    [[ -z "$REPO" ]] && continue
    NAME="$(basename "${REPO%.git}")"
    if [[ -d "${SRC_DIR}/${NAME}/.git" ]]; then
      echo "  ${NAME}: already present"
      continue
    fi
    echo "  cloning ${NAME}"
    as_user "git clone '${REPO}' '${SRC_DIR}/${NAME}'" || { warn "clone failed: $REPO"; continue; }

    # Per-repo bootstrap that only makes sense once the code is on disk.
    if [[ -f "${SRC_DIR}/${NAME}/.config/dotnet-tools.json" ]]; then
      as_user "source /etc/profile.d/devlxc.sh && cd '${SRC_DIR}/${NAME}' && dotnet tool restore" \
        || warn "dotnet tool restore failed in ${NAME}"
    fi

    if [[ -f "${SRC_DIR}/${NAME}/.env.example" && ! -f "${SRC_DIR}/${NAME}/.env" ]]; then
      as_user "cp '${SRC_DIR}/${NAME}/.env.example' '${SRC_DIR}/${NAME}/.env'"
      ENVF="${SRC_DIR}/${NAME}/.env"
      FILLED=()
      # These key names come from BidParser. Other repos get their .env copied
      # from the example and nothing substituted, so report honestly which
      # keys were actually filled rather than claiming the file is ready.
      if grep -q '^SESSION_SECRET=' "$ENVF"; then
        as_user "sed -i 's|^SESSION_SECRET=.*|SESSION_SECRET=$(openssl rand -hex 32)|' '$ENVF'"
        FILLED+=("SESSION_SECRET")
      fi
      if grep -q '^MSSQL_SA_PASSWORD=' "$ENVF"; then
        # SQL Server refuses to start unless the SA password has upper, lower,
        # digit and symbol, and the healthcheck then never passes.
        SA_PASS="Dev$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)!9"
        as_user "sed -i 's|^MSSQL_SA_PASSWORD=.*|MSSQL_SA_PASSWORD=${SA_PASS}|' '$ENVF'"
        FILLED+=("MSSQL_SA_PASSWORD")
      fi
      if grep -q '^FORWARDED_ALLOW_IPS=' "$ENVF"; then
        as_user "sed -i 's|^FORWARDED_ALLOW_IPS=.*|FORWARDED_ALLOW_IPS=127.0.0.1|' '$ENVF'"
        FILLED+=("FORWARDED_ALLOW_IPS")
      fi
      if [[ ${#FILLED[@]} -gt 0 ]]; then
        echo "  ${NAME}: .env copied, filled ${FILLED[*]}"
      else
        warn "${NAME}: .env copied from example but nothing filled in. Edit it before use."
      fi
    fi
  done < "$REPOLIST"
else
  echo "  none requested"
fi

# ---------------------------------------------------------------------------
# 10. Smoke test
# ---------------------------------------------------------------------------
if [[ "${OPT_SMOKE:-false}" == "true" ]]; then
  FIRST="$(find "$SRC_DIR" -maxdepth 1 -mindepth 1 -type d | head -n1)"
  if [[ -n "$FIRST" ]]; then
    log "Smoke test in $(basename "$FIRST")"
    SLN="$(find "$FIRST" -maxdepth 1 -name '*.sln' | head -n1)"
    if [[ -n "$SLN" ]]; then
      as_user "source /etc/profile.d/devlxc.sh && cd '$FIRST' && dotnet restore '$SLN' && dotnet build '$SLN' -c Release" \
        || warn "build failed"
    fi
    if [[ -f "${FIRST}/frontend/package-lock.json" ]]; then
      as_user "cd '${FIRST}/frontend' && npm ci && npm run build" || warn "frontend build failed"
    fi
    echo
    echo "Full test suite not run automatically. On 4 cores with a SQL Server"
    echo "container it takes a long time. Run it yourself when you want it:"
    echo "  cd $FIRST && dotnet test"
  fi
fi

# ---------------------------------------------------------------------------
rm -f "$ANSWERS" "$REPOLIST"

log "Provisioning complete"
echo "  user:     ${DEV_USER}"
echo "  repos:    ${SRC_DIR}"
echo "  docker:   \$DOCKER_HOST -> rootless podman socket"
echo "  agents:   claude / codex / agy (each needs an interactive login)"
