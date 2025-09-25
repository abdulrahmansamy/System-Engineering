data "google_compute_image" "ubuntu" {
  family  = var.ubuntu_family
  project = "ubuntu-os-cloud"
}

resource "google_compute_disk" "primary_data" {
  name  = "pg-primary-data"
  type  = var.data_disk_type
  zone  = var.primary_zone
  size  = var.data_disk_size_gb
  labels = var.default_labels
}

resource "google_compute_disk" "primary_wal" {
  name  = "pg-primary-wal"
  type  = var.wal_disk_type
  zone  = var.primary_zone
  size  = var.wal_disk_size_gb
  labels = var.default_labels
}

resource "google_compute_disk" "secondary_data" {
  name  = "pg-secondary-data"
  type  = var.data_disk_type
  zone  = var.secondary_zone
  size  = var.data_disk_size_gb
  labels = var.default_labels
}

resource "google_compute_disk" "secondary_wal" {
  name  = "pg-secondary-wal"
  type  = var.wal_disk_type
  zone  = var.secondary_zone
  size  = var.wal_disk_size_gb
  labels = var.default_labels
}

resource "google_compute_instance" "primary" {
  name         = "pg-primary"
  machine_type = var.node_machine_type
  zone         = var.primary_zone
  tags         = ["pg-ha", "pg-ha-admin", "pg-role-primary", "pg-function-postgresql"]
  labels       = merge(var.default_labels, {
    role     = "primary"
    function = "postgresql"
  })

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      type  = "pd-balanced"
      size  = 50
    }
    auto_delete = true
  }

  attached_disk {
    source      = google_compute_disk.primary_data.id
    device_name = "pgdata"
    mode        = "READ_WRITE"
  }

  attached_disk {
    source      = google_compute_disk.primary_wal.id
    device_name = "pgwal"
    mode        = "READ_WRITE"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.self_link
    network_ip = google_compute_address.primary.address
  }

  service_account {
    email  = google_service_account.pg_nodes.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata_startup_script = file("${path.module}/scripts/bootstrap_os.sh")

  metadata = {
    timezone = var.timezone
    role     = "primary"
    noderole = "pg-primary"
    function = "postgresql"
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
    provisioning_model  = "STANDARD"
  }
}

resource "google_compute_instance" "secondary" {
  name         = "pg-secondary"
  machine_type = var.node_machine_type
  zone         = var.secondary_zone
  tags         = ["pg-ha", "pg-ha-admin", "pg-role-secondary", "pg-function-postgresql"]
  labels       = merge(var.default_labels, {
    role     = "secondary"
    function = "postgresql"
  })

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      type  = "pd-balanced"
      size  = 50
    }
    auto_delete = true
  }

  attached_disk {
    source      = google_compute_disk.secondary_data.id
    device_name = "pgdata"
    mode        = "READ_WRITE"
  }

  attached_disk {
    source      = google_compute_disk.secondary_wal.id
    device_name = "pgwal"
    mode        = "READ_WRITE"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.self_link
    network_ip = google_compute_address.secondary.address
  }

  service_account {
    email  = google_service_account.pg_nodes.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata_startup_script = file("${path.module}/scripts/bootstrap_os.sh")

  metadata = {
    timezone = var.timezone
    role     = "secondary"
    noderole = "pg-secondary"
    function = "postgresql"
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
    provisioning_model  = "STANDARD"
  }
}

resource "google_compute_instance" "monitor" {
  name         = "pg-monitor"
  machine_type = var.monitor_machine_type
  zone         = var.monitor_zone
  tags         = ["pg-ha", "pg-ha-admin", "pg-role-monitor", "pg-function-monitor"]
  labels       = merge(var.default_labels, {
    role     = "monitor"
    function = "pg_auto_failover_monitor"
  })

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      type  = "pd-balanced"
      size  = 30
    }
    auto_delete = true
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.self_link
    network_ip = google_compute_address.monitor.address
  }

  service_account {
    email  = google_service_account.pg_monitor.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata_startup_script = file("${path.module}/scripts/bootstrap_os.sh")

  metadata = {
    timezone = var.timezone
    role     = "monitor"
    noderole = "pg-monitor"
    function = "pg_auto_failover_monitor"
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
    provisioning_model  = "STANDARD"
  }
}
