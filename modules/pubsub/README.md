# module: pubsub

Provisions Pub/Sub topics and a DLQ topic for the sync pipeline.

## Topics

| Topic | Purpose |
|-------|---------|
| `sync-credential-requested` | Main sync trigger. `sync-dispatch` publishes here; `sync-credential` is triggered via Eventarc. |
| `fcm-send-requested` | FCM notification trigger. Published on `auth_required` or `consecutiveFailures >= 3`. |
| `sync-credential-dlq` | Dead-letter destination (created but policy not yet wired — see note below). |

## Dead-letter policy

The DLQ topic exists, but the dead-letter **policy** is not attached to the Eventarc-managed subscriptions by Terraform, because Eventarc owns those subscriptions.
Run `scripts/setup-dlq.sh` (idempotent) to attach the policy dynamically via `gcloud`.

## Inputs

| Name | Type | Description |
|------|------|-------------|
| `project_id` | `string` | GCP project ID. |

## Outputs

| Name | Description |
|------|-------------|
| `sync_credential_topic_id` | Resource ID of `sync-credential-requested`. |
| `fcm_topic_id` | Resource ID of `fcm-send-requested`. |
