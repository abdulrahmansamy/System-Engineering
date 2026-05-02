# install-docker-fedora

A hardened Bash script to **install** or **uninstall** Docker Engine on Fedora, with full support for both the legacy `dnf` (Fedora < 39) and the modern `dnf5` (Fedora 39+) package managers.

---

## Features

- Detects Fedora version and automatically selects `dnf` or `dnf5`
- Downloads the official Docker CE repository file via `curl` (works on all Fedora releases)
- Installs Docker Engine, CLI, containerd, Buildx, and Compose plugin
- Enables and starts `docker.service` via systemd
- Optionally adds a user to the `docker` group (with group existence check and duplicate-member guard)
- Validates the installation end-to-end using `hello-world`
- Full **uninstall** mode: stops/disables the service, removes packages and the repo file
- Optional `--purge` flag to also wipe `/var/lib/docker` and `/var/lib/containerd`
- Structured, timestamped, color-coded log output
- Fails fast with clear error messages at every step

---

## Requirements

| Requirement | Details |
|---|---|
| OS | Fedora (any release) |
| Privileges | Must be run as `root` (`sudo`) |
| Network | Internet access to `download.docker.com` |

---

## Usage

```bash
sudo ./install-docker-fedora_v1.5.sh [COMMAND] [OPTIONS]
```

### Commands

| Command | Description |
|---|---|
| `install` | Install Docker Engine *(default if omitted)* |
| `uninstall` | Stop, disable, and remove Docker Engine |

### Options

| Option | Description |
|---|---|
| `--add-user <user>` | Add `<user>` to the `docker` group after install |
| `--purge` | *(uninstall only)* Also remove `/var/lib/docker` and `/var/lib/containerd` |
| `-h`, `--help` | Show help message and exit |

---

## Examples

```bash
# Install Docker (default)
sudo ./install-docker-fedora_v1.5.sh

# Install and add a user to the docker group
sudo ./install-docker-fedora_v1.5.sh install --add-user alice

# Uninstall Docker (keep data directories)
sudo ./install-docker-fedora_v1.5.sh uninstall

# Uninstall Docker and wipe all data
sudo ./install-docker-fedora_v1.5.sh uninstall --purge
```

---

## What the Script Does

### `install`

| Step | Description |
|---|---|
| 1 | Validates root privileges |
| 2 | Validates Fedora OS and reads `VERSION_ID` |
| 3 | Installs `curl` as a prerequisite |
| 4 | Downloads `docker-ce.repo` to `/etc/yum.repos.d/` (skips if already present) |
| 5 | Installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin` |
| 6 | Enables and starts `docker.service` |
| 7 | *(optional)* Creates `docker` group if missing, checks for existing membership, then runs `usermod -aG docker <user>` |
| 8 | Validates `docker --version` |
| 9 | Validates Docker Engine runtime with `docker run --rm hello-world` |

### `uninstall`

| Step | Description |
|---|---|
| 1 | Stops `docker.service` (if active) |
| 2 | Disables `docker.service` (if enabled) |
| 3 | Removes all Docker packages |
| 4 | Removes `/etc/yum.repos.d/docker-ce.repo` |
| 5 | Reloads systemd units |
| 6 | *(with `--purge`)* Removes `/var/lib/docker` and `/var/lib/containerd` |

---

## Fedora Version Compatibility

| Fedora Release | Package Manager | Repo Method |
|---|---|---|
| ≤ 38 | `dnf` (dnf4) | `curl` download to `/etc/yum.repos.d/` |
| ≥ 39 | `dnf5` | `curl` download to `/etc/yum.repos.d/` |

Both code paths use `curl` to fetch the repo file directly, avoiding any `config-manager` plugin incompatibilities between `dnf4` and `dnf5`.

---

## Log Levels

| Level | Color | Prefix | Stream |
|---|---|---|---|
| `info` | Blue | `[i]` | stdout |
| `success` | Green | `[+]` | stdout |
| `warn` | Yellow | `[!]` | stderr |
| `error` | Red | `[x]` | stderr |
| `debug` | Magenta | `[*]` | stdout |
| `trace` | White | `[>]` | stdout |
| `silent` | Gray | `[-]` | stdout |

All log entries include a UTC timestamp in ISO 8601 format: `[YYYY-MM-DDTHH:MM:SSZ]`.

---

## Notes

- After adding a user to the `docker` group, a **re-login** (or `newgrp docker`) is required for the group change to take effect.
- The `--purge` flag is **irreversible** — all container images, volumes, and networks stored under `/var/lib/docker` will be permanently deleted.
- The script exits immediately on any unexpected error (`set -euo pipefail`).
