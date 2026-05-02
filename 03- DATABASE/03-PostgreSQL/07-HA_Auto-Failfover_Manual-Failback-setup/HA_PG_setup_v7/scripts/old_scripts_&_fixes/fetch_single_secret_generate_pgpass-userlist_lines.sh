#!/usr/bin/env bash
set -euo pipefail

# Usage: fetch_single_secret_generate_lines.sh <username> <secret_id> [--pg-port 5432] [--pgbouncer-port 6432]
# Prints:
# - .pgpass lines for direct PG and PgBouncer (if ports provided)
# - PgBouncer userlist.txt line with md5<md5(password+username)>

PG_PORT=5432
PGBOUNCER_PORT=6432

# Parse args
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <username> <secret_id> [--pg-port 5432] [--pgbouncer-port 6432]" >&2
  exit 1
fi

USERNAME="$1"
SECRET_ID="$2"
shift 2

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pg-port) PG_PORT="${2:-5432}"; shift 2 ;;
    --pgbouncer-port) PGBOUNCER_PORT="${2:-6432}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Helpers
get_project_id() {
  curl -sf -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/project/project-id'
}

get_token() {
  curl -sf -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' \
    | jq -r '.access_token'
}

fetch_secret_value() {
  local project_id token url body
  project_id="$(get_project_id)"
  token="$(get_token || true)"
  if [[ -z "${token}" ]]; then
    echo "ERROR: Could not obtain metadata token" >&2
    exit 1
  fi
  url="https://secretmanager.googleapis.com/v1/projects/${project_id}/secrets/${SECRET_ID}/versions/latest:access"
  body="$(curl -sf -H "Authorization: Bearer ${token}" -H 'Accept: application/json' "${url}")"
  echo "${body}" | jq -r '.payload.data' | base64 -d
}

md5_hash() {
  local user="$1" pass="$2"
  # PgBouncer uses md5 of password+username
  printf '%s%s' "$pass" "$user" | md5sum | awk '{print $1}'
}

PASSWORD="$(fetch_secret_value)"

# Output helper lines
echo "# .pgpass lines:"
echo "*:${PG_PORT}:*:${USERNAME}:${PASSWORD}"
echo "*:${PGBOUNCER_PORT}:*:${USERNAME}:${PASSWORD}"
echo
echo "# PgBouncer userlist.txt line:"
echo "\"${USERNAME}\" \"md5$(md5_hash "${USERNAME}" "${PASSWORD}")\""
