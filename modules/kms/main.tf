variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

resource "google_kms_key_ring" "fafa" {
  project  = var.project_id
  name     = "fafa-firestore"
  location = var.region

  # Key rings can never be deleted from GCP (only keys can be scheduled for
  # destruction). Treat the TF resource as permanent to match reality and
  # prevent accidental state-tree removal that would leave an orphan.
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key" "firestore" {
  name            = "firestore-cmek"
  key_ring        = google_kms_key_ring.fafa.id
  rotation_period = "7776000s" # 90 days
  purpose         = "ENCRYPT_DECRYPT"

  lifecycle {
    prevent_destroy = true
  }
}

# Force the Firestore service agent to materialize. GCP creates service agents
# lazily — usually on first use of the API — so an early IAM binding can hit
# "Service account ... does not exist." This resource calls the API that
# instantiates the agent and surfaces its email, removing the project-number
# string-construction hack and the lazy-creation race.
resource "google_project_service_identity" "firestore" {
  provider = google-beta
  project  = var.project_id
  service  = "firestore.googleapis.com"
}

# The service identity API returns the SA email synchronously, but the SA is
# not always immediately resolvable in IAM policies — propagation can take
# ~10–60s. Without this sleep, a fresh `terraform apply` hits a Error 400
# "Service account ... does not exist." on the binding below. Once the
# binding succeeds the first time, subsequent applies are no-ops.
resource "time_sleep" "wait_for_firestore_agent" {
  create_duration = "60s"

  depends_on = [google_project_service_identity.firestore]
}

# Grant the Firestore service agent encrypt/decrypt on the CMEK key.
resource "google_kms_crypto_key_iam_member" "firestore_agent" {
  crypto_key_id = google_kms_crypto_key.firestore.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.firestore.email}"

  depends_on = [time_sleep.wait_for_firestore_agent]
}

output "crypto_key_id" {
  value = google_kms_crypto_key.firestore.id
}
