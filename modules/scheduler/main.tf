variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "timezone" {
  type = string
}

variable "invoker_sa_email" {
  type = string
}

variable "sync_dispatch_url" {
  type = string
}

variable "cleanup_url" {
  type = string
}

variable "expire_trials_url" {
  type = string
}

variable "sync_dispatch_schedule" {
  type = string
}

variable "cleanup_schedule" {
  type = string
}

variable "expire_trials_schedule" {
  type = string
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

  attempt_deadline = "320s"

  retry_config {
    retry_count = 3
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
