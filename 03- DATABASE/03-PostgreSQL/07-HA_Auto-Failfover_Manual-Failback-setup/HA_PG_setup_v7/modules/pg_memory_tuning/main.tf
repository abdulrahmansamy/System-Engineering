terraform {
  required_version = ">= 1.3.0"
}

variable "nodes_memory_gb" {
  type        = map(number)
  description = "Map of node identifiers to total RAM in GB (e.g., { node-a = 32, node-b = 64 })."
}

variable "work_mem_mb" {
  type        = number
  description = "Desired work_mem per connection in MB."
  default     = 16
}

variable "shared_buffers_ratio" {
  type        = number
  description = "Fraction of total RAM to use for shared_buffers (recommend 0.15 to 0.25)."
  default     = 0.25
}

variable "effective_cache_size_ratio" {
  type        = number
  description = "Fraction of total RAM to use for effective_cache_size (recommend 0.5)."
  default     = 0.5
}

variable "maintenance_work_mem_fraction" {
  type        = number
  description = "Fraction of total RAM to allocate to maintenance_work_mem (recommend 0.05)."
  default     = 0.05
}

locals {
  # Convert GB to MB
  nodes_memory_mb = {
    for k, v in var.nodes_memory_gb :
    k => v * 1024
  }

  # Per-node computed GUCs in MB
  nodes_gucs_mb = {
    for node, mem_mb in local.nodes_memory_mb :
    node => {
      # shared_buffers ≈ 15–25% of RAM
      shared_buffers_mb = floor(mem_mb * var.shared_buffers_ratio)

      # maintenance_work_mem ≈ 5% of RAM
      maintenance_work_mem_mb = floor(mem_mb * var.maintenance_work_mem_fraction)

      # effective_cache_size ≈ 50% of RAM
      effective_cache_size_mb = floor(mem_mb * var.effective_cache_size_ratio)

      # max_connections = (Total RAM × 0.25) ÷ work_mem
      max_connections = max(1, floor((mem_mb * 0.25) / var.work_mem_mb))

      # work_mem is user-defined
      work_mem_mb = var.work_mem_mb
    }
  }

  # Format as postgresql.conf lines
  nodes_postgresql_conf = {
    for node, gucs in local.nodes_gucs_mb :
    node => [
      "shared_buffers = ${gucs.shared_buffers_mb}MB",
      "work_mem = ${gucs.work_mem_mb}MB",
      "maintenance_work_mem = ${gucs.maintenance_work_mem_mb}MB",
      "effective_cache_size = ${gucs.effective_cache_size_mb}MB",
      "max_connections = ${gucs.max_connections}"
    ]
  }
}

output "nodes_gucs_mb" {
  description = "Computed GUC parameters (MB) per node."
  value       = local.nodes_gucs_mb
}

output "nodes_postgresql_conf" {
  description = "postgresql.conf-ready lines per node."
  value       = local.nodes_postgresql_conf
}
