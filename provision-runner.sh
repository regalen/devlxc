#!/usr/bin/env bash
#
# provision-runner.sh  -  runs INSIDE the Fedora LXC as root.
#
# Non-interactive. Reads /run/runner-answers.env and /run/runner-token, both
# pushed in by create-runner-lxc.sh. Idempotent enough to re-run, though
# re-registering an existing runner needs it removed from GitHub first.
#
set -euo pipefail

ANSWERS=/run/runner-answers.env
TOKENFILE=/run/runner-token

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*"; }

[[ -r "$ANSWERS" ]] || { echo "Missing $ANSWERS" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ANSWERS"

RUNNER_USER="${RUNNER_USER:?answers file must set RUNNER_USER}"
DEV_TZ="${DEV_TZ:-Australia/Melbourne}"
RUNNER_HOME="/home/${RUNNER_USER}"
RUNNER_DIR="${RUNNER_HOME}/actions-runner"

# runuser -l does not set XDG_RUNTIME_DIR or the DBus address, so anything
# using `systemctl --user` fails with "$DBUS_SESSION_BUS_ADDRESS and
# $XDG_RUNTIME_DIR not defined". Supply both on every call.
as_user() {
  local uid
  uid="$(id -u "$RUNNER_USER" 2>/dev/null || echo 0)"
  runuser -l "$RUNNER_USER" -c \
    "export XDG_RUNTIME_DIR=/run/user/${uid} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus; $*"
}

# ---------------------------------------------------------------------------
# 1. Base system
# ---------------------------------------------------------------------------
log "Base packages"

if [[ -f /etc/selinux/config ]]; then
  sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config || true
fi

dnf -y --setopt=install_weak_deps=False upgrade

# libicu, krb5-libs, zlib and openssl-libs are the runner's own native
# dependencies. It is a .NET application, which is why they look familiar.
dnf -y --setopt=install_weak_deps=False install \
  git curl wget tar xz unzip jq which findutils procps-ng iproute hostname \
  ca-certificates openssl openssl-libs libicu krb5-libs zlib tzdata \
  tmux vim rsync ncdu htop bash-completion \
  sudo shadow-utils passwd openssh-server \
  podman podman-docker fuse-overlayfs slirp4netns

timedatectl set-timezone "$DEV_TZ" 2>/dev/null || ln -sf "/usr/share/zoneinfo/${DEV_TZ}" /etc/localtime

# ---------------------------------------------------------------------------
# 2. Service account
# ---------------------------------------------------------------------------
log "User ${RUNNER_USER}"

if ! id "$RUNNER_USER" &>/dev/null; then
  useradd -m -G wheel -s /bin/bash "$RUNNER_USER"
fi
echo "${RUNNER_USER}:${RUNNER_PASSWORD}" | chpasswd
unset RUNNER_PASSWORD

echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/90-wheel
chmod 440 /etc/sudoers.d/90-wheel

sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl enable --now sshd

# Fedora's useradd allocates subordinate IDs from 524288, outside an
# unprivileged LXC's ID range. Rewrite rather than only adding when missing.
for f in /etc/subuid /etc/subgid; do
  if grep -q "^${RUNNER_USER}:" "$f"; then
    sed -i "s|^${RUNNER_USER}:.*|${RUNNER_USER}:100000:65536|" "$f"
  else
    echo "${RUNNER_USER}:100000:65536" >> "$f"
  fi
done

# Essential here: the runner service must work with nobody logged in, so the
# user's systemd instance and /run/user/<uid> have to persist.
loginctl enable-linger "$RUNNER_USER"

# ---------------------------------------------------------------------------
# 3. Rootless podman
# ---------------------------------------------------------------------------
log "Rootless podman"

RUNNER_UID="$(id -u "$RUNNER_USER")"

# enable-linger starts the user manager asynchronously, so /run/user/<uid>
# may not exist for a second or two after it returns.
for _ in $(seq 1 30); do
  [[ -d "/run/user/${RUNNER_UID}" ]] && break
  sleep 1
done
[[ -d "/run/user/${RUNNER_UID}" ]] || warn "/run/user/${RUNNER_UID} never appeared; is lingering enabled?"

as_user "systemctl --user enable --now podman.socket" \
  || warn "Could not enable the user podman socket; jobs needing a container runtime will fail"

cat > /etc/profile.d/runner.sh <<EOF
export DOCKER_HOST=unix:///run/user/${RUNNER_UID}/podman.sock
export TESTCONTAINERS_RYUK_PRIVILEGED=true
export PATH="\$HOME/.local/bin:\$HOME/.dotnet/tools:\$PATH"
EOF
chmod 644 /etc/profile.d/runner.sh

as_user "podman system migrate" &>/dev/null || true
if as_user "source /etc/profile.d/runner.sh && podman run --rm docker.io/library/hello-world"; then
  echo "podman: ok"
else
  warn "podman could not run a test container. See the error above."
  warn "Check: features nesting=1,keyctl=1 / lxc.idmap width / /etc/subuid range"
fi

# ---------------------------------------------------------------------------
# 4. Toolchain
# ---------------------------------------------------------------------------
if [[ "${OPT_DOTNET:-false}" == "true" ]]; then
  log ".NET SDK 10"
  dnf -y --setopt=install_weak_deps=False install dotnet-sdk-10.0 \
    || warn "dotnet-sdk-10.0 not available; workflows can use actions/setup-dotnet instead"
fi

if [[ "${OPT_NODE:-false}" == "true" ]]; then
  log "Node.js 22"
  if curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -; then
    dnf -y --setopt=install_weak_deps=False install nodejs
  else
    dnf -y --setopt=install_weak_deps=False install nodejs22 npm \
      || warn "Node install failed; workflows can use actions/setup-node instead"
  fi
fi

# ---------------------------------------------------------------------------
# 5. The runner itself
# ---------------------------------------------------------------------------
log "GitHub Actions runner"

install -d -o "$RUNNER_USER" -g "$RUNNER_USER" "$RUNNER_DIR"

if [[ ! -x "${RUNNER_DIR}/config.sh" ]]; then
  URL="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
    | jq -r '.assets[] | select(.name | test("actions-runner-linux-x64-[0-9.]+\\.tar\\.gz$")) | .browser_download_url' \
    | head -n1)"
  [[ -n "$URL" ]] || { echo "Could not resolve the runner download URL." >&2; exit 1; }
  echo "  downloading $(basename "$URL")"
  curl -fsSL "$URL" -o /tmp/actions-runner.tar.gz
  tar -xzf /tmp/actions-runner.tar.gz -C "$RUNNER_DIR"
  chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"
  rm -f /tmp/actions-runner.tar.gz
else
  echo "  runner already extracted"
fi

# The runner reads this file and injects it into every job's environment, so
# it is how workflows find the rootless podman socket. A system-level service
# would not otherwise inherit anything from /etc/profile.d.
cat > "${RUNNER_DIR}/.env" <<EOF
DOCKER_HOST=unix:///run/user/${RUNNER_UID}/podman.sock
TESTCONTAINERS_RYUK_PRIVILEGED=true
XDG_RUNTIME_DIR=/run/user/${RUNNER_UID}
RUNNER_TOOL_CACHE=${RUNNER_DIR}/_work/_tool
DOTNET_INSTALL_DIR=${RUNNER_HOME}/.dotnet
EOF
chown "$RUNNER_USER:$RUNNER_USER" "${RUNNER_DIR}/.env"

# actions/setup-dotnet installs to /usr/share/dotnet by default, which a
# non-root runner cannot create. Fedora's own SDK lives in /usr/lib64/dotnet,
# so nothing else has made that path either.
install -d -o "$RUNNER_USER" -g "$RUNNER_USER" "${RUNNER_HOME}/.dotnet"
install -d -o "$RUNNER_USER" -g "$RUNNER_USER" "${RUNNER_DIR}/_work/_tool"

if [[ -f "${RUNNER_DIR}/.runner" ]]; then
  echo "  already registered, skipping config"
else
  [[ -r "$TOKENFILE" ]] || { echo "Missing $TOKENFILE" >&2; exit 1; }
  install -o "$RUNNER_USER" -g "$RUNNER_USER" -m 600 "$TOKENFILE" "${RUNNER_DIR}/.regtoken"

  # config.sh refuses to run as root by design.
  as_user "cd '${RUNNER_DIR}' && ./config.sh \
    --unattended \
    --url '${REPO_URL}' \
    --token \"\$(cat .regtoken)\" \
    --name '${RUNNER_NAME:-$(hostname)}' \
    --labels '${RUNNER_LABELS}' \
    --work _work \
    --replace" || { warn "Runner registration failed"; }

  as_user "shred -u '${RUNNER_DIR}/.regtoken'" || rm -f "${RUNNER_DIR}/.regtoken"
  shred -u "$TOKENFILE" || rm -f "$TOKENFILE"
fi

# svc.sh must run as root; it writes a system unit that runs as the user.
# It refuses to overwrite an existing unit, so only install when absent.
if [[ -f "${RUNNER_DIR}/.runner" ]]; then
  if systemctl list-unit-files --no-legend 2>/dev/null | grep -q '^actions\.runner\.'; then
    echo "  service already installed"
    systemctl start "$(systemctl list-unit-files --no-legend | awk '/^actions\.runner\./{print $1}' | head -n1)" 2>/dev/null || true
  else
    ( cd "$RUNNER_DIR" && ./svc.sh install "$RUNNER_USER" && ./svc.sh start ) \
      || warn "Runner service install failed"
    sleep 3
  fi
  ( cd "$RUNNER_DIR" && ./svc.sh status ) || true
fi

# ---------------------------------------------------------------------------
# 6. Long-lived housekeeping
# ---------------------------------------------------------------------------
if [[ "${OPT_AUTOUPDATE:-false}" == "true" ]]; then
  log "Unattended security updates"
  dnf -y --setopt=install_weak_deps=False install dnf-automatic || \
    dnf -y --setopt=install_weak_deps=False install dnf5-plugin-automatic || \
    warn "no automatic update plugin available"

  # dnf5 ships the default under /usr/share and only creates an /etc copy
  # once you customise it, so seed one rather than expecting it to exist.
  AUTOCONF=""
  for c in /etc/dnf/automatic.conf /etc/dnf/dnf5-plugins/automatic.conf; do
    [[ -f "$c" ]] && { AUTOCONF="$c"; break; }
  done

  if [[ -z "$AUTOCONF" ]]; then
    for d in /usr/share/dnf5/dnf5-plugins/automatic.conf /usr/share/dnf/automatic.conf; do
      if [[ -f "$d" ]]; then
        install -D -m 644 "$d" /etc/dnf/dnf5-plugins/automatic.conf
        AUTOCONF=/etc/dnf/dnf5-plugins/automatic.conf
        echo "  seeded ${AUTOCONF} from $(basename "$(dirname "$d")")"
        break
      fi
    done
  fi

  if [[ -n "$AUTOCONF" ]]; then
    sed -i \
      -e 's/^upgrade_type *=.*/upgrade_type = security/' \
      -e 's/^apply_updates *=.*/apply_updates = yes/' \
      "$AUTOCONF"
    echo "  configured ${AUTOCONF}"
  else
    warn "could not find automatic.conf; security updates not configured"
  fi

  AUTOTIMER="$(systemctl list-unit-files --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -E '^dnf5?-automatic\.timer$' | head -n1)"
  if [[ -n "$AUTOTIMER" ]]; then
    systemctl enable --now "$AUTOTIMER" && echo "  enabled ${AUTOTIMER}"
  else
    warn "no dnf automatic timer unit found"
  fi
fi

if [[ "${OPT_PRUNE:-false}" == "true" ]]; then
  log "Weekly image prune"
  # Nothing else reclaims layers on a persistent runner, and a full disk
  # surfaces as a mysterious build failure rather than a disk error.
  cat > /etc/systemd/system/podman-prune.service <<EOF
[Unit]
Description=Prune unused podman images and containers

[Service]
Type=oneshot
User=${RUNNER_USER}
Environment=XDG_RUNTIME_DIR=/run/user/${RUNNER_UID}
Environment=DOCKER_HOST=unix:///run/user/${RUNNER_UID}/podman.sock
ExecStart=/usr/bin/podman system prune -af
EOF

  cat > /etc/systemd/system/podman-prune.timer <<'EOF'
[Unit]
Description=Weekly podman prune

[Timer]
OnCalendar=Sun 03:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  log "Monthly deep clean"
  # The podman prune above cannot see package caches or stale build output
  # in the workspaces, and both grow without bound on a persistent runner.
  # Monthly rather than weekly, because clearing the NuGet cache costs one
  # slow build afterwards.
  cat > /usr/local/bin/runner-deepclean.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

# Never run mid-job: git clean would delete a running build's output.
if pgrep -u "$(id -un)" -f 'Runner.Worker' >/dev/null 2>&1; then
  echo "A job is running, skipping deep clean."
  exit 0
fi

echo "== npm cache =="
npm cache clean --force 2>/dev/null || echo "npm not available, skipped"

echo "== NuGet caches =="
dotnet nuget locals all --clear 2>/dev/null || echo "dotnet not available, skipped"

echo "== workspaces =="
for d in "$HOME"/actions-runner*/_work/*/*; do
  [ -d "$d/.git" ] || continue
  echo "  cleaning $d"
  git -C "$d" clean -xdf >/dev/null 2>&1 || echo "  clean failed in $d"
done

echo "== disk =="
df -h "$HOME" | tail -1
EOF
  chmod 755 /usr/local/bin/runner-deepclean.sh

  cat > /etc/systemd/system/runner-deepclean.service <<EOF
[Unit]
Description=Monthly runner cache and workspace clean

[Service]
Type=oneshot
User=${RUNNER_USER}
Environment=XDG_RUNTIME_DIR=/run/user/${RUNNER_UID}
Environment=DOTNET_INSTALL_DIR=${RUNNER_HOME}/.dotnet
Environment=PATH=${RUNNER_HOME}/.dotnet:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/local/bin/runner-deepclean.sh
EOF

  # First Sunday of the month, an hour after the weekly prune so they
  # never overlap.
  cat > /etc/systemd/system/runner-deepclean.timer <<'EOF'
[Unit]
Description=Monthly runner deep clean

[Timer]
OnCalendar=Sun *-*-1..7 04:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now podman-prune.timer
  systemctl enable --now runner-deepclean.timer
fi

# ---------------------------------------------------------------------------
rm -f "$ANSWERS"

log "Provisioning complete"
echo "  user:     ${RUNNER_USER}"
echo "  runner:   ${RUNNER_DIR}"
echo "  service:  actions.runner.* (systemctl status)"
echo "  docker:   \$DOCKER_HOST -> rootless podman socket"
echo
echo "  This container is long-lived. Back it up."
