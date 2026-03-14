# ── GCS Backup Buckets ───────────────────────────────────────────────────────
# Separate bucket per data type. The Terraform state bucket (backend "gcs")
# is created manually outside of this config.

locals {
  backup_buckets = {
    postgres         = "hkp-${var.env}-postgres-backups"
    etcd             = "hkp-${var.env}-etcd-backups"
    rustfs           = "hkp-${var.env}-rustfs-backups"
    victoriametrics  = "hkp-${var.env}-victoriametrics-backups"
    loki             = "hkp-${var.env}-loki-backups"
  }
}

resource "google_storage_bucket" "postgres_backups" {
  name          = "${var.gcp_project}-${local.backup_buckets.postgres}"
  location      = var.gcp_region
  force_destroy = false

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition { age = 30 }
    action { type = "SetStorageClass"; storage_class = "NEARLINE" }
  }
  lifecycle_rule {
    condition { age = 90 }
    action { type = "Delete" }
  }
  lifecycle_rule {
    condition { num_newer_versions = 1; with_state = "NONCURRENT" }
    action { type = "SetStorageClass"; storage_class = "NEARLINE" }
  }
  lifecycle_rule {
    condition { days_since_noncurrent_time = 30; with_state = "NONCURRENT" }
    action { type = "Delete" }
  }
}

resource "google_storage_bucket" "etcd_backups" {
  name          = "${var.gcp_project}-${local.backup_buckets.etcd}"
  location      = var.gcp_region
  force_destroy = false

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition { age = 30 }
    action { type = "SetStorageClass"; storage_class = "NEARLINE" }
  }
  lifecycle_rule {
    condition { age = 90 }
    action { type = "Delete" }
  }
  lifecycle_rule {
    condition { num_newer_versions = 1; with_state = "NONCURRENT" }
    action { type = "SetStorageClass"; storage_class = "NEARLINE" }
  }
  lifecycle_rule {
    condition { days_since_noncurrent_time = 30; with_state = "NONCURRENT" }
    action { type = "Delete" }
  }
}

resource "google_storage_bucket" "rustfs_backups" {
  name          = "${var.gcp_project}-${local.backup_buckets.rustfs}"
  location      = var.gcp_region
  force_destroy = false

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  # Artifacts/objects — keep longer than observability data.
  lifecycle_rule {
    condition { age = 30 }
    action { type = "SetStorageClass"; storage_class = "NEARLINE" }
  }
  lifecycle_rule {
    condition { age = 90 }
    action { type = "SetStorageClass"; storage_class = "COLDLINE" }
  }
  lifecycle_rule {
    condition { age = 180 }
    action { type = "Delete" }
  }
  lifecycle_rule {
    condition { num_newer_versions = 1; with_state = "NONCURRENT" }
    action { type = "SetStorageClass"; storage_class = "NEARLINE" }
  }
  lifecycle_rule {
    condition { days_since_noncurrent_time = 30; with_state = "NONCURRENT" }
    action { type = "Delete" }
  }
}

resource "google_storage_bucket" "victoriametrics_backups" {
  name          = "${var.gcp_project}-${local.backup_buckets.victoriametrics}"
  location      = var.gcp_region
  force_destroy = false

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition { age = 30 }
    action { type = "SetStorageClass"; storage_class = "NEARLINE" }
  }
  lifecycle_rule {
    condition { age = 90 }
    action { type = "Delete" }
  }
  lifecycle_rule {
    condition { num_newer_versions = 1; with_state = "NONCURRENT" }
    action { type = "SetStorageClass"; storage_class = "NEARLINE" }
  }
  lifecycle_rule {
    condition { days_since_noncurrent_time = 30; with_state = "NONCURRENT" }
    action { type = "Delete" }
  }
}

resource "google_storage_bucket" "loki_backups" {
  name          = "${var.gcp_project}-${local.backup_buckets.loki}"
  location      = var.gcp_region
  force_destroy = false

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition { age = 30 }
    action { type = "SetStorageClass"; storage_class = "NEARLINE" }
  }
  lifecycle_rule {
    condition { age = 90 }
    action { type = "Delete" }
  }
  lifecycle_rule {
    condition { num_newer_versions = 1; with_state = "NONCURRENT" }
    action { type = "SetStorageClass"; storage_class = "NEARLINE" }
  }
  lifecycle_rule {
    condition { days_since_noncurrent_time = 30; with_state = "NONCURRENT" }
    action { type = "Delete" }
  }
}

# ── Service Account for backup uploads ───────────────────────────────────────
# Single SA with write access to all backup buckets.
# Machines authenticate with this key to push backups to GCS.

resource "google_service_account" "backup" {
  account_id   = "hkp-${var.env}-backup"
  display_name = "HKP ${var.env} backup agent"
}

resource "google_storage_bucket_iam_member" "backup_postgres" {
  bucket = google_storage_bucket.postgres_backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.backup.email}"
}

resource "google_storage_bucket_iam_member" "backup_etcd" {
  bucket = google_storage_bucket.etcd_backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.backup.email}"
}

resource "google_storage_bucket_iam_member" "backup_rustfs" {
  bucket = google_storage_bucket.rustfs_backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.backup.email}"
}

resource "google_storage_bucket_iam_member" "backup_victoriametrics" {
  bucket = google_storage_bucket.victoriametrics_backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.backup.email}"
}

resource "google_storage_bucket_iam_member" "backup_loki" {
  bucket = google_storage_bucket.loki_backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.backup.email}"
}

# Rotate the SA key every 90 days. On the next `terraform apply` after expiry,
# Terraform destroys the old key and creates a new one. The operator must then
# update the corresponding Kubernetes secret (sealed or otherwise).
resource "time_rotating" "backup_key_rotation" {
  rotation_days = 90
}

resource "google_service_account_key" "backup" {
  service_account_id = google_service_account.backup.name

  lifecycle {
    replace_triggered_by = [time_rotating.backup_key_rotation]
  }
}
