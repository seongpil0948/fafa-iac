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
