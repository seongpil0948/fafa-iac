locals {
  # 7 days. Pub/Sub default is 7d but we pin it so it does not silently
  # change if Google updates the default.
  pubsub_retention = "604800s"
}

# Dead-letter topic. NOTE: a topic alone is not a DLQ — the dead-letter
# *policy* lives on the Cloud Functions Gen 2 / Eventarc subscription. Eventarc
# manages those subscriptions implicitly, so attaching a DLQ requires reaching
# into the Eventarc-managed subscription via gcloud after terraform apply.
# Run scripts/setup-dlq.sh once after the first apply and after any function
# re-creation. The script is idempotent.
resource "google_pubsub_topic" "dead_letter" {
  project                    = var.project_id
  name                       = "fafa-dead-letter"
  message_retention_duration = local.pubsub_retention
}

# Drain/inspection subscription on the DLQ topic. Without at least one
# subscription, dead-lettered messages are dropped on arrival (topic
# retention only buys a 7-day seek window) and nothing can be replayed
# after an incident. Never auto-expire it; operators pull from it during
# incident response (docs/deployment-runbook.md rollback section).
resource "google_pubsub_subscription" "dead_letter_drain" {
  project                    = var.project_id
  name                       = "fafa-dead-letter-drain"
  topic                      = google_pubsub_topic.dead_letter.id
  message_retention_duration = local.pubsub_retention
  retain_acked_messages      = false

  expiration_policy {
    ttl = "" # never expire, even with no pull activity
  }
}

resource "google_pubsub_topic" "sync_credential" {
  project                    = var.project_id
  name                       = "sync-credential-requested"
  message_retention_duration = local.pubsub_retention
}

resource "google_pubsub_topic" "fcm_send" {
  project                    = var.project_id
  name                       = "fcm-send-requested"
  message_retention_duration = local.pubsub_retention
}

resource "google_pubsub_topic" "amazon_report" {
  project                    = var.project_id
  name                       = "amazon-report-requested"
  message_retention_duration = local.pubsub_retention
}

# Unified cross-platform report jobs (reportJobs). The web route
# POST /api/reports publishes { jobId } here; the process-report Cloud
# Function (Eventarc-triggered, runs as sync-runner SA) consumes it and
# fans out to the per-platform report runners. See docs/unified-reports.md.
resource "google_pubsub_topic" "report" {
  project                    = var.project_id
  name                       = "report-requested"
  message_retention_duration = local.pubsub_retention
}

# Allow the sync-runner SA to publish amazon report requests from the web
# route handler (via the runtime SA that also runs process-amazon-report).
resource "google_pubsub_topic_iam_member" "runner_amazon_report_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.amazon_report.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.sync_runner.email}"
}

# Allow the sync-runner SA to publish to the DLQ from inside a function when
# it decides a message is permanently un-processable.
resource "google_pubsub_topic_iam_member" "runner_dlq_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.dead_letter.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.sync_runner.email}"
}

# Allow the Vercel app SA to publish manual resync requests directly to the
# sync-credential-requested topic. This is used as the fallback path in
# apps/web/lib/server/cf-invoke.ts:notifyManualSync when SYNC_ON_DEMAND_URL
# is unset (local dev or environments without the on-demand HTTPS function).
resource "google_pubsub_topic_iam_member" "vercel_sync_credential_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.sync_credential.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.vercel_app.email}"
}

# Allow the Vercel app SA to publish unified report-job requests from the
# web route handler POST /api/reports (apps/web/lib/server/pubsub-publish.ts).
resource "google_pubsub_topic_iam_member" "vercel_report_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.report.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.vercel_app.email}"
}

# Allow the sync-runner SA to publish report requests too — used when the
# worker re-publishes a job to itself (retry/resume) and for parity with the
# amazon-report topic grant.
resource "google_pubsub_topic_iam_member" "runner_report_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.report.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.sync_runner.email}"
}
