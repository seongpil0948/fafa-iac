variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "runtime" {
  type = string
}

variable "service_account_email" {
  type = string
}

variable "function_names" {
  type = object({
    sync_on_connect = string
    sync_dispatch   = string
    sync_credential = string
    send_fcm        = string
    cleanup         = string
    expire_trials   = string
  })
}

variable "pubsub_topics" {
  type = object({
    sync_credential = string
    fcm_send        = string
  })
}

# Config for HTTPS-triggered functions (sync-on-connect, sync-dispatch, cleanup, expire-trials).
variable "https_function_config" {
  description = "Resource sizing for HTTPS Cloud Functions Gen 2."
  type = object({
    available_memory   = string
    timeout_seconds    = number
    max_instance_count = number
  })
  default = {
    available_memory   = "512Mi"
    timeout_seconds    = 540
    max_instance_count = 10
  }
}

# Config for Pub/Sub-triggered functions (sync-credential, send-fcm).
# max_instance_count is intentionally low: 5 instances × Cloud Run concurrency
# comfortably handles the normal sync backlog (≤500 credentials per dispatch,
# each sync taking <30 s). Raise if Cloud Monitoring shows sustained queue lag.
variable "pubsub_function_config" {
  description = "Resource sizing for Pub/Sub-triggered Cloud Functions Gen 2."
  type = object({
    available_memory   = string
    timeout_seconds    = number
    max_instance_count = number
  })
  default = {
    available_memory   = "1Gi"
    timeout_seconds    = 540
    max_instance_count = 5
  }
}

# Look up the project number, used to construct the build service-account
# email. We avoid plumbing project_number through tfvars by resolving it
# dynamically.
data "google_project" "this" {
  project_id = var.project_id
}

locals {
  # Cloud Functions Gen 2 builds run on Cloud Build. Since April 2024 Google
  # defaults to the project's default compute service account for those
  # builds (instead of the legacy <num>@cloudbuild.gserviceaccount.com).
  # In a fresh project this SA has no role unless we grant one, which causes
  # "Build failed with status: FAILURE. Could not build the function due to
  # a missing permission on the build service account."
  build_sa_email = "${data.google_project.this.number}-compute@developer.gserviceaccount.com"

  # Roles needed for Cloud Build to (a) read source from GCS, (b) push the
  # container image to Artifact Registry, (c) write build logs.
  # roles/cloudbuild.builds.builder is the omnibus role recommended by GCP
  # (https://cloud.google.com/functions/docs/troubleshooting#build-service-account)
  # and bundles most of what's needed.
  build_sa_roles = toset([
    "roles/cloudbuild.builds.builder",
    "roles/artifactregistry.writer",
    "roles/logging.logWriter",
    "roles/storage.objectViewer",
  ])
}

resource "google_project_iam_member" "build_sa" {
  for_each = local.build_sa_roles

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${local.build_sa_email}"
}

# Source bucket for CF Gen 2 builds. gcloud uploads zips here.
resource "google_storage_bucket" "source" {
  project                     = var.project_id
  name                        = "${var.project_id}-cf-source"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  # Build zips accumulate quickly. Keep the latest live object, drop
  # noncurrent versions after a week (gcloud functions deploy uploads a fresh
  # zip every deploy, so the noncurrent set grows unbounded otherwise).
  lifecycle_rule {
    condition {
      age        = 7
      with_state = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }
}

# Initial stub zip so Terraform can create function resources without
# waiting for a real gcloud deploy.
data "archive_file" "stub" {
  type        = "zip"
  source_dir  = "${path.module}/stub"
  output_path = "${path.module}/.stub.zip"
}

resource "google_storage_bucket_object" "stub" {
  name   = "stub-${data.archive_file.stub.output_md5}.zip"
  bucket = google_storage_bucket.source.name
  source = data.archive_file.stub.output_path
}

locals {
  https_functions = {
    (var.function_names.sync_on_connect) = "syncOnConnect"
    (var.function_names.sync_dispatch)   = "syncDispatch"
    (var.function_names.cleanup)         = "cleanup"
    (var.function_names.expire_trials)   = "expireTrials"
  }

  pubsub_functions = {
    (var.function_names.sync_credential) = {
      entry_point = "syncCredential"
      topic       = var.pubsub_topics.sync_credential
    }
    (var.function_names.send_fcm) = {
      entry_point = "sendFcm"
      topic       = var.pubsub_topics.fcm_send
    }
  }
}

resource "google_cloudfunctions2_function" "https" {
  for_each = local.https_functions

  project  = var.project_id
  location = var.region
  name     = each.key

  build_config {
    runtime     = var.runtime
    entry_point = "handler" # overridden by real deploys
    source {
      storage_source {
        bucket = google_storage_bucket.source.name
        object = google_storage_bucket_object.stub.name
      }
    }
  }

  service_config {
    available_memory      = var.https_function_config.available_memory
    timeout_seconds       = var.https_function_config.timeout_seconds
    max_instance_count    = var.https_function_config.max_instance_count
    min_instance_count    = 0
    service_account_email = var.service_account_email
    ingress_settings      = "ALLOW_ALL"
  }

  # Block creation until the build SA has the roles it needs, otherwise the
  # first Cloud Build run fails with "missing permission on the build
  # service account."
  depends_on = [google_project_iam_member.build_sa]

  lifecycle {
    ignore_changes = [
      build_config[0].source,
      build_config[0].entry_point,
      build_config[0].runtime,
      service_config[0].environment_variables,
      service_config[0].available_memory,
      service_config[0].timeout_seconds,
      service_config[0].max_instance_count,
      service_config[0].min_instance_count,
    ]
  }
}

resource "google_cloudfunctions2_function" "pubsub" {
  for_each = local.pubsub_functions

  project  = var.project_id
  location = var.region
  name     = each.key

  build_config {
    runtime     = var.runtime
    entry_point = "handler"
    source {
      storage_source {
        bucket = google_storage_bucket.source.name
        object = google_storage_bucket_object.stub.name
      }
    }
  }

  service_config {
    available_memory      = var.pubsub_function_config.available_memory
    timeout_seconds       = var.pubsub_function_config.timeout_seconds
    max_instance_count    = var.pubsub_function_config.max_instance_count
    min_instance_count    = 0
    service_account_email = var.service_account_email
    ingress_settings      = "ALLOW_INTERNAL_ONLY"
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = each.value.topic
    retry_policy          = "RETRY_POLICY_RETRY"
    service_account_email = var.service_account_email
  }

  depends_on = [google_project_iam_member.build_sa]

  lifecycle {
    ignore_changes = [
      build_config[0].source,
      build_config[0].entry_point,
      build_config[0].runtime,
      service_config[0].environment_variables,
      service_config[0].secret_environment_variables,
      service_config[0].available_memory,
      service_config[0].timeout_seconds,
      service_config[0].max_instance_count,
      service_config[0].min_instance_count,
      event_trigger[0].retry_policy,
    ]
  }
}

output "function_urls" {
  value = { for k, f in google_cloudfunctions2_function.https : k => f.service_config[0].uri }
}

# Cloud Run service name (== function name for Gen 2) used by IAM bindings.
output "cloud_run_service_names" {
  value = merge(
    { for k, _ in google_cloudfunctions2_function.https : k => k },
    { for k, _ in google_cloudfunctions2_function.pubsub : k => k },
  )
}

output "source_bucket" {
  value = google_storage_bucket.source.name
}
