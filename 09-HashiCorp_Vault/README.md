# HashiCorp Vault Podman Automation

Single-node (developer / small prod) Vault deployment automated with Podman.

Primary script:
```
prod/install_vault_container_prod-moduler-version-clean-working.sh
```

## 1. What It Does
1. Installs Podman (if missing) and optionally Vault CLI.
2. Creates directory structure under `$HOME/vault-server`.
3. Generates or reuses a self-signed TLS certificate.
4. Optionally trusts the cert system-wide.
5. Applies secure permissions (falls back to permissive if required).
6. Writes `config.hcl` (file storage backend + TLS listener).
7. Optionally validates config (`-check-config`).
8. Opens firewall ports (unless disabled).
9. Starts / replaces the container.
10. Polls health endpoint and prints status (sealed / uninitialized hints).

## 2. Quick Start (Non-Interactive)
```bash
TRUST_CERT=1 INSTALL_CLI=1 ./prod/install_vault_container_prod-moduler-version-clean-working.sh
```

If you did NOT trust the cert:
```bash
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_SKIP_VERIFY=1   # Dev only; prefer --cacert
```

## 3. Initialize & Unseal
```bash
vault operator init          # Save unseal keys + root token securely
vault operator unseal        # Repeat until unsealed (usually 3 keys)
vault status
```

## 4. Core Environment Variables
| Variable | Purpose | Default |
|----------|---------|---------|
| VAULT_VERSION | Vault image tag | latest |
| VAULT_PORT | API listen port | 8200 |
| VAULT_CLUSTER_PORT | Cluster port | 8201 |
| VAULT_API_ADDR | Advertised API address | https://127.0.0.1:8200 |
| INSTALL_CLI | Auto install Vault CLI (1=yes) | 0 |
| TRUST_CERT / TRUST_VAULT_CERT | Auto trust self-signed cert | 0 |
| PERMISSIVE_STORAGE | Force wide-open perms | 0 |
| FIREWALL_DISABLE | Skip firewalld updates | 0 |
| CHECK_VAULT_CONFIG | Run `-check-config` | 1 |

## 5. Directory Layout
```text
$HOME/vault-server/
  data/
    certs/
      public.crt
      private.key
    storage/          (file storage backend)
  config/
    config.hcl
```
Container mounts:
```
/data   -> data + certs
/config -> configuration
```

## 6. Health & Status
```bash
curl --cacert $HOME/vault-server/data/certs/public.crt https://127.0.0.1:8200/v1/sys/health
# Dev only:
curl -k https://127.0.0.1:8200/v1/sys/health
podman logs vault | head
podman exec vault vault status -tls-skip-verify
```
Codes:
```
501 = uninitialized (run vault operator init)
503 = sealed (run vault operator unseal)
```

## 7. Updating Vault
```bash
VAULT_VERSION=1.20.2 ./prod/install_vault_container_prod-moduler-version-clean-working.sh
```
(omit VAULT_VERSION to keep using `latest`)

## 8. Clean Removal
Manual:
```bash
podman rm -f vault
rm -rf $HOME/vault-server   # irreversible
```
Script (recommended):
```bash
./clean_vault_script.sh          # interactive
./clean_vault_script.sh -f       # force all removals
CLEAN_IMAGE=1 CLEAN_CLI=1 ./clean_vault_script.sh -f
```

## 9. Security Notes
- Replace self-signed cert with CA-issued cert for real environments.
- File storage backend = single-node; switch to Raft or external backend for HA.
- Avoid `PERMISSIVE_STORAGE=1` outside local dev.
- Protect unseal keys & root token (never commit).
- Prefer explicit Vault versions (pin `VAULT_VERSION`).

## 10. Troubleshooting
| Symptom | Action |
|---------|--------|
| Startup timeout | `podman logs vault` (check TLS, perms, mlock) |
| Cert verify errors | Re-run with `TRUST_CERT=1` or use `--cacert` |
| Port in use | `ss -tulnp | grep ':8200'` then free or override `VAULT_PORT` |
| 501 health | Initialize (`vault operator init`) |
| 503 health | Unseal (`vault operator unseal`) |

## 11. Auxiliary / Legacy Scripts
### Root-level helper:
- sync_on_change_clean.sh — Single-file watcher (SHA-256 hash polling); on change: scp to remote, chmod +x.

#### `sync_on_change_clean.sh` usage:
```bash
./sync_on_change_clean.sh <local-file> [-c <config-file>] [-h]

# Examples:
./sync_on_change_clean.sh prod/install_vault_container_prod-moduler-version-clean-working.sh
./sync_on_change_clean.sh prod/install_vault_container_prod-moduler-version-clean-working.sh -c ./sync_on_change.conf
```

Configuration precedence (first found wins):
1. -c <config-file> (explicit; must exist; no fallback if given)
2. <script_dir>/sync_on_change.conf
3. $PWD/.sync_on_change.conf
4. <script_dir>/.sync_on_change.conf
5. <watched_file_dir>/.sync_on_change.conf

Overridable variables:
remote_user, remote_host, remote_path, interval, max_failures

Startup prints a sourced-from report for each variable (default vs file).

To customize:
1. Create a config (e.g. sync_on_change.conf) with variable assignments.
2. Place it beside the script OR pass via -c.
3. Run the watcher; verify the “Configuration sources” section.

Minimal config example:
```bash
remote_user="asamy"
remote_host="172.16.42.174"
remote_path="~/vault-scripts/"
interval=2
max_failures=15
```

### Legacy / experimental (in `prod/.trash/`):
- Various earlier installer iterations (alternative TLS, Raft examples, dynamic port logic).
- sync_on_change.sh (older watcher variant).



## 12. Example Manual Health Check
```bash
curl --cacert $HOME/vault-server/data/certs/public.crt https://127.0.0.1:8200/v1/sys/health
```

## 13. Minimal Workflow
```text
Run script → init → unseal → set VAULT_ADDR → use
```

---
For production: harden TLS, use Raft or HA backend, manage unseal keys securely, pin versions.
