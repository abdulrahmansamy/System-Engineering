# Project-level metadata for timezone, read by startup script if instance attr missing
resource "google_compute_project_metadata_item" "timezone" {
  key   = "timezone"
  value = var.timezone
}
