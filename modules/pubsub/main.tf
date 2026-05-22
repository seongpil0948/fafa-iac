variable "project_id" {
  type = string
}

variable "sync_runner_sa_email" {
  type = string
}

locals {
  # 7 days. Pub/Sub default is 7d but we pin it so it does not silently
  # change if Google updates the default.
  retention = "604800s"
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
  message_retention_duration = local.retention
}

resource "google_pubsub_topic" "sync_credential" {
  project                    = var.project_id
  name                       = "sync-credential-requested"
  message_retention_duration = local.retention
}

resource "google_pubsub_topic" "fcm_send" {
  project                    = var.project_id
  name                       = "fcm-send-requested"
  message_retention_duration = local.retention
}

# Allow the sync-runner SA to publish to the DLQ from inside a function when
# it decides a message is permanently un-processable.
resource "google_pubsub_topic_iam_member" "runner_dlq_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.dead_letter.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${var.sync_runner_sa_email}"
}

output "sync_credential_topic_id" {
  value = google_pubsub_topic.sync_credential.id
}

output "fcm_send_topic_id" {
  value = google_pubsub_topic.fcm_send.id
}

output "dead_letter_topic_id" {
  value = google_pubsub_topic.dead_letter.id
}
