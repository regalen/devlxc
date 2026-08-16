#!/usr/bin/env bash
#
# create-runner-lxc.sh  -  run this ON THE PROXMOX HOST as root.
#
# Creates a Fedora LXC running a self-hosted GitHub Actions runner, with a
# rootless Podman runtime so workflows that build images or use Testcontainers
# work. Unlike the dev container this one is long-lived: back it up.
#
# Usage:
#   ./create-runner-lxc.sh
#   DESTROY=1 CTID=101 ./create-runner-lxc.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CT_HOSTNAME="${CT_HOSTNAME:-ghrunner}"
CT_STORAGE="${CT_STORAGE:-local-lvm}"
TPL_STORAGE="${TPL_STORAGE:-local}"
DISK_GB="${DISK_GB:-80}"                     # image layers accumulate here
CORES="${CORES:-4}"
MEMORY_MB="${MEMORY_MB:-8192}"
SWAP_MB="${SWAP_MB:-4096}"
CPUUNITS="${CPUUNITS:-50}"
BRIDGE="${BRIDGE:-vmbr0}"
MACADDR="${MACADDR:-BC:24:11:DE:00:02}"      # differs from the dev container
GUEST_SCRIPT="${GUEST_SCRIPT:-$(dirname "$(readlink -f "$0")")/provision-runner.sh}"

# Identity and registration. Prompted if unset.
RUNNER_USER="${RUNNER_USER:-}"
REPO_URL="${REPO_URL:-}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64,fedora,podman}"

UNPRIVILEGED="${UNPRIVILEGED:-1}"
IDMAP_HOST_BASE="${IDMAP_HOST_BASE:-100000}"
IDMAP_COUNT="${IDMAP_COUNT:-200000}"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "Run this on the Proxmox host as root." >&2; exit 1; }
command -v pct >/dev/null || { echo "pct not found. Is this a Proxmox host?" >&2; exit 1; }
[[ -f "$GUEST_SCRIPT" ]] || { echo "Guest script not found: $GUEST_SCRIPT" >&2; exit 1; }

CTID="${CTID:-$(pvesh get /cluster/nextid)}"

if [[ "${DESTROY:-0}" == "1" ]] && pct status "$CTID" &>/dev/null; then
  echo ">> Destroying existing CT $CTID"
  pct stop "$CTID" --skiplock 1 &>/dev/null || true
  pct destroy "$CTID" --purge 1
fi

if pct status "$CTID" &>/dev/null; then
  echo "CT $CTID already exists. Set DESTROY=1 to rebuild, or pass a different CTID." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Questions
# ---------------------------------------------------------------------------
echo
echo "=== GitHub Actions runner LXC ==="

while [[ -z "$RUNNER_USER" ]]; do
  read -rp "Service account username for the runner: " RUNNER_USER
done

while :; do
  read -rsp "Password for '${RUNNER_USER}' (for SSH admin access): " P1; echo
  read -rsp "Confirm: " P2; echo
  [[ -n "$P1" && "$P1" == "$P2" ]] && break
  echo "Empty or mismatched, try again."
done
RUNNER_PASSWORD="$P1"; unset P1 P2

while [[ -z "$REPO_URL" ]]; do
  echo "Repository the runner attaches to, e.g. https://github.com/owner/repo"
  read -rp "  repo URL: " REPO_URL
done

echo
echo "Registration token. Get it from the repo:"
echo "  Settings > Actions > Runners > New self-hosted runner > Linux"
echo "  It is the value after --token, and it expires in one hour."
echo "  Or: gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token"
while :; do
  read -rsp "  token: " REG_TOKEN; echo
  [[ -n "$REG_TOKEN" ]] && { echo "  received ${#REG_TOKEN} characters"; break; }
  echo "  Nothing received, try again."
done

read -rp "Runner labels [${RUNNER_LABELS}]: " L_IN
RUNNER_LABELS="${L_IN:-$RUNNER_LABELS}"

read -rp "Timezone [Australia/Melbourne]: " TZ_IN
TZ_IN="${TZ_IN:-Australia/Melbourne}"

ask_yn() {
  local prompt="$1" def="$2" ans
  read -rp "$prompt [$( [[ $def == y ]] && echo 'Y/n' || echo 'y/N' )]: " ans
  ans="${ans:-$def}"
  [[ "${ans,,}" == y* ]] && echo true || echo false
}

echo
OPT_DOTNET=$(ask_yn "Install .NET SDK 10 on the runner" y)
OPT_NODE=$(ask_yn "Install Node.js 22 on the runner" y)
OPT_AUTOUPDATE=$(ask_yn "Enable unattended security updates (long-lived box)" y)
OPT_PRUNE=$(ask_yn "Weekly 'podman system prune -af' timer" y)

echo
echo "About to create CT $CTID ($CT_HOSTNAME): ${CORES} cores, ${MEMORY_MB}MB, ${DISK_GB}GB"
read -rp "Continue? [y/N]: " GO
[[ "${GO,,}" == y* ]] || exit 1

# ---------------------------------------------------------------------------
# Template
# ---------------------------------------------------------------------------
echo ">> Refreshing template list"
pveam update >/dev/null

TEMPLATE="$(pveam available --section system \
  | awk '{print $2}' \
  | grep -E '^fedora-[0-9]+-default' \
  | sort -V | tail -n1)"

[[ -n "$TEMPLATE" ]] || { echo "No Fedora template available from pveam." >&2; exit 1; }
echo ">> Using template: $TEMPLATE"

if ! pveam list "$TPL_STORAGE" | grep -q "$TEMPLATE"; then
  echo ">> Downloading template"
  pveam download "$TPL_STORAGE" "$TEMPLATE"
fi

# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------
echo ">> Creating CT $CTID"
pct create "$CTID" "${TPL_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$CT_HOSTNAME" \
  --cores "$CORES" \
  --cpuunits "$CPUUNITS" \
  --memory "$MEMORY_MB" \
  --swap "$SWAP_MB" \
  --rootfs "${CT_STORAGE}:${DISK_GB}" \
  --net0 "name=eth0,bridge=${BRIDGE},hwaddr=${MACADDR},ip=dhcp,firewall=0" \
  --features "nesting=1,keyctl=1" \
  --unprivileged "$UNPRIVILEGED" \
  --onboot 1 \
  --ostype fedora \
  --timezone "$TZ_IN" \
  --description "GitHub Actions self-hosted runner. Long-lived: back this up."

CONF="/etc/pve/lxc/${CTID}.conf"

if [[ "$UNPRIVILEGED" == "1" ]]; then
  echo ">> Widening the ID map for nested rootless podman"
  for f in /etc/subuid /etc/subgid; do
    if ! grep -qE "^root:${IDMAP_HOST_BASE}:${IDMAP_COUNT}$" "$f"; then
      sed -i -E "/^root:${IDMAP_HOST_BASE}:[0-9]+$/d" "$f"
      echo "root:${IDMAP_HOST_BASE}:${IDMAP_COUNT}" >> "$f"
    fi
  done

  cat >> "$CONF" <<EOF
lxc.idmap: u 0 ${IDMAP_HOST_BASE} ${IDMAP_COUNT}
lxc.idmap: g 0 ${IDMAP_HOST_BASE} ${IDMAP_COUNT}
EOF
fi

# fuse-overlayfs needs /dev/fuse; pasta and slirp4netns need /dev/net/tun.
modprobe tun 2>/dev/null || true
grep -qx tun /etc/modules-load.d/tun.conf 2>/dev/null || echo tun > /etc/modules-load.d/tun.conf

cat >> "$CONF" <<'EOF'
lxc.cgroup2.devices.allow: c 10:229 rwm
lxc.mount.entry: /dev/fuse dev/fuse none bind,create=file,optional 0 0
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file,optional 0 0
EOF

echo ">> Starting CT $CTID"
pct start "$CTID"

echo -n ">> Waiting for network"
for _ in $(seq 1 60); do
  if pct exec "$CTID" -- getent hosts mirrors.fedoraproject.org &>/dev/null; then
    echo " ok"; break
  fi
  echo -n "."; sleep 2
done
pct exec "$CTID" -- getent hosts mirrors.fedoraproject.org &>/dev/null \
  || { echo; echo "Container has no DNS/network." >&2; exit 1; }

# ---------------------------------------------------------------------------
# Push and provision
# ---------------------------------------------------------------------------
echo ">> Pushing configuration"

ANSWERS="$(mktemp)"; chmod 600 "$ANSWERS"
trap 'shred -u "$ANSWERS" 2>/dev/null || true' EXIT

cat > "$ANSWERS" <<EOF
RUNNER_USER=${RUNNER_USER}
RUNNER_PASSWORD=$(printf '%q' "$RUNNER_PASSWORD")
REPO_URL=$(printf '%q' "$REPO_URL")
RUNNER_LABELS=$(printf '%q' "$RUNNER_LABELS")
RUNNER_NAME=${CT_HOSTNAME}
DEV_TZ=${TZ_IN}
OPT_DOTNET=${OPT_DOTNET}
OPT_NODE=${OPT_NODE}
OPT_AUTOUPDATE=${OPT_AUTOUPDATE}
OPT_PRUNE=${OPT_PRUNE}
EOF

TOKTMP="$(mktemp -p /dev/shm)"; chmod 600 "$TOKTMP"
printf '%s' "$REG_TOKEN" > "$TOKTMP"

pct push "$CTID" "$ANSWERS"      /run/runner-answers.env   --perms 600
pct push "$CTID" "$TOKTMP"       /run/runner-token         --perms 600
pct push "$CTID" "$GUEST_SCRIPT" /root/provision-runner.sh --perms 700

shred -u "$TOKTMP"
unset REG_TOKEN

echo ">> Provisioning (this takes a while)"
pct exec "$CTID" -- /bin/bash /root/provision-runner.sh

IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"

echo
echo "==============================================="
echo " CT $CTID ready."
echo " Host: $CT_HOSTNAME    IP: ${IP:-unknown}    MAC: $MACADDR"
echo
echo " The runner should now show as Idle at:"
echo "   ${REPO_URL}/settings/actions/runners"
echo
echo " Use it in a workflow with:"
echo "   runs-on: [self-hosted, linux, x64]"
echo
echo " This container is NOT disposable. Add it to your backup schedule."
echo "==============================================="
