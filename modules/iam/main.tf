variable "project_id" {
  type = string
}

# Runtime SA for all Cloud Functions (Firestore + Pub/Sub + FCM).
resource "google_service_account" "sync_runner" {
  project      = var.project_id
  account_id   = "sa-sync-runner"
  display_name = "SiveraV2 sync runtime (Cloud Functions)"
}

# OIDC invoker SA for Cloud Scheduler → HTTPS Functions.
resource "google_service_account" "scheduler_invoker" {
  project      = var.project_id
  account_id   = "sa-scheduler-invoker"
  display_name = "Cloud Scheduler → Cloud Functions invoker"
}

# Identity used by the Next.js app on Vercel (JSON key created manually).
resource "google_service_account" "vercel_app" {
  project      = var.project_id
  account_id   = "sa-vercel-app"
  display_name = "Vercel Next.js Admin SDK"
}

# --- Role bindings ---

# sync-runner: Firestore + Pub/Sub publish + FCM
resource "google_project_iam_member" "sync_runner_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.sync_runner.email}"
}

resource "google_project_iam_member" "sync_runner_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.sync_runner.email}"
}

resource "google_project_iam_member" "sync_runner_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.sync_runner.email}"
}

# Firebase Admin SDK access (covers Cloud Messaging send permissions).
resource "google_project_iam_member" "sync_runner_firebase_admin" {
  project = var.project_id
  role    = "roles/firebase.admin"
  member  = "serviceAccount:${google_service_account.sync_runner.email}"
}

# vercel-app: Firestore + Firebase Auth Admin (session cookies, user mgmt).
resource "google_project_iam_member" "vercel_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.vercel_app.email}"
}

resource "google_project_iam_member" "vercel_firebase_auth" {
  project = var.project_id
  role    = "roles/firebaseauth.admin"
  member  = "serviceAccount:${google_service_account.vercel_app.email}"
}

# Allow Vercel SA to mint OIDC tokens (for calling sync-on-connect via Cloud Run invoker).
resource "google_service_account_iam_member" "vercel_token_creator" {
  service_account_id = google_service_account.vercel_app.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.vercel_app.email}"
}

output "sync_runner_email" {
  value = google_service_account.sync_runner.email
}

output "scheduler_invoker_email" {
  value = google_service_account.scheduler_invoker.email
}

output "vercel_app_email" {
  value = google_service_account.vercel_app.email
}
