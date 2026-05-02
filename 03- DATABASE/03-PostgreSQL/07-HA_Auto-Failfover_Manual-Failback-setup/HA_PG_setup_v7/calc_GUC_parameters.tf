variable "prd_machine_type" {
  type    = string
  default = "n2-standard-8"
}

variable "nprd_machine_type" {
  type    = string
  default = "n2-standard-4"
}

# Lookup table for n2-standard machine types
locals {
  n2_standard_memory_gb = {
    for i in [2, 4, 8, 16, 32, 48, 64, 80] :
    "n2-standard-${i}" => i * 4
  }

  prd_memory_gb  = local.n2_standard_memory_gb[var.prd_machine_type]
  nprd_memory_gb = local.n2_standard_memory_gb[var.nprd_machine_type]

  # Pass into your pg_memory_tuning module
  nodes_memory_gb = {
    "prd-node"  = local.prd_memory_gb
    "nprd-node" = local.nprd_memory_gb
  }
}

module "pg_memory_tuning" {
  source = "./modules/pg_memory_tuning"

  nodes_memory_gb = local.nodes_memory_gb
  work_mem_mb     = 10
}

output "nodes_memory_gb" {
  description = "Map of node identifiers to total RAM in GB."
  value       = local.nodes_memory_gb     
}

output "pg_guc_parameters" {
  description = "Computed PostgreSQL GUC parameters per node."
  value       = module.pg_memory_tuning.nodes_gucs_mb
}

output "postgresql_conf_lines" {
  value = module.pg_memory_tuning.nodes_postgresql_conf
}

output "nodes_gucs_mb" {
  value = module.pg_memory_tuning.nodes_gucs_mb
}
