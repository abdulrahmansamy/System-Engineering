# sync_on_change

A lightweight bash tool that watches a local file or directory for content changes and automatically syncs it to a remote host over SSH.

---

## Features

- Detects file/directory changes via SHA-256 checksum comparison
- Syncs files via `scp`; directories via `rsync` (with `tar+scp` fallback)
- Sets remote executable permissions automatically after each sync
- Animated progress indicator while idle (dots)
- Tracks consecutive failures and aborts after a configurable threshold
- Self-installs to `/usr/local/bin` as `sync_on_change` for system-wide use
- Supports external config files with per-variable source reporting
- Generates an example config file on demand

---

## Installation

### One-time install into PATH

```bash
./sync_on_change_v1.8.3.sh --install
```

After installation, run it from anywhere as:

```bash
sync_on_change <file|directory>
```

### Update installed binary

```bash
./sync_on_change_v1.8.3.sh --update
```

### Remove from PATH

```bash
sync_on_change --uninstall
```

---

## Usage

```
sync_on_change <file|directory> [options]
sync_on_change --install | --update | --uninstall | --gen-config
```

### Arguments

| Argument | Description |
|---|---|
| `<file\|directory>` | Local file or directory to watch and sync |
| `-c <config-file>` | Explicit config file path (disables fallback search) |
| `-v`, `--verbose` | Enable verbose debug output |
| `--version` | Print version and exit |
| `-h`, `--help` | Show help |

### PATH Management

| Flag | Description |
|---|---|
| `--install` | Install to `/usr/local/bin/sync_on_change` |
| `--update` | Overwrite the installed binary with the current version |
| `--uninstall` | Remove from `/usr/local/bin` |

### Configuration

| Flag | Description |
|---|---|
| `--gen-config` | Write `.sync_on_change.conf.example` to the current directory and exit |

---

## Quick Start

**1. Generate an example config:**

```bash
sync_on_change --gen-config
```

This writes `.sync_on_change.conf.example` to your current directory.

**2. Fill in your remote details:**

```bash
mv .sync_on_change.conf.example .sync_on_change.conf
vi .sync_on_change.conf
```

**3. Start watching:**

```bash
sync_on_change deploy.sh
```

---

## Configuration

Config files use plain `key=value` bash syntax.

### Config file locations (first found wins)

| Priority | Path |
|---|---|
| 1 | `-c <path>` explicit flag |
| 2 | `$PWD/.sync_on_change.conf` |
| 3 | `<script_dir>/.sync_on_change.conf` |
| 4 | `<watched_file_dir>/sync_on_change.conf` |
| 5 | `/etc/sync_on_change/sync_on_change.conf` |
| 6 | Built-in defaults |

> When `-c` is used, no fallback search occurs — the specified file must exist.

### Available variables

```bash
# --- Remote Connection ---
remote_user="youruser"        # SSH username
remote_host="your.host.ip"   # SSH hostname or IP
remote_path="~/scripts/"     # Destination path on the remote host

# --- Behaviour ---
interval=3                    # Polling interval in seconds (default: 3)
max_failures=10               # Abort after this many consecutive failures (default: 10)
```

On startup, a config source table is printed showing where each variable came from:

```
[i] Configuration sources:
  remote_user    = asamy                     (from: /home/user/.sync_on_change.conf)
  remote_host    = 172.16.42.182             (from: /home/user/.sync_on_change.conf)
  remote_path    = ~/scripts/               (from: /home/user/.sync_on_change.conf)
  interval       = 3                         (from: default)
  max_failures   = 10                        (from: default)
```

---

## SSH Setup

On first run, the script checks whether SSH key authentication is already working for the target host:

- **Key auth working** → proceeds immediately
- **Key auth not set up** → runs `ssh-copy-id` to install your public key, then re-verifies
- **Host unreachable** → `ssh-copy-id` fails → script aborts with a clear error

Your SSH key (`~/.ssh/id_*.pub`) must exist. Generate one if needed:

```bash
ssh-keygen -t ed25519
```

---

## How It Works

```
┌─────────────────────────────────────────────────┐
│                   Startup                       │
│  set_defaults → parse_args → install prompt     │
│  → load_config → config prompt → validate       │
│  → print sources → ssh_setup → watch summary    │
│  → initial_sync                                 │
└──────────────────────┬──────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────┐
│                  Main Loop                      │
│                                                 │
│  ┌──────────────────────────────────────────┐   │
│  │  Calculate SHA-256 checksum of target    │   │
│  └──────────────┬───────────────────────────┘   │
│                 │                               │
│        ┌────────▼────────┐                      │
│        │ Changed?        │                      │
│        └──┬──────────┬───┘                      │
│           │ YES      │ NO                       │
│           ▼          ▼                          │
│      sync_target   animate dots                 │
│      (scp / rsync)  (wait interval)             │
│           │                                     │
│           ├── success → reset fail_count        │
│           └── failure → fail_count++            │
│                         if >= max_failures: die │
└─────────────────────────────────────────────────┘
```

### Checksum-based change detection

Every `interval` seconds, a SHA-256 hash of the target is computed:

- **File**: `openssl dgst -sha256 <file>`
- **Directory**: recursive hash of all files via `find | openssl`

If the hash differs from the previous cycle, a sync is triggered.

### Sync methods

| Target type | Primary | Fallback |
|---|---|---|
| File | `scp` | — |
| Directory | `rsync -az --delete` | `tar + scp`, then remote `tar -xzf` |

After a successful sync, the script runs `chmod +x` on the remote target (all `.sh` files for directories).

### Failure tracking

Each failed sync increments `fail_count`. On success it resets to `0`. When `fail_count >= max_failures`, the script calls `die` and exits.

---

## Examples

Watch a single script and sync it on every save:

```bash
sync_on_change deploy.sh
```

Watch a directory with an explicit config:

```bash
sync_on_change ./scripts/ -c ~/myproject/.sync_on_change.conf
```

Run verbosely to see debug output:

```bash
sync_on_change deploy.sh -v
```

Use with a config file in a non-standard location:

```bash
sync_on_change deploy.sh -c /etc/myteam/sync.conf
```

---

## Output Legend

| Prefix | Meaning |
|---|---|
| `[+]` | Success / action completed |
| `[!]` | Warning |
| `[x]` | Fatal error (script exits) |
| `[i]` | Informational |
| `[?]` | Interactive prompt |
| `[*]` | Debug (only with `-v`) |
| `[>]` | Monitoring animation (idle) |

---

## Requirements

| Tool | Purpose |
|---|---|
| `bash` | Shell interpreter |
| `ssh` / `scp` | Remote connection and file transfer |
| `ssh-copy-id` | Initial SSH key setup |
| `openssl` | SHA-256 checksum calculation |
| `rsync` | Directory sync (optional; falls back to tar+scp) |
| `find` | Directory checksum and remote chmod |

---

## Changelog

### v1.8.3
- Replaced individual logging functions with a unified `log()` dispatcher
- Added `success()`, `error()` levels; `log <level> <msg>` call style now supported
- Thin convenience wrappers (`info`/`warn`/`die`/`debug`/etc.) preserved for compatibility
- Fixed bare `log()` calls with no level (`ssh_setup`, `initial_sync`, `check_deps`) that produced blank log lines — replaced with explicit `info()` calls
- Fixed `SCRIPT_NAME` derivation: now strips `_v<version>.sh` suffix dynamically instead of a hardcoded string

### v1.8.2
- Added `check_deps()`: detects OS package manager and installs missing prerequisites
- Added `--check-deps` flag to verify/install dependencies without starting a sync

### v1.8.1
- Fixed `SCRIPT_NAME` to always install as `sync_on_change` (strips version suffix)
- Extracted `print_watch_summary()` function

### v1.8.0
- Clean release combining all fixes from v1.6 → v1.7.x
- Fixed `ssh_setup`: `ssh-copy-id` and `mkdir -p` failures now abort the script
- Added post-`ssh-copy-id` re-verification of key auth
- Added `--gen-config` flag: writes `.sync_on_change.conf.example` to `$PWD` and exits
- Extracted `gen_example_config()` as standalone reusable function

---

## License

MIT License — Copyright (c) 2025 Abdulrahman Samy
