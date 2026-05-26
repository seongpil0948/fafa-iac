locals {
  scheduler_jobs = {
    sync-dispatch = {
      url      = google_cloudfunctions2_function.https[local.function_names.sync_dispatch].service_config[0].uri
      schedule = var.sync_dispatch_schedule
    }
    cleanup = {
      url      = google_cloudfunctions2_function.https[local.function_names.cleanup].service_config[0].uri
      schedule = var.cleanup_schedule
    }
    expire-trials = {
      url      = google_cloudfunctions2_function.https[local.function_names.expire_trials].service_config[0].uri
      schedule = var.expire_trials_schedule
    }
  }

  # Cloud Scheduler attempt_deadline must exceed the function's HTTP timeout;
  # otherwise the scheduler declares failure before the function finishes.
  # We add a 60s buffer above the function timeout (540s).
  scheduler_attempt_deadline = "600s"
}

resource "google_cloud_scheduler_job" "jobs" {
  for_each = local.scheduler_jobs

  project   = var.project_id
  region    = var.region
  name      = each.key
  schedule  = each.value.schedule
  time_zone = var.scheduler_timezone

  attempt_deadline = local.scheduler_attempt_deadline

  retry_config {
    retry_count          = 3
    min_backoff_duration = "5s"
    max_backoff_duration = "60s"
  }

  http_target {
    http_method = "POST"
    uri         = each.value.url

    headers = {
      "Content-Type" = "application/json"
    }

    body = base64encode("{}")

    oidc_token {
      service_account_email = google_service_account.scheduler_invoker.email
      audience              = each.value.url
    }
  }

  depends_on = [
    google_cloud_run_v2_service_iam_member.scheduler_invokes_https_functions,
  ]
}
