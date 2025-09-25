locals {
  backup_bucket = var.backup_bucket_name != "" ? var.backup_bucket_name : "${var.project_id}-pg-ha-backups"
}

resource "google_storage_bucket" "pgbackrest" {
  name                        = local.backup_bucket
  location                    = var.backup_location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  versioning { enabled = true }
  lifecycle_rule {
    action { type = "Delete" }
    condition { num_newer_versions = 5 }
  }
  lifecycle_rule {
    action { type = "Delete" }
    condition { age = 365 }
  }
  labels = var.default_labels
}
