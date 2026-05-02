terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.43"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.43"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "google" {
  alias   = "app_projects"
  project = contains(["prod", "production", "prd"], lower(terraform.workspace == "default" ? var.ha_db_environment : terraform.workspace)) ? var.prod_app_project_id : var.nonprod_app_project_id
  region  = var.region
}

provider "google" {
  alias   = "db_projects"
  project = contains(["prod", "production", "prd"], lower(terraform.workspace == "default" ? var.ha_db_environment : terraform.workspace)) ? var.prod_db_project_id : var.nonprod_db_project_id
  region  = var.region
}


# Shared VPC lives in the host project; use an alias to query resources there
provider "google" {
  alias   = "host"
  project = var.host_project_id
  region  = var.region
}
