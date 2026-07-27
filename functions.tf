locals {
  function_names = {
    sync_on_connect       = "sync-on-connect"
    sync_on_demand        = "sync-on-demand"
    sync_dispatch         = "sync-dispatch"
    sync_credential       = "sync-credential"
    send_fcm              = "send-fcm"
    cleanup               = "cleanup"
    expire_trials         = "expire-trials"
    process_amazon_report = "process-amazon-report"
    process_report        = "process-report"
  }

  # Config for HTTPS-triggered functions (sync-on-connect, sync-on-demand,
  # sync-dispatch, cleanup, expire-trials).
  https_function_config = {
    available_memory   = "512Mi"
    timeout_seconds    = 540
    max_instance_count = 10
  }

  # Config for Pub/Sub-triggered functions (sync-credential, send-fcm,
  # process-amazon-report). max_instance_count is intentionally low: 5 instances
  # × Cloud Run concurrency comfortably handles the normal sync backlog
  # (≤500 credentials per dispatch, each sync taking <30 s). Raise if Cloud
  # Monitoring shows sustained queue lag.
  pubsub_function_config = {
    available_memory   = "1Gi"
    timeout_seconds    = 540
    max_instance_count = 5
  }

  https_functions = {
    (local.function_names.sync_on_connect) = "syncOnConnect"
    (local.function_names.sync_on_demand)  = "syncOnDemand"
    (local.function_names.sync_dispatch)   = "syncDispatch"
    (local.function_names.cleanup)         = "cleanup"
    (local.function_names.expire_trials)   = "expireTrials"
  }

  pubsub_functions = {
    (local.function_names.sync_credential) = {
      entry_point = "syncCredential"
      topic       = google_pubsub_topic.sync_credential.id
    }
    (local.function_names.send_fcm) = {
      entry_point = "sendFcm"
      topic       = google_pubsub_topic.fcm_send.id
    }
    (local.function_names.process_amazon_report) = {
      entry_point = "processAmazonReport"
      topic       = google_pubsub_topic.amazon_report.id
    }
    (local.function_names.process_report) = {
      entry_point = "processReport"
      topic       = google_pubsub_topic.report.id
    }
  }
}

# Look up the project number to construct the build service-account email.
# We avoid plumbing project_number through tfvars by resolving it dynamically.
data "google_project" "this" {
  project_id = var.project_id
}

locals {
  # Cloud Functions Gen 2 builds run on Cloud Build. Since April 2024 Google
  # defaults to the project's default compute service account for those builds
  # (instead of the legacy <num>@cloudbuild.gserviceaccount.com). In a fresh
  # project this SA has no role unless we grant one.
  build_sa_email = "${data.google_project.this.number}-compute@developer.gserviceaccount.com"

  # Roles needed for Cloud Build to (a) read source from GCS, (b) push the
  # container image to Artifact Registry, (c) write build logs.
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
  source_dir  = "${path.root}/stub"
  output_path = "${path.root}/.stub.zip"
}

resource "google_storage_bucket_object" "stub" {
  name   = "stub-${data.archive_file.stub.output_md5}.zip"
  bucket = google_storage_bucket.source.name
  source = data.archive_file.stub.output_path
}

resource "google_cloudfunctions2_function" "https" {
  for_each = local.https_functions

  project  = var.project_id
  location = var.region
  name     = each.key

  build_config {
    runtime     = var.functions_runtime
    entry_point = "handler" # overridden by real deploys
    source {
      storage_source {
        bucket = google_storage_bucket.source.name
        object = google_storage_bucket_object.stub.name
      }
    }
  }

  service_config {
    available_memory      = local.https_function_config.available_memory
    timeout_seconds       = local.https_function_config.timeout_seconds
    max_instance_count    = local.https_function_config.max_instance_count
    min_instance_count    = 0
    service_account_email = google_service_account.sync_runner.email
    ingress_settings      = "ALLOW_ALL"
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
    ]
  }
}

resource "google_cloudfunctions2_function" "pubsub" {
  for_each = local.pubsub_functions

  project  = var.project_id
  location = var.region
  name     = each.key

  build_config {
    runtime     = var.functions_runtime
    entry_point = "handler"
    source {
      storage_source {
        bucket = google_storage_bucket.source.name
        object = google_storage_bucket_object.stub.name
      }
    }
  }

  service_config {
    available_memory      = local.pubsub_function_config.available_memory
    timeout_seconds       = local.pubsub_function_config.timeout_seconds
    max_instance_count    = local.pubsub_function_config.max_instance_count
    min_instance_count    = 0
    service_account_email = google_service_account.sync_runner.email
    ingress_settings      = "ALLOW_INTERNAL_ONLY"
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = each.value.topic
    retry_policy          = "RETRY_POLICY_RETRY"
    service_account_email = google_service_account.sync_runner.email
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

# Allow the Vercel app SA to invoke sync-on-connect and sync-on-demand.
# sync-on-demand powers the dashboard "지금 동기화" button; the Vercel route
# mints an OIDC ID token via sa-vercel-app and POSTs {uid, credentialId}.
resource "google_cloud_run_v2_service_iam_member" "vercel_invokes_sync_on_connect" {
  project  = var.project_id
  location = var.region
  name     = google_cloudfunctions2_function.https[local.function_names.sync_on_connect].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.vercel_app.email}"
}

resource "google_cloud_run_v2_service_iam_member" "vercel_invokes_sync_on_demand" {
  project  = var.project_id
  location = var.region
  name     = google_cloudfunctions2_function.https[local.function_names.sync_on_demand].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.vercel_app.email}"
}

# Allow the Scheduler SA to invoke the three scheduled HTTPS functions.
resource "google_cloud_run_v2_service_iam_member" "scheduler_invokes_https_functions" {
  for_each = toset([
    local.function_names.sync_dispatch,
    local.function_names.cleanup,
    local.function_names.expire_trials,
  ])

  project  = var.project_id
  location = var.region
  name     = google_cloudfunctions2_function.https[each.value].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler_invoker.email}"
}
