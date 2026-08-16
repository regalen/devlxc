#!/usr/bin/env bash
#
# create-devlxc.sh  -  run this ON THE PROXMOX HOST as root.
#
# Creates a disposable Fedora dev LXC, then pushes and runs provision-devlxc.sh
# inside it. All interactive questions are asked here, on a real TTY, and the
# answers are handed to the guest script as a file so the guest half runs
# completely unattended.
#
# Usage:
#   ./create-devlxc.sh                 # create a new container
#   CTID=210 ./create-devlxc.sh        # force a specific ID
#   DESTROY=1 CTID=210 ./create-devlxc.sh   # destroy 210 first, then rebuild
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CT_HOSTNAME="${CT_HOSTNAME:-devlxc}"
CT_STORAGE="${CT_STORAGE:-local-lvm}"        # where the rootfs lives
TPL_STORAGE="${TPL_STORAGE:-local}"          # where LXC templates live
DISK_GB="${DISK_GB:-64}"
CORES="${CORES:-4}"
MEMORY_MB="${MEMORY_MB:-8192}"
SWAP_MB="${SWAP_MB:-4096}"
CPUUNITS="${CPUUNITS:-50}"                   # below the media VM so Plex wins
BRIDGE="${BRIDGE:-vmbr0}"
MACADDR="${MACADDR:-BC:24:11:DE:00:01}"      # fixed, so the DHCP reservation sticks
# Leave PAT_FILE unset to be prompted for the token instead of storing it on
# the host. Set it to a path if you would rather keep a 600 file around.
PAT_FILE="${PAT_FILE:-}"

# Identity. All three are prompted for if not set here or in the environment,
# so nothing personal has to live in the script itself:
#   DEV_USER=me GIT_USER_NAME=me GIT_USER_EMAIL=me@example.com ./create-devlxc.sh
DEV_USER="${DEV_USER:-}"
GIT_USER_NAME="${GIT_USER_NAME:-}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-}"
GUEST_SCRIPT="${GUEST_SCRIPT:-$(dirname "$(readlink -f "$0")")/provision-devlxc.sh}"

# Unprivileged container plus a widened ID map so rootless podman has subuids
# to hand out. See the README notes: the default unprivileged map is only
# 65536 IDs wide, which is exactly the range rootless podman wants for one
# user, so nested rootless containers fail with "no subuid ranges found".
UNPRIVILEGED="${UNPRIVILEGED:-1}"
IDMAP_HOST_BASE="${IDMAP_HOST_BASE:-100000}"
IDMAP_COUNT="${IDMAP_COUNT:-200000}"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "Run this on the Proxmox host as root." >&2; exit 1; }
command -v pct >/dev/null || { echo "pct not found. Is this a Proxmox host?" >&2; exit 1; }
[[ -f "$GUEST_SCRIPT" ]] || { echo "Guest script not found: $GUEST_SCRIPT" >&2; exit 1; }
if [[ -n "$PAT_FILE" && ! -r "$PAT_FILE" ]]; then
  echo "PAT_FILE set but not readable: $PAT_FILE" >&2; exit 1
fi

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
# Questions (asked here, on a real terminal)
# ---------------------------------------------------------------------------
echo
echo "=== Dev LXC setup ==="

while [[ -z "$DEV_USER" ]]; do
  read -rp "Username for the container's sudo account: " DEV_USER
done

while :; do
  read -rsp "Password for user '${DEV_USER}': " P1; echo
  read -rsp "Confirm: " P2; echo
  [[ -n "$P1" && "$P1" == "$P2" ]] && break
  echo "Empty or mismatched, try again."
done
DEV_PASSWORD="$P1"; unset P1 P2

GH_TOKEN_VALUE=""
if [[ -n "$PAT_FILE" ]]; then
  echo "GitHub PAT: reading from $PAT_FILE"
else
  # Not echoed, not in shell history, never written to the host disk.
  # Confirm the length, because a silent prompt that received nothing looks
  # identical to one that worked until a private clone fails 20 minutes later.
  while :; do
    read -rsp "GitHub PAT (paste, or leave blank to skip GitHub auth): " GH_TOKEN_VALUE; echo
    if [[ -z "$GH_TOKEN_VALUE" ]]; then
      read -rp "  Nothing received. Skip GitHub auth entirely? [y/N]: " SKIPGH
      [[ "${SKIPGH,,}" == y* ]] && break
      continue
    fi
    echo "  received ${#GH_TOKEN_VALUE} characters"
    break
  done
fi

read -rp "Timezone [Australia/Melbourne]: " TZ_IN
TZ_IN="${TZ_IN:-Australia/Melbourne}"

echo
echo "Git identity. This is what appears as the author on every commit you"
echo "make in this container, so it should match the account you push as."
while [[ -z "$GIT_USER_NAME" ]]; do
  read -rp "  git user.name: " GIT_USER_NAME
done
while [[ -z "$GIT_USER_EMAIL" ]]; do
  read -rp "  git user.email: " GIT_USER_EMAIL
done

ask_yn() { # ask_yn "prompt" default(y|n) -> echoes true/false
  local prompt="$1" def="$2" ans
  read -rp "$prompt [$( [[ $def == y ]] && echo 'Y/n' || echo 'y/N' )]: " ans
  ans="${ans:-$def}"
  [[ "${ans,,}" == y* ]] && echo true || echo false
}

echo
echo "Agent CLIs (latest version of whichever you pick):"
AGENT_CLAUDE=$(ask_yn "  Claude Code" n)
AGENT_CODEX=$(ask_yn "  Codex CLI" n)
AGENT_AGY=$(ask_yn "  Antigravity CLI (agy)" n)

echo
echo "Optional extras:"
OPT_PLAYWRIGHT=$(ask_yn "  Playwright browsers (~500 MB, chromium + system libs)" n)
OPT_FIXTURES=$(ask_yn "  PDF/spreadsheet fixture tools (poppler, openpyxl, xlrd, pdfplumber venv)" y)
OPT_ROSLYNMCP=$(ask_yn "  roslyn-mcp dotnet global tool" y)
OPT_UV=$(ask_yn "  Python toolchain (uv) for the Python repos" y)
OPT_ACT=$(ask_yn "  act (run GitHub Actions workflows locally)" y)
OPT_SQLCMD=$(ask_yn "  sqlcmd (MSSQL client)" y)
OPT_DBCLIENTS=$(ask_yn "  sqlite3 and psql clients" n)
OPT_LINT=$(ask_yn "  shellcheck and hadolint" y)
OPT_SMOKE=$(ask_yn "  Run a build smoke test on the first cloned repo at the end" n)

echo
echo "Repos to clone (full git URL, blank line to finish):"
REPOS=()
while :; do
  read -rp "  repo> " R
  [[ -z "$R" ]] && break
  REPOS+=("$R")
done

echo
echo "About to create CT $CTID ($CT_HOSTNAME): ${CORES} cores, ${MEMORY_MB}MB RAM, ${DISK_GB}GB on $CT_STORAGE"
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
  --onboot 0 \
  --ostype fedora \
  --timezone "$TZ_IN" \
  --description "Disposable dev LXC. Rebuilt by create-devlxc.sh."

CONF="/etc/pve/lxc/${CTID}.conf"

if [[ "$UNPRIVILEGED" == "1" ]]; then
  echo ">> Widening the ID map for nested rootless podman"

  # Host must be allowed to delegate the wider range to root.
  for f in /etc/subuid /etc/subgid; do
    if ! grep -qE "^root:${IDMAP_HOST_BASE}:${IDMAP_COUNT}$" "$f"; then
      # Drop any narrower root entry starting at the same base, then add ours.
      sed -i -E "/^root:${IDMAP_HOST_BASE}:[0-9]+$/d" "$f"
      echo "root:${IDMAP_HOST_BASE}:${IDMAP_COUNT}" >> "$f"
    fi
  done

  cat >> "$CONF" <<EOF
lxc.idmap: u 0 ${IDMAP_HOST_BASE} ${IDMAP_COUNT}
lxc.idmap: g 0 ${IDMAP_HOST_BASE} ${IDMAP_COUNT}
EOF
fi

# Two host devices the container cannot create for itself:
#   /dev/fuse    - fuse-overlayfs, podman's fallback when the kernel will not
#                  give it a native overlay mount inside a user namespace.
#   /dev/net/tun - pasta and slirp4netns both build the rootless container
#                  network by creating a tap device, and fail without it.
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
  || { echo; echo "Container has no DNS/network. Check the bridge and DHCP." >&2; exit 1; }

# ---------------------------------------------------------------------------
# Push answers, secret, and the guest script
# ---------------------------------------------------------------------------
echo ">> Pushing configuration"

ANSWERS="$(mktemp)"; chmod 600 "$ANSWERS"
REPOLIST="$(mktemp)"; chmod 600 "$REPOLIST"
trap 'shred -u "$ANSWERS" "$REPOLIST" 2>/dev/null || true' EXIT

cat > "$ANSWERS" <<EOF
DEV_USER=${DEV_USER}
DEV_PASSWORD=$(printf '%q' "$DEV_PASSWORD")
GIT_USER_NAME=$(printf '%q' "$GIT_USER_NAME")
GIT_USER_EMAIL=$(printf '%q' "$GIT_USER_EMAIL")
DEV_TZ=${TZ_IN}
AGENT_CLAUDE=${AGENT_CLAUDE}
AGENT_CODEX=${AGENT_CODEX}
AGENT_AGY=${AGENT_AGY}
OPT_PLAYWRIGHT=${OPT_PLAYWRIGHT}
OPT_FIXTURES=${OPT_FIXTURES}
OPT_ROSLYNMCP=${OPT_ROSLYNMCP}
OPT_UV=${OPT_UV}
OPT_ACT=${OPT_ACT}
OPT_SQLCMD=${OPT_SQLCMD}
OPT_DBCLIENTS=${OPT_DBCLIENTS}
OPT_LINT=${OPT_LINT}
OPT_SMOKE=${OPT_SMOKE}
EOF

printf '%s\n' "${REPOS[@]:-}" > "$REPOLIST"

# /run is tmpfs inside the guest, so none of this survives a reboot.
pct push "$CTID" "$ANSWERS"      /run/devlxc-answers.env --perms 600
pct push "$CTID" "$REPOLIST"     /run/devlxc-repos.txt   --perms 600
pct push "$CTID" "$GUEST_SCRIPT" /root/provision-devlxc.sh --perms 700

if [[ -n "$PAT_FILE" ]]; then
  pct push "$CTID" "$PAT_FILE" /run/gh-pat --perms 600
elif [[ -n "$GH_TOKEN_VALUE" ]]; then
  # Staged in the host's own tmpfs so the token never lands on disk, pushed
  # into the guest's tmpfs, then shredded from both ends.
  PATTMP="$(mktemp -p /dev/shm)"; chmod 600 "$PATTMP"
  printf '%s' "$GH_TOKEN_VALUE" > "$PATTMP"
  pct push "$CTID" "$PATTMP" /run/gh-pat --perms 600
  shred -u "$PATTMP"
  unset GH_TOKEN_VALUE
else
  echo ">> No PAT supplied, skipping GitHub auth (clones of private repos will fail)"
fi

echo ">> Provisioning (this takes a while)"
pct exec "$CTID" -- /bin/bash /root/provision-devlxc.sh

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"

echo
echo "==============================================="
echo " CT $CTID ready."
echo " Host: $CT_HOSTNAME    IP: ${IP:-unknown}    MAC: $MACADDR"
echo
echo " On your client, clear the stale host key first:"
echo "   ssh-keygen -R ${IP:-<ip>}"
echo "   ssh ${DEV_USER}@${IP:-<ip>}"
if [[ "$AGENT_CLAUDE" == true || "$AGENT_CODEX" == true || "$AGENT_AGY" == true ]]; then
  echo
  echo " Then log in (each prints a URL to open locally):"
  [[ "$AGENT_CLAUDE" == true ]] && echo "   claude    # Claude Code"
  [[ "$AGENT_CODEX"  == true ]] && echo "   codex     # Codex CLI"
  [[ "$AGENT_AGY"    == true ]] && echo "   agy       # Antigravity CLI"
fi
echo "==============================================="
