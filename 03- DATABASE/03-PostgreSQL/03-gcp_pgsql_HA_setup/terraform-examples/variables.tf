# Variables for GCP PostgreSQL HA Terraform configuration

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "us-central1-a"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "instance_prefix" {
  description = "Prefix for instance names"
  type        = string
  default     = "postgresql-ha"
}

variable "machine_type" {
  description = "Machine type for PostgreSQL instances"
  type        = string
  default     = "n2-standard-2"
  
  validation {
    condition = contains([
      "e2-standard-2", "e2-standard-4",
      "n2-standard-2", "n2-standard-4", "n2-standard-8",
      "c2-standard-4", "c2-standard-8", "c2-standard-16"
    ], var.machine_type)
    error_message = "Machine type must be a valid GCP machine type suitable for PostgreSQL."
  }
}

variable "boot_disk_size" {
  description = "Boot disk size in GB"
  type        = number
  default     = 50
  
  validation {
    condition     = var.boot_disk_size >= 20 && var.boot_disk_size <= 1000
    error_message = "Boot disk size must be between 20GB and 1000GB."
  }
}

variable "boot_disk_type" {
  description = "Boot disk type"
  type        = string
  default     = "pd-ssd"
  
  validation {
    condition     = contains(["pd-standard", "pd-ssd", "pd-balanced"], var.boot_disk_type)
    error_message = "Boot disk type must be pd-standard, pd-ssd, or pd-balanced."
  }
}

variable "data_disk_size" {
  description = "Additional data disk size in GB (0 to disable)"
  type        = number
  default     = 100
  
  validation {
    condition     = var.data_disk_size >= 0 && var.data_disk_size <= 65536
    error_message = "Data disk size must be between 0GB and 65536GB."
  }
}

variable "data_disk_type" {
  description = "Data disk type"
  type        = string
  default     = "pd-ssd"
  
  validation {
    condition     = contains(["pd-standard", "pd-ssd", "pd-balanced"], var.data_disk_type)
    error_message = "Data disk type must be pd-standard, pd-ssd, or pd-balanced."
  }
}

variable "ssh_source_ranges" {
  description = "Source IP ranges for SSH access"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "create_dns_zone" {
  description = "Whether to create a Cloud DNS zone"
  type        = bool
  default     = false
}

variable "dns_domain" {
  description = "DNS domain name (required if create_dns_zone is true)"
  type        = string
  default     = ""
}

variable "notification_emails" {
  description = "Email addresses for monitoring notifications"
  type        = list(string)
  default     = []
}

variable "backup_retention_days" {
  description = "Number of days to retain backups"
  type        = number
  default     = 90
  
  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 365
    error_message = "Backup retention must be between 7 and 365 days."
  }
}

variable "enable_monitoring" {
  description = "Enable Cloud Monitoring and alerting"
  type        = bool
  default     = true
}

variable "enable_logging" {
  description = "Enable Cloud Logging for PostgreSQL"
  type        = bool
  default     = true
}
