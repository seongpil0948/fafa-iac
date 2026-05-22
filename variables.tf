variable "project_id" {
  description = "GCP project ID (existing Firebase project)."
  type        = string
  default     = "fafa-255a2"
}

variable "region" {
  description = "Primary GCP region for Firestore, KMS, Functions, Scheduler."
  type        = string
  default     = "asia-northeast3"
}

variable "scheduler_timezone" {
  description = "IANA TZ string for Cloud Scheduler jobs."
  type        = string
  default     = "Asia/Seoul"
}

variable "sync_dispatch_schedule" {
  description = "Cron expression for the periodic sync-dispatch job."
  type        = string
  default     = "*/15 * * * *"
}

variable "cleanup_schedule" {
  type    = string
  default = "0 2 * * *"
}

variable "expire_trials_schedule" {
  type    = string
  default = "0 3 * * *"
}

variable "functions_runtime" {
  type    = string
  default = "nodejs22"
  # nodejs24 currently resolves to an RC base image whose bundled Functions
  # Framework breaks `firebase-functions@^7` onMessagePublished (malformed
  # CloudEvent body). Re-pin to nodejs24 once it is GA. Note: this value is
  # informational only — modules/functions/main.tf has build_config[0].runtime
  # in ignore_changes; the operational runtime is set by
  # SiveraV2/functions/scripts/deploy-all.sh (RUNTIME env).
}
