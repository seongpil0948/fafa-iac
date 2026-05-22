variable "project_id" {
  type        = string
  description = "GCP project ID."
}

variable "region" {
  type        = string
  description = "GCP region for Cloud Scheduler jobs (e.g. asia-northeast3)."
}

variable "timezone" {
  type        = string
  description = "IANA timezone string used for cron expressions (e.g. Asia/Seoul)."
}

variable "invoker_sa_email" {
  type        = string
  description = "Service account email granted roles/run.invoker on the target Cloud Run services."
}

variable "sync_dispatch_url" {
  type        = string
  description = "HTTPS URL of the sync-dispatch Cloud Function (Gen 2)."
  validation {
    condition     = can(regex("^https://", var.sync_dispatch_url))
    error_message = "sync_dispatch_url must start with https://"
  }
}

variable "cleanup_url" {
  type        = string
  description = "HTTPS URL of the cleanup Cloud Function (Gen 2)."
  validation {
    condition     = can(regex("^https://", var.cleanup_url))
    error_message = "cleanup_url must start with https://"
  }
}

variable "expire_trials_url" {
  type        = string
  description = "HTTPS URL of the expire-trials Cloud Function (Gen 2)."
  validation {
    condition     = can(regex("^https://", var.expire_trials_url))
    error_message = "expire_trials_url must start with https://"
  }
}

variable "sync_dispatch_schedule" {
  type        = string
  description = "Cron expression for sync-dispatch (e.g. \"0 * * * *\" for hourly)."
}

variable "cleanup_schedule" {
  type        = string
  description = "Cron expression for cleanup (e.g. \"0 3 * * *\" for daily at 03:00)."
}

variable "expire_trials_schedule" {
  type        = string
  description = "Cron expression for expire-trials (e.g. \"30 3 * * *\")."
}

# The HTTP function timeout (seconds). Cloud Scheduler's attempt_deadline must
# exceed this so a slow function isn't considered timed-out by the scheduler
# before it can respond. We add a 60-second grace period.
variable "function_timeout_seconds" {
  type        = number
  default     = 540
  description = "Cloud Functions HTTP timeout in seconds. attempt_deadline is set to this + 60s."
}

variable "retry_count" {
  type        = number
  default     = 3
  description = "Number of retry attempts per job invocation on failure."
}

locals {
  jobs = {
    sync-dispatch = {
      url      = var.sync_dispatch_url
      schedule = var.sync_dispatch_schedule
    }
    cleanup = {
      url      = var.cleanup_url
      schedule = var.cleanup_schedule
    }
    expire-trials = {
      url      = var.expire_trials_url
      schedule = var.expire_trials_schedule
    }
  }
}

resource "google_cloud_scheduler_job" "jobs" {
  for_each = local.jobs

  project   = var.project_id
  region    = var.region
  name      = each.key
  schedule  = each.value.schedule
  time_zone = var.timezone

  # attempt_deadline must exceed the function's own HTTP timeout; otherwise the
  # scheduler declares failure before the function finishes and retries
  # unnecessarily. We add a 60s buffer above the function timeout.
  attempt_deadline = "${var.function_timeout_seconds + 60}s"

  retry_config {
    retry_count = var.retry_count
    # Exponential backoff: first retry after 5s, cap at 60s.
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
      service_account_email = var.invoker_sa_email
      audience              = each.value.url
    }
  }
}
