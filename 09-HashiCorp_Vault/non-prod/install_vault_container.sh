#!/bin/bash

# Install and run HashiCorp Vault in a Podman container on a non-production environment
set -euo pipefail
set -e

# -------- Helpers (color logging) --------
RED='\033[0;31m' # Errors
GREEN='\033[0;32m' # Success
YELLOW='\033[1;33m' # Warnings
BLUE='\033[0;34m' # Info
CYAN='\033[0;36m' # Questions
NC='\033[0m' # No Color (reset)

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $*"; }
ask()  { echo -e "${CYAN}[?]${NC} $*"; }

log "Installing Podman..."
sudo dnf install -y podman

log "Creating Vault directories..."
mkdir -p $HOME/vault-server/data/{certs,storage}
mkdir -p $HOME/vault-server/config

log "Generating self-signed TLS certificate..."
openssl req -new -newkey rsa:2048 -sha256 -days 3650 -nodes -x509 \
  -keyout $HOME/vault-server/data/certs/private.key \
  -out $HOME/vault-server/data/certs/public.crt \
  -subj "/C=SA/ST=Riyadh/L=Riyadh/O=Vault/OU=Dev/CN=localhost" \
  -addext "subjectAltName = DNS:localhost,IP:127.0.0.1"

log "Setting permissions..."
chmod 777 $HOME/vault-server/data/storage
chmod 744 $HOME/vault-server/data/certs/*.key
chmod 744 $HOME/vault-server/data/certs/*.crt

log "Creating Vault config file..."
cat <<EOF > $HOME/vault-server/config/config.hcl
ui = true
api_addr = "https://127.0.0.1:8200"
disable_mlock = true

storage "file" {
  path = "/data/storage"
}

listener "tcp" {
  address = "0.0.0.0:8200"
  tls_cert_file = "/data/certs/public.crt"
  tls_key_file  = "/data/certs/private.key"
}
EOF

log "Pulling Vault container image..."
podman pull docker.io/hashicorp/vault:latest

log "Removing any existing Vault container..."
podman rm -f vault >/dev/null 2>&1 || true

log "Running Vault container..."
podman run -d --name vault \
  -p 8200:8200 \
  --cap-add=IPC_LOCK \
  -v $HOME/vault-server/data:/data:Z \
  -v $HOME/vault-server/config:/config:Z \
  -e VAULT_LOCAL_CONFIG='@/config/config.hcl' \
  docker.io/hashicorp/vault:latest server -config=/config/config.hcl

log "Vault container started. Access it at https://localhost:8200"

log "Container status:"

sleep 2
podman ps -a --filter "name=vault"
podman logs -f vault

log ""
