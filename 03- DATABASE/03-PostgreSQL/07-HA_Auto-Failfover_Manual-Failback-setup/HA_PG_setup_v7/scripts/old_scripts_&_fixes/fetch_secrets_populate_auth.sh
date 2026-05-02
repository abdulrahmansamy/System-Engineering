#!/usr/bin/env bash
set -euo pipefail

# Config
PGPASS_FILE="/var/lib/postgresql/.pgpass"
PGBOUNCER_DIR="/etc/pgbouncer"
PGBOUNCER_USERLIST="${PGBOUNCER_DIR}/userlist.txt"
PG_PORT="${PG_PORT:-5432}"
PGBOUNCER_PORT="${PGBOUNCER_PORT:-6432}"
SECRET_CACHE_DIR="/run/pg-secrets"
mkdir -p "${SECRET_CACHE_DIR}"

# Helpers
metadata() {
  local key="$1"
  curl -sf -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/attributes/${key}" 2>/dev/null || echo ""
}

# Get OAuth token (no gcloud needed)
get_token() {
  curl -sf -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' \
    | jq -r '.access_token'
}

# Fetch secret payload from Secret Manager
# Args: name cache_filename secret_id
get_secret() {
  local name="$1" cache="${SECRET_CACHE_DIR}/${2}" sid="$3"
  if [[ -s "${cache}" ]]; then cat "${cache}"; return 0; fi
  local project_id
  project_id=$(curl -sf -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/project/project-id')

  local token
  token=$(get_token || echo "")
  [[ -z "${token}" ]] && { echo "ERR: token missing" >&2; return 1; }

  local url="https://secretmanager.googleapis.com/v1/projects/${project_id}/secrets/${sid}/versions/latest:access"
  local body
  body=$(curl -sf -H "Authorization: Bearer ${token}" -H 'Accept: application/json' "${url}") || return 1
  echo "${body}" | jq -r '.payload.data' | base64 -d | tee "${cache}" >/dev/null
}

# md5(username,password) for PgBouncer format md5<md5(password+username)>
md5_hash() {
  local user="$1" pass="$2"
  printf '%s%s' "$pass" "$user" | md5sum | awk '{print $1}'
}

# Read all secret ids from metadata (populated by Terraform)
declare -A SIDS=(
  [pg_superuser]="$(metadata pg_superuser_secret_id)"
  [pg_replication]="$(metadata pg_replication_secret_id)"
  [pg_monitor]="$(metadata pg_monitor_secret_id)"
  [pg_appuser]="$(metadata pg_appuser_secret_id)"
  [pg_wso2user]="$(metadata pg_wso2user_secret_id)"
  [pg_tmsuser]="$(metadata pg_tmsuser_secret_id)"
  [pg_examuser]="$(metadata pg_examuser_secret_id)"
  [pg_helpdeskuser]="$(metadata pg_helpdeskuser_secret_id)"
  [pg_konguser]="$(metadata pg_konguser_secret_id)"
  [pg_iparaguser]="$(metadata pg_iparaguser_secret_id)"  # present in secrets.tf variant
  [pgbouncer]="$(metadata pgbouncer_secret_id)"
)

# Retrieve secrets
declare -A PWS
for k in "${!SIDS[@]}"; do
  sid="${SIDS[$k]}"
  if [[ -n "$sid" ]]; then
    PWS[$k]="$(get_secret "$k" "${k}.txt" "$sid" || true)"
  else
    PWS[$k]="" # metadata key may be absent (optional users)
  fi
done

# Build .pgpass
install -o postgres -g postgres -m 600 /dev/null "${PGPASS_FILE}"
cat > "${PGPASS_FILE}" <<EOF
# .pgpass managed by fetch_secrets_populate_auth.sh
# host:port:database:user:password
*:${PG_PORT}:*:postgres:${PWS[pg_superuser]}
*:${PG_PORT}:*:repuser:${PWS[pg_replication]}
*:${PG_PORT}:*:monitor_user:${PWS[pg_monitor]}
*:${PG_PORT}:*:app_user:${PWS[pg_appuser]}
*:${PG_PORT}:*:wso2_user:${PWS[pg_wso2user]}
*:${PG_PORT}:*:tms_user:${PWS[pg_tmsuser]}
*:${PG_PORT}:*:exam_user:${PWS[pg_examuser]}
*:${PG_PORT}:*:helpdesk_user:${PWS[pg_helpdeskuser]}
*:${PG_PORT}:*:kong_user:${PWS[pg_konguser]}
*:${PG_PORT}:*:iparag_user:${PWS[pg_iparaguser]}
*:${PGBOUNCER_PORT}:*:postgres:${PWS[pg_superuser]}
*:${PGBOUNCER_PORT}:*:app_user:${PWS[pg_appuser]}
*:${PGBOUNCER_PORT}:*:wso2_user:${PWS[pg_wso2user]}
*:${PGBOUNCER_PORT}:*:tms_user:${PWS[pg_tmsuser]}
*:${PGBOUNCER_PORT}:*:exam_user:${PWS[pg_examuser]}
*:${PGBOUNCER_PORT}:*:helpdesk_user:${PWS[pg_helpdeskuser]}
*:${PGBOUNCER_PORT}:*:kong_user:${PWS[pg_konguser]}
*:${PGBOUNCER_PORT}:pgbouncer:pgbouncer_admin:${PWS[pgbouncer]}
EOF
chown postgres:postgres "${PGPASS_FILE}"
chmod 600 "${PGPASS_FILE}"

# Build PgBouncer userlist.txt
mkdir -p "${PGBOUNCER_DIR}"
install -o postgres -g pgbouncer -m 640 /dev/null "${PGBOUNCER_USERLIST}"

# Compute MD5 hashes only for present passwords
user_md5_line() {
  local user="$1" pass="$2"
  [[ -n "$pass" ]] && echo "\"${user}\" \"md5$(md5_hash "${user}" "${pass}")\""
}

{
  echo ";; PgBouncer MD5 Authentication (managed)"
  user_md5_line "postgres"        "${PWS[pg_superuser]}"
  user_md5_line "repuser"         "${PWS[pg_replication]}"
  user_md5_line "monitor_user"    "${PWS[pg_monitor]}"
  user_md5_line "app_user"        "${PWS[pg_appuser]}"
  user_md5_line "wso2_user"       "${PWS[pg_wso2user]}"
  user_md5_line "tms_user"        "${PWS[pg_tmsuser]}"
  user_md5_line "exam_user"       "${PWS[pg_examuser]}"
  user_md5_line "helpdesk_user"   "${PWS[pg_helpdeskuser]}"
  user_md5_line "kong_user"       "${PWS[pg_konguser]}"
  user_md5_line "iparag_user"     "${PWS[pg_iparaguser]}"
  user_md5_line "pgbouncer_admin" "${PWS[pgbouncer]}"
} > "${PGBOUNCER_USERLIST}"

chown postgres:pgbouncer "${PGBOUNCER_USERLIST}"
chmod 640 "${PGBOUNCER_USERLIST}"

echo "Secrets fetched and auth files updated:"
echo " - ${PGPASS_FILE}"
echo " - ${PGBOUNCER_USERLIST}"
