locals {
  fqdn_suffix   = chomp(google_dns_managed_zone.private.dns_name)
  fqdn_primary  = "pg-primary.${local.fqdn_suffix}"
  fqdn_secondary= "pg-secondary.${local.fqdn_suffix}"
  fqdn_monitor  = "pg-monitor.${local.fqdn_suffix}"
}

resource "tls_private_key" "ca_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "ca_cert" {
  subject {
    common_name  = "pg-ha-internal-ca"
    organization = "PG HA"
  }
  is_ca_certificate       = true
  validity_period_hours   = 87600
  allowed_uses            = ["cert_signing","crl_signing","key_encipherment","digital_signature"]
  private_key_pem         = tls_private_key.ca_key.private_key_pem
}

resource "tls_private_key" "primary_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_private_key" "secondary_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_private_key" "monitor_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_cert_request" "primary_csr" {
  key_algorithm   = "RSA"
  private_key_pem = tls_private_key.primary_key.private_key_pem
  subject { common_name = local.fqdn_primary }
  dns_names    = [local.fqdn_primary, "pg-primary"]
  ip_addresses = [var.primary_ip]
}

resource "tls_cert_request" "secondary_csr" {
  key_algorithm   = "RSA"
  private_key_pem = tls_private_key.secondary_key.private_key_pem
  subject { common_name = local.fqdn_secondary }
  dns_names    = [local.fqdn_secondary, "pg-secondary"]
  ip_addresses = [var.secondary_ip]
}

resource "tls_cert_request" "monitor_csr" {
  key_algorithm   = "RSA"
  private_key_pem = tls_private_key.monitor_key.private_key_pem
  subject { common_name = local.fqdn_monitor }
  dns_names    = [local.fqdn_monitor, "pg-monitor"]
  ip_addresses = [var.monitor_ip]
}

resource "tls_locally_signed_cert" "primary_cert" {
  cert_request_pem     = tls_cert_request.primary_csr.cert_request_pem
  ca_private_key_pem   = tls_private_key.ca_key.private_key_pem
  ca_cert_pem          = tls_self_signed_cert.ca_cert.cert_pem
  validity_period_hours= 8760
  allowed_uses         = ["digital_signature","key_encipherment","server_auth","client_auth"]
}

resource "tls_locally_signed_cert" "secondary_cert" {
  cert_request_pem     = tls_cert_request.secondary_csr.cert_request_pem
  ca_private_key_pem   = tls_private_key.ca_key.private_key_pem
  ca_cert_pem          = tls_self_signed_cert.ca_cert.cert_pem
  validity_period_hours= 8760
  allowed_uses         = ["digital_signature","key_encipherment","server_auth","client_auth"]
}

resource "tls_locally_signed_cert" "monitor_cert" {
  cert_request_pem     = tls_cert_request.monitor_csr.cert_request_pem
  ca_private_key_pem   = tls_private_key.ca_key.private_key_pem
  ca_cert_pem          = tls_self_signed_cert.ca_cert.cert_pem
  validity_period_hours= 8760
  allowed_uses         = ["digital_signature","key_encipherment","server_auth","client_auth"]
}
