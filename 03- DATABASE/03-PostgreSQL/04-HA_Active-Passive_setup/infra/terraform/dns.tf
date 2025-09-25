resource "google_dns_managed_zone" "private" {
  name        = "db-ha-internal"
  dns_name    = "db-ha.internal."
  visibility  = "private"
  description = "Private zone for PostgreSQL HA endpoints"
  private_visibility_config {
    networks {
      network_url = google_compute_network.vpc.id
    }
  }
}

# Private DNS A records for nodes
resource "google_dns_record_set" "node_a_records" {
  for_each = {
    "pg-primary"  = google_compute_address.primary.address
    "pg-secondary"= google_compute_address.secondary.address
    "pg-monitor"  = google_compute_address.monitor.address
  }
  name         = "${each.key}.${google_dns_managed_zone.private.dns_name}"
  managed_zone = google_dns_managed_zone.private.name
  type         = "A"
  ttl          = 30
  rrdatas      = [each.value]
}

# VIP DNS record
resource "google_dns_record_set" "pg_vip" {
  name         = "pg-vip.${google_dns_managed_zone.private.dns_name}"
  managed_zone = google_dns_managed_zone.private.name
  type         = "A"
  ttl          = 30
  rrdatas      = [google_compute_address.vip.address]
}
