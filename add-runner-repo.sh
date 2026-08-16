#!/usr/bin/env bash
#
# add-runner-repo.sh  -  run this INSIDE the runner LXC as root (or with sudo).
#
# Registers an additional GitHub Actions runner for another repository into a
# container that create-runner-lxc.sh already provisioned. Each repo gets its
# own directory and its own systemd service; they share the machine, the
# podman socket and the package caches.
#
# Usage:
#   sudo ./add-runner-repo.sh
#   sudo REPO_URL=https://github.com/owner/repo ./add-runner-repo.sh
#
set -euo pipefail

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

RUNNER_USER="${RUNNER_USER:-}"
REPO_URL="${REPO_URL:-}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64,fedora,podman}"

# Work out the service account from the existing install rather than asking.
if [[ -z "$RUNNER_USER" ]]; then
  RUNNER_USER="$(find /home -maxdepth 2 -name '.runner' -printf '%h\n' 2>/dev/null \
    | head -n1 | awk -F/ '{print $3}')"
fi
[[ -n "$RUNNER_USER" ]] || { echo "Could not find an existing runner. Set RUNNER_USER." >&2; exit 1; }

RUNNER_HOME="/home/${RUNNER_USER}"
RUNNER_UID="$(id -u "$RUNNER_USER")"
as_user() { runuser -l "$RUNNER_USER" -c "$*"; }

echo "Service account: ${RUNNER_USER}"

while [[ -z "$REPO_URL" ]]; do
  read -rp "Repository URL (https://github.com/owner/repo): " REPO_URL
done

REPO_NAME="$(basename "$REPO_URL")"
TARGET="${RUNNER_HOME}/actions-runner-${REPO_NAME,,}"

if [[ -f "${TARGET}/.runner" ]]; then
  echo "A runner for ${REPO_NAME} already exists at ${TARGET}." >&2
  echo "Remove it in GitHub's UI and delete that directory to re-register." >&2
  exit 1
fi

echo
echo "Registration token from:"
echo "  ${REPO_URL}/settings/actions/runners/new"
echo "  or: gh api -X POST repos/<owner>/${REPO_NAME}/actions/runners/registration-token --jq .token"
while :; do
  read -rsp "  token: " REG_TOKEN; echo
  [[ -n "$REG_TOKEN" ]] && { echo "  received ${#REG_TOKEN} characters"; break; }
  echo "  Nothing received, try again."
done

read -rp "Labels [${RUNNER_LABELS}]: " L_IN
RUNNER_LABELS="${L_IN:-$RUNNER_LABELS}"

# ---------------------------------------------------------------------------
log "Extracting runner into ${TARGET}"

install -d -o "$RUNNER_USER" -g "$RUNNER_USER" "$TARGET"

URL="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
  | jq -r '.assets[] | select(.name | test("actions-runner-linux-x64-[0-9.]+\\.tar\\.gz$")) | .browser_download_url' \
  | head -n1)"
[[ -n "$URL" ]] || { echo "Could not resolve the runner download URL." >&2; exit 1; }

curl -fsSL "$URL" -o /tmp/actions-runner.tar.gz
tar -xzf /tmp/actions-runner.tar.gz -C "$TARGET"
chown -R "$RUNNER_USER:$RUNNER_USER" "$TARGET"
rm -f /tmp/actions-runner.tar.gz

# Jobs inherit this, not /etc/profile.d, because svc.sh writes a system unit.
cat > "${TARGET}/.env" <<EOF
DOCKER_HOST=unix:///run/user/${RUNNER_UID}/podman.sock
TESTCONTAINERS_RYUK_DISABLED=true
XDG_RUNTIME_DIR=/run/user/${RUNNER_UID}
EOF
chown "$RUNNER_USER:$RUNNER_USER" "${TARGET}/.env"

# ---------------------------------------------------------------------------
log "Registering"

install -o "$RUNNER_USER" -g "$RUNNER_USER" -m 600 /dev/null "${TARGET}/.regtoken"
printf '%s' "$REG_TOKEN" > "${TARGET}/.regtoken"
unset REG_TOKEN

as_user "cd '${TARGET}' && ./config.sh \
  --unattended \
  --url '${REPO_URL}' \
  --token \"\$(cat .regtoken)\" \
  --name '$(hostname)-${REPO_NAME,,}' \
  --labels '${RUNNER_LABELS}' \
  --work _work \
  --replace" || { warn "Registration failed"; }

as_user "shred -u '${TARGET}/.regtoken'" || rm -f "${TARGET}/.regtoken"

# ---------------------------------------------------------------------------
if [[ -f "${TARGET}/.runner" ]]; then
  log "Installing service"
  ( cd "$TARGET" && ./svc.sh install "$RUNNER_USER" && ./svc.sh start )
  sleep 3
  ( cd "$TARGET" && ./svc.sh status ) || true

  echo
  echo "==============================================="
  echo " Runner for ${REPO_NAME} is registered."
  echo " Check: ${REPO_URL}/settings/actions/runners"
  echo "==============================================="
else
  warn "No .runner file written, so registration did not complete."
  exit 1
fi
