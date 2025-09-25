variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "default_labels" {
  type = map(string)
  default = {
    app        = "pg-ha"
    managed_by = "terraform"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
