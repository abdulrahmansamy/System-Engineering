variable "network_name" {
  type    = string
  default = "pg-ha-net"
}

variable "subnet_name" {
  type    = string
  default = "pg-ha-subnet"
}

variable "subnet_cidr" {
  type    = string
  default = "192.168.24.0/22"
}

variable "primary_ip" {
  type    = string
  default = "192.168.24.10"
}

variable "secondary_ip" {
  type    = string
  default = "192.168.24.11"
}

variable "monitor_ip" {
  type    = string
  default = "192.168.24.12"
}

variable "vip_ip" {
  type    = string
  default = "192.168.24.20"
}

variable "health_port" {
  type    = number
  default = 8008
}

variable "primary_zone" {
  type    = string
  default = "us-central1-a"
}

variable "secondary_zone" {
  type    = string
  default = "us-central1-b"
}

variable "monitor_zone" {
  type    = string
  default = "us-central1-c"
}

variable "node_machine_type" {
  type    = string
  default = "e2-standard-4"
}

variable "monitor_machine_type" {
  type    = string
  default = "e2-small"
}

variable "data_disk_size_gb" {
  type    = number
  default = 500
}

variable "wal_disk_size_gb" {
  type    = number
  default = 100
}

variable "data_disk_type" {
  type    = string
  default = "pd-ssd"
}

variable "wal_disk_type" {
  type    = string
  default = "pd-ssd"
}

variable "ubuntu_family" {
  type    = string
  default = "ubuntu-2204-lts"
}

variable "backup_bucket_name" {
  type    = string
  default = ""
}

variable "backup_location" {
  type    = string
  default = "us-central1"
}

variable "timezone" {
  description = "Instance timezone to set as GCE metadata (read by startup script)."
  type        = string
  default     = "Asia/Riyadh"
}
