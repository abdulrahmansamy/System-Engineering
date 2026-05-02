#!/bin/bash
# Enhanced PgBouncer configuration with separate admin user
# This creates a dedicated pgbouncer_admin user with limited privileges

create_dedicated_pgbouncer_admin() {
  info "Creating dedicated PgBouncer admin user with limited privileges"
  
  # Create a dedicated pgbouncer admin user in PostgreSQL
  sudo -u postgres psql -c "
    DO \$\$
    BEGIN
      -- Create pgbouncer_admin user if it doesn't exist
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgbouncer_admin') THEN
        CREATE ROLE pgbouncer_admin WITH LOGIN PASSWORD '${PGBOUNCER_PASSWORD}';
        
        -- Grant minimal required permissions for PgBouncer admin
        GRANT CONNECT ON DATABASE postgres TO pgbouncer_admin;
        GRANT CONNECT ON DATABASE ${REPMGR_DB} TO pgbouncer_admin;
        
        -- Allow basic monitoring queries (optional)
        GRANT pg_monitor TO pgbouncer_admin;
      END IF;
    END
    \$\$;
  " postgres || warn "Failed to create PgBouncer admin user"
  
  # Update PgBouncer configuration to use dedicated admin user
  sed -i "s/admin_users = postgres/admin_users = pgbouncer_admin/" "$PGBOUNCER_CONF_FILE"
  sed -i "s/stats_users = postgres/stats_users = pgbouncer_admin/" "$PGBOUNCER_CONF_FILE"
  
  # Add to userlist.txt
  local admin_md5
  admin_md5=$(echo -n "${PGBOUNCER_PASSWORD}pgbouncer_admin" | md5sum | cut -d' ' -f1)
  echo "\"pgbouncer_admin\" \"md5${admin_md5}\"" >> "$PGBOUNCER_USERLIST_FILE"
  
  # Update .pgpass for pgbouncer admin
  cat >> "/var/lib/postgresql/.pgpass" << EOF

# PgBouncer admin user entries
localhost:6432:pgbouncer:pgbouncer_admin:${PGBOUNCER_PASSWORD}
*:6432:pgbouncer:pgbouncer_admin:${PGBOUNCER_PASSWORD}
EOF

  info "✓ Created dedicated PgBouncer admin user with separate password"
}