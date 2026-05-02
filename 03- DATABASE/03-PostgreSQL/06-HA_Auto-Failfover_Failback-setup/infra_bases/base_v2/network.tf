############################################################
# Shared VPC and Subnets (data lookups; no resource creation)
############################################################

data "google_compute_network" "shared_vpc" {
  provider = google.host
  name     = var.shared_vpc_network_id
}

data "google_compute_subnetwork" "prod_app" {
  provider = google.host
  name     = var.prod_application_subnet_id
  region   = var.region
}

data "google_compute_subnetwork" "prod_db" {
  provider = google.host
  name     = var.prod_database_subnet_id
  region   = var.region
}

data "google_compute_subnetwork" "nonprod_app" {
  provider = google.host
  name     = var.nonprod_application_subnet_id
  region   = var.region
}

data "google_compute_subnetwork" "nonprod_db" {
  provider = google.host
  name     = var.nonprod_database_subnet_id
  region   = var.region
}

output "shared_vpc_self_link" {
  value       = data.google_compute_network.shared_vpc.self_link
  description = "Self link of the Shared VPC network"
}

output "prod_db_subnet_self_link" {
  value       = data.google_compute_subnetwork.prod_db.self_link
  description = "Self link of the production DB subnet"
}

output "prod_app_subnet_self_link" {
  value       = data.google_compute_subnetwork.prod_app.self_link
  description = "Self link of the production App subnet"
}

output "nonprod_db_subnet_self_link" {
  value       = data.google_compute_subnetwork.nonprod_db.self_link
  description = "Self link of the non-production DB subnet"
}

output "nonprod_app_subnet_self_link" {
  value       = data.google_compute_subnetwork.nonprod_app.self_link
  description = "Self link of the non-production App subnet"
}
