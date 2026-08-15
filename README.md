# devlxc

Two scripts that build a disposable Fedora development container on Proxmox VE,
with a .NET and Node toolchain and a working rootless Podman runtime for
Testcontainers.

Rebuild it whenever it drifts. Nothing inside is precious.

## What you get

A Fedora LXC with:

- **.NET SDK 10** from Fedora's own repositories, no Microsoft feed
- **Node.js 22** from NodeSource
- **Rootless Podman** with `DOCKER_HOST` set, so Testcontainers and other
  Docker-speaking tooling work without a root daemon
- **GitHub CLI**, authenticated, with git configured to use it as a credential
  helper
- `tmux`, `ripgrep`, `vim`, `rsync`, `ncdu`, `htop`, `bash-completion`
- Optional: Claude Code, Codex CLI, Antigravity CLI, `act`, `sqlcmd`, `sqlite3`
  and `psql`, `shellcheck` and `hadolint`, `uv`, Playwright, and a
  PDF/spreadsheet inspection toolchain
- Your repositories cloned and bootstrapped

Nothing personal is baked in. Username, git identity, timezone, tooling and
repositories are all prompted for at build time.

## Requirements

- Proxmox VE with a Fedora LXC template available via `pveam`
- Root on the Proxmox host
- A GitHub personal access token with `repo` and `read:org` scopes

`read:org` is not optional. `gh auth login --with-token` validates it even when
you only intend to use the token for git operations, and rejects tokens without
it.

## Usage

Both scripts must sit in the same directory. The host script looks for its
sibling.

```bash
git clone https://github.com/<you>/devlxc.git
cd devlxc
chmod +x create-devlxc.sh provision-devlxc.sh
./create-devlxc.sh
```

You will be prompted for the container username and password, your GitHub PAT,
timezone, git commit identity, which agent CLIs to install, which optional tools
to include, and the repositories to clone.

To rebuild an existing container from scratch:

```bash
DESTROY=1 CTID=100 ./create-devlxc.sh
```

This destroys everything in the container. Commit your work first.

### Skipping prompts

Any configuration value can come from the environment instead:

```bash
DEV_USER=me GIT_USER_NAME=me GIT_USER_EMAIL=me@example.com ./create-devlxc.sh
```

Set `PAT_FILE=/root/.secrets/github-pat` to read the token from a file rather
than pasting it. By default the token is never written to disk on either the
host or the guest: it is staged in `/dev/shm`, pushed into the guest's `/run`
tmpfs, consumed by `gh`, and shredded from both.

### Configuration

Override at the command line or edit the block at the top of
`create-devlxc.sh`.

| Variable | Default | Notes |
|---|---|---|
| `CTID` | next free | |
| `CT_HOSTNAME` | `devlxc` | |
| `CT_STORAGE` | `local-lvm` | Check yours with `pvesm status` |
| `TPL_STORAGE` | `local` | Where LXC templates live |
| `DISK_GB` | `64` | 40 is the practical floor |
| `CORES` | `4` | |
| `MEMORY_MB` | `8192` | A cgroup ceiling, not a reservation |
| `SWAP_MB` | `4096` | Absorbs build spikes instead of an OOM kill |
| `CPUUNITS` | `50` | Lower than your other guests, so they win contention |
| `BRIDGE` | `vmbr0` | |
| `MACADDR` | `BC:24:11:DE:00:01` | Fixed, so a DHCP reservation sticks |
| `UNPRIVILEGED` | `1` | Set `0` to skip the ID map work entirely |

## How it works

The split is by privilege, not by concern.

`create-devlxc.sh` runs on the Proxmox host. It asks every question up front on
a real terminal, writes the answers to a file, creates the container with the
right features and ID map, pushes the answers and the guest script in, and
executes it.

`provision-devlxc.sh` runs inside the container as root. It is non-interactive
and idempotent, reading its configuration from `/run/devlxc-answers.env` and
`/run/devlxc-repos.txt`. It is also standalone: write those two files yourself
and it will provision any Fedora host, container or not.

Moving all interactivity to the host half means you get real prompts and a
clean unattended provision, and the guest script stays portable.

## The LXC-specific parts

Running rootless Podman inside an unprivileged LXC needs four things that are
easy to miss. Each fails in a way that does not point at its own cause.

**`nesting=1` and `keyctl=1`.** Set at container creation. Without `keyctl`,
SQL Server's testcontainer fails at startup with an error that says nothing
about keyrings.

**A widened ID map.** The default unprivileged container maps 65536 IDs.
Rootless Podman wants a 65536-wide subuid range for one user, which collides
with that ceiling. The script writes a 200000-wide `lxc.idmap` and extends the
host's `/etc/subuid` and `/etc/subgid` to match.

**A subuid range that fits.** Fedora's `useradd` allocates subordinate IDs
starting at 524288, which is outside the container's ID range no matter how
wide you make it. The provisioner rewrites the entry rather than only adding one
when absent. Symptom if missed:

```
newuidmap: write to uid_map failed: Operation not permitted
```

**`/dev/fuse` and `/dev/net/tun` bound in from the host.** `fuse-overlayfs`
needs the first; `pasta` and `slirp4netns` both need the second to build the
container network. Symptom if missed:

```
pasta failed with exit code 1: Failed to open() /dev/net/tun
```

If you would rather not deal with any of this, set `UNPRIVILEGED=0`, or use a
VM. A VM has its own kernel and none of these four apply.

## Deliberate choices

**Fedora, not Debian.** .NET 10 is in Fedora's own repositories, so no
third-party feed is needed, and Podman ships newer on the distribution that
develops it. Both of this project's hardest dependencies are first-class there.

**`go-sqlcmd`, not `mssql-tools18`.** The packaged tools only come from
`packages.microsoft.com`, whose repository also carries .NET builds that collide
with Fedora's. `go-sqlcmd` is a single static binary with no repository and no
conflict. You lose `bcp`.

**Agents install but do not authenticate.** Claude Code, Codex and Antigravity
all use interactive OAuth. Their credentials could be pre-seeded, but Codex
rotates its tokens during normal use, so a saved copy goes stale. Logging in
once after SSH is less work than maintaining exports.

**SELinux is disabled in the config.** Not a security decision. SELinux is
enforced by the kernel, and an LXC guest shares the Proxmox host's kernel, which
loads AppArmor and no SELinux policy. Fedora's SELinux userspace has nothing to
enforce with either way; the config change only stops the noise.

## Notes

The container does not have its own kernel. Nothing inside can load modules,
`uname -r` reports the Proxmox kernel version, and `dnf upgrade` should be rare:
if the container feels stale, rebuild it rather than upgrading in place, or you
have quietly recreated the long-lived box you were trying to avoid.

Claude Code updates itself. Codex and Antigravity update by re-running their
installers. Everything else updates on the next rebuild.

## Licence

MIT
