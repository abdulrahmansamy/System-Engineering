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
  project = var.prod_db_project_id
  region  = var.region
}

# Shared VPC lives in the host project; use an alias to query resources there
provider "google" {
  alias   = "host"
  project = var.host_project_id
  region  = var.region
}
