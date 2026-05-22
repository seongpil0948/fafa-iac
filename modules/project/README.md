# module: project

Enables required GCP APIs for the `fafa-255a2` project.

## What it does

- Enables 9 APIs via `google_project_service` (one resource per API, with `disable_on_destroy = false`).
- If you need a new API, add it here — do **not** create ad-hoc `google_project_service` resources elsewhere.

## Current APIs

| API | Purpose |
|-----|---------|
| `firestore.googleapis.com` | Cloud Firestore |
| `firebase.googleapis.com` | Firebase project surface |
| `cloudfunctions.googleapis.com` | Cloud Functions Gen 2 |
| `run.googleapis.com` | Cloud Run (Gen 2 functions run here) |
| `pubsub.googleapis.com` | Pub/Sub (sync pipeline) |
| `cloudscheduler.googleapis.com` | Cloud Scheduler |
| `secretmanager.googleapis.com` | Secret Manager |
| `cloudkms.googleapis.com` | Cloud KMS (CMEK, future use) |
| `iam.googleapis.com` | IAM API |

## Inputs

| Name | Type | Description |
|------|------|-------------|
| `project_id` | `string` | GCP project ID. |

## Outputs

None.
