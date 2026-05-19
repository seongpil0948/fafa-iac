variable "project_id" {
  type = string
}

variable "sync_runner_sa_email" {
  type        = string
  description = "Runtime SA for Cloud Functions that consume these secrets."
}

# Names ONLY — values are seeded out-of-band via scripts/seed-secrets.sh
# (reading from apps/web/.env.local) so that secret material never lands
# in Terraform state. Each platform's OAuth client_id/client_secret/etc.
# is treated as a secret; toggles like AMAZON_TEST_ACCOUNTS_ENABLED and
# NEXT_PUBLIC_APP_URL stay as plain env vars on the function shell.
locals {
  platform_secret_names = toset([
    "AMAZON_CLIENT_ID",
    "AMAZON_CLIENT_SECRET",
    "GOOGLE_CLIENT_ID",
    "GOOGLE_CLIENT_SECRET",
    "GOOGLE_DEVELOPER_TOKEN",
    "META_APP_ID",
    "META_APP_SECRET",
    "META_LOGIN_CONFIG_ID",
    "TIKTOK_APP_ID",
    "TIKTOK_APP_SECRET",
  ])
}

resource "google_secret_manager_secret" "platform" {
  for_each = local.platform_secret_names

  project   = var.project_id
  secret_id = each.value

  replication {
    auto {}
  }

  # Once created, the secret resource itself must persist even if Terraform
  # ever stops managing it (orphan-safer than recreating, which would force
  # a value re-seed). Versions are mutable separately.
  lifecycle {
    prevent_destroy = true
  }
}

# Grant the Cloud Functions runtime SA accessor on every platform secret.
# `roles/secretmanager.secretAccessor` is the least-privileged role that
# allows `secrets.versions.access` — the only operation Cloud Functions
# needs at cold start to mount the secret as an env var.
resource "google_secret_manager_secret_iam_member" "sync_runner_accessor" {
  for_each = google_secret_manager_secret.platform

  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.sync_runner_sa_email}"
}

output "secret_names" {
  description = "Platform secret short names (== Cloud Functions env var keys)."
  value       = tolist(local.platform_secret_names)
}

output "secret_refs_for_gcloud" {
  description = "Comma-joined --set-secrets value for `gcloud functions deploy`."
  value = join(",", [
    for name in local.platform_secret_names :
    "${name}=projects/${var.project_id}/secrets/${name}/versions/latest"
  ])
}
