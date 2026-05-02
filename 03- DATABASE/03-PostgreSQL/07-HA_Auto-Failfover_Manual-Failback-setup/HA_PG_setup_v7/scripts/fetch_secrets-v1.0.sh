#!/usr/bin/env bash
set -euo pipefail

# Usage: fetch_secrets.sh <username> <secret_id> [--pg-port 5432] [--pgbouncer-port 6432] [--pg-hba-cidr 192.168.24.0/0] [--auth md5|scram-sha-256]
# Prints:
# - .pgpass lines for direct PG and PgBouncer (if ports provided)
# - PgBouncer userlist.txt line with md5<md5(password+username)>
# - pg_hba.conf line with host, database, username, CIDR, and auth-method

PG_PORT=5432
PGBOUNCER_PORT=6432
PG_HBA_CIDR="192.168.24.0/0"
AUTH_METHOD="md5"

# Parse args
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <username> <secret_id> [--pg-port 5432] [--pgbouncer-port 6432] [--pg-hba-cidr 192.168.24.0/0] [--auth md5|scram-sha-256]" >&2
  exit 1
fi

USERNAME="$1"
SECRET_ID="$2"
shift 2

if [[ -z "${SECRET_ID}" || "${SECRET_ID}" == "-" ]]; then
  echo "ERROR: Secret ID is empty or invalid. Provide a valid Secret Manager secret_id." >&2
  exit 2
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pg-port) PG_PORT="${2:-5432}"; shift 2 ;;
    --pgbouncer-port) PGBOUNCER_PORT="${2:-6432}"; shift 2 ;;
    --pg-hba-cidr) PG_HBA_CIDR="${2:-192.168.24.0/0}"; shift 2 ;;
    --auth)
      AUTH_METHOD="${2:-md5}"; shift 2
      case "${AUTH_METHOD}" in
        md5|scram-sha-256) ;;
        *) echo "ERROR: --auth must be 'md5' or 'scram-sha-256'." >&2; exit 1 ;;
      esac
      ;;
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
  local project_id token url body payload http_code
  project_id="$(get_project_id)"
  if [[ -z "${project_id}" ]]; then
    echo "ERROR: Could not resolve GCP project ID from metadata server." >&2
    exit 3
  fi

  token="$(get_token || true)"
  if [[ -z "${token}" ]]; then
    echo "ERROR: Could not obtain metadata OAuth token for service account." >&2
    exit 4
  fi

  url="https://secretmanager.googleapis.com/v1/projects/${project_id}/secrets/${SECRET_ID}/versions/latest:access"
  # Capture HTTP status code for better diagnostics
  body="$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer ${token}" -H 'Accept: application/json' "${url}")" || {
    echo "ERROR: Network or curl error while accessing Secret Manager for secret_id='${SECRET_ID}'." >&2
    exit 5
  }
  http_code="${body##*$'\n'}"
  body="${body%$'\n'*}"

  if [[ "${http_code}" != "200" ]]; then
    # Extract short error message if present
    local err_msg
    err_msg="$(echo "${body}" | jq -r '.error.message // empty' 2>/dev/null || true)"
    [[ -z "${err_msg}" ]] && err_msg="$(echo "${body}" | head -c 200)"
    echo "ERROR: Secret Manager access failed for secret_id='${SECRET_ID}' (HTTP ${http_code})." >&2
    echo "DETAILS: ${err_msg}" >&2
    echo "HINTS: Verify the secret ID, that a 'latest' version exists, and that the VM service account has roles/secretmanager.secretAccessor." >&2
    exit 5
  fi

  payload="$(echo "${body}" | jq -r '.payload.data // empty')"
  if [[ -z "${payload}" ]]; then
    echo "ERROR: Secret payload is empty or missing for secret_id='${SECRET_ID}'. Ensure a secret version is created." >&2
    exit 6
  fi

  if ! printf '%s' "${payload}" | base64 -d 2>/dev/null; then
    echo "ERROR: Failed to decode secret payload (base64) for secret_id='${SECRET_ID}'." >&2
    exit 7
  fi
}

md5_hash() {
  local user="$1" pass="$2"
  # PgBouncer uses md5 of password+username
  printf '%s%s' "$pass" "$user" | md5sum | awk '{print $1}'
}

PASSWORD="$(fetch_secret_value)" || {
  echo "ERROR: Could not fetch password for secret_id='${SECRET_ID}'. Aborting output." >&2
  exit 8
}

# Output helper lines
echo "# .pgpass lines:"
echo "*:${PG_PORT}:*:${USERNAME}:${PASSWORD}"
echo "*:${PGBOUNCER_PORT}:*:${USERNAME}:${PASSWORD}"
echo
if [[ "${AUTH_METHOD}" == "md5" ]]; then
  echo "# PgBouncer userlist.txt line:"
  echo "\"${USERNAME}\" \"md5$(md5_hash "${USERNAME}" "${PASSWORD}")\""
else
  echo "# PgBouncer userlist.txt line:"
  echo "Note: PgBouncer does not support SCRAM-SHA-256 userlist entries; skipping userlist line."
fi
echo
echo "# pg_hba.conf line:"
echo "host    all             ${USERNAME}       ${PG_HBA_CIDR}               ${AUTH_METHOD}"
