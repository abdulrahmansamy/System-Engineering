# Validation Guide — PostgreSQL HA on GCP (Terraform)

This guide walks you through validating the deployment end-to-end and testing failover/failback behavior.

## Before you start
- Ensure terraform apply completed successfully.
- You can SSH to pg-primary, pg-secondary, and pg-monitor.
- psql is available (installed on nodes). Keep terraform outputs handy:
```bash
terraform output
```

## 1) Infrastructure and DNS
- Verify reserved IPs and ILB VIP match outputs (primary_ip, secondary_ip, monitor_ip, ilb_ip, vip_ip).
- Check DNS A records resolve internally:
```bash
dig +short pg-primary.<your-private-zone>
dig +short pg-secondary.<your-private-zone>
dig +short pg-monitor.<your-private-zone>
dig +short pg-vip.<your-private-zone>
```
- Confirm firewall allows internal 5432, 5431, 6432, 8008.

## 2) OS hardening baseline
On any node:
```bash
sudo ufw status verbose
systemctl status fail2ban auditd apparmor
sudo sysctl -a | egrep 'rp_filter|tcp_syncookies|file-max|vm.swappiness'
ls -ld /var/log/journal || true
```

## 3) TLS and secrets
On a data node:
```bash
sudo ls -l /etc/ssl/pg/
sudo openssl x509 -in /etc/ssl/pg/server.crt -noout -subject -issuer -dates -ext subjectAltName
sudo stat -c '%a %n' /etc/ssl/pg/server.key /etc/ssl/pg/server.crt /etc/ssl/pg/ca.crt
```
Expect CN/SANs for the node FQDN and proper key perms (600).

## 4) PostgreSQL and replication
On primary:
```bash
psql -Atc "select version();"
psql -Atc "show synchronous_commit;"
psql -Atc "show wal_level;"
psql -Atc "show archive_mode;"
psql -Atc "select application_name, state, sync_state from pg_stat_replication;"
```
On secondary:
```bash
psql -Atc "select pg_is_in_recovery();"
psql -Atc "select status from pg_stat_wal_receiver;"
```
Expect one sync standby and synchronous_commit=remote_apply.

## 5) pg_auto_failover
On monitor:
```bash
sudo -u postgres pg_autoctl show state
sudo -u postgres pg_autoctl show settings --formation default
cat /opt/pg-ha/monitor_uri.txt
```
Expect two nodes in the default formation: one primary, one secondary.

## 6) Health endpoint and ILB routing
- Health endpoint returns PRIMARY only on the leader:
```bash
curl http://<primary-node-ip>:8008
curl http://<secondary-node-ip>:8008  # should not return PRIMARY
```
- Connect via VIP through PgBouncer (6432) and verify you hit the primary:
```bash
psql "host=pg-vip.<your-private-zone> port=6432 user=postgres sslmode=require" -Atc "select inet_server_addr(), pg_is_in_recovery();"
```
Expect pg_is_in_recovery = f (primary) through VIP.

## 7) Backups
On a data node:
```bash
sudo -u postgres pgbackrest --stanza=main check --log-level-console=info
systemctl list-timers '*pgbackrest*'
cat /var/log/pg-ha/pgbackrest-backup.log | tail -n 100
mount | grep pgbackrest || grep gcsfuse /etc/fstab
```
Optionally run a manual backup on the secondary:
```bash
sudo -u postgres pgbackrest --stanza=main --type=incr backup --log-level-console=info
```

## 8) Monitoring
Check Ops Agent:
```bash
systemctl status google-cloud-ops-agent
sudo cat /etc/google-cloud-ops-agent/config.yaml
journalctl -u google-cloud-ops-agent --no-pager -n 100
```
Confirm logs and metrics appear in Cloud Logging/Monitoring.

---

# Failover and Failback Validation Scenarios

## Scenario A: Manual switchover (no data loss)
Goal: Verify controlled switchover with synchronous replication (RPO=0).

Steps:
1) On monitor, trigger switchover:
```bash
sudo -u postgres pg_autoctl perform switchover --formation default
```
2) Watch state converge:
```bash
sudo -u postgres pg_autoctl show state --watch
```
3) Verify health endpoint flips to the new primary and VIP routes correctly:
```bash
curl http://<old-primary-ip>:8008      # should no longer be PRIMARY
curl http://<new-primary-ip>:8008      # should be PRIMARY
psql "host=pg-vip.<your-private-zone> port=6432 user=postgres sslmode=require" -Atc "select pg_is_in_recovery();"
```
4) Write/read check through VIP:
```bash
psql "host=pg-vip.<your-private-zone> port=6432 user=postgres sslmode=require" -c "create table if not exists ha_smoke(id int primary key); insert into ha_smoke values (extract(epoch from now())::int) on conflict do nothing;"
```
5) Confirm replication on standby (connect directly to the other node):
```bash
psql -Atc "select count(*) from ha_smoke;"
```
Expected outcome: Switchover completes, VIP targets the new primary, data visible on both nodes.

## Scenario B: Failure-driven failover
Goal: Verify automatic failover when the primary stops.

Steps:
1) On current primary, simulate failure:
```bash
sudo systemctl stop pgautofailover-node || sudo systemctl stop postgresql
```
2) On monitor, observe election:
```bash
sudo -u postgres pg_autoctl show state --watch
```
3) Validate VIP and health endpoint point to the survivor.
4) Restore the failed node:
```bash
sudo systemctl start pgautofailover-node || sudo systemctl start postgresql
```
Expected outcome: Secondary promotes to primary; failed node re-joins as secondary.

## Scenario C: Automatic failback to original primary
Goal: Validate the monitor’s failback orchestrator.

Preconditions:
- Original pg-primary is back online as secondary.
- Replication is synchronous (primary has pg-primary listed as synchronous standby).

Steps:
1) On monitor, tail the orchestrator log:
```bash
sudo tail -f /var/log/pg-ha/failback.log
```
2) Wait for stabilization window (default 3 consecutive checks and 10 min cooldown) and observe automatic switchover back to pg-primary.
3) Confirm with:
```bash
sudo -u postgres pg_autoctl show state
curl http://pg-primary.<your-private-zone>:8008
psql "host=pg-vip.<your-private-zone> port=6432 user=postgres sslmode=require" -Atc "select pg_is_in_recovery();"
```
Expected outcome: Primary role returns to pg-primary automatically once healthy and synchronous.

---

## Troubleshooting pointers
- Bootstrap and provisioning: /var/log/pg-ha/bootstrap.log
- Auto-failover node/monitor: journalctl -u pgautofailover-* | tail -n 200
- Failback orchestrator: /var/log/pg-ha/failback.log
- PgBouncer: /var/log/pg-ha/pgbouncer.log
- Postgres: journalctl -u postgresql; psql -c 'select * from pg_stat_replication;'
- TLS files: /etc/ssl/pg
- Secret access from node (example):
```bash
gcloud secrets versions access latest --secret=tls-ca-cert
```

## Clean-up (optional)
```bash
terraform destroy
```
