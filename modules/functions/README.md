# module: functions

Provisions Cloud Functions Gen 2 shells (IAM, triggers, build SA grants).

## What it does

- Creates one `google_cloudfunctions2_function` per function entry in `var.functions`.
- Grants required IAM roles to the build SA (`<project_number>-compute@developer.gserviceaccount.com`) to allow first-build success.
- Wires Pub/Sub Eventarc triggers for event-driven functions.

## Critical invariants

- **Source code is not managed here.** `lifecycle.ignore_changes` covers `build_config[0].source`, `entry_point`, `runtime`, and key `service_config` fields (memory, timeout, env vars, max instances, secret env vars).
- **Deploy source via** `SiveraV2/functions/scripts/deploy-all.sh` — never via Terraform.
- The stub zip in `stub/` is a placeholder used only for the initial `terraform apply` that creates the function shell.

## Adding a new function

1. Add the function entry to `var.functions` in `main.tf`.
2. Run `terraform apply` to create the shell + IAM.
3. Deploy source with `deploy-all.sh`.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `project_id` | `string` | — | GCP project ID. |
| `project_number` | `string` | — | GCP project number (for build SA). |
| `region` | `string` | — | Deployment region. |
| `sync_runner_sa_email` | `string` | — | Runtime SA email. |
| `sync_credential_topic_id` | `string` | — | Pub/Sub topic for Eventarc trigger. |
| `https_function_config` | `object({available_memory, timeout_seconds, max_instance_count})` | `{512Mi, 540, 10}` | Resource config for HTTPS-triggered functions (sync-on-connect, sync-dispatch, cleanup, expire-trials). Overridable; changes take effect on next `terraform apply` but `lifecycle.ignore_changes` covers these fields — use `gcloud functions deploy` to update live resources. |
| `pubsub_function_config` | `object({available_memory, timeout_seconds, max_instance_count})` | `{1Gi, 540, 5}` | Resource config for Pub/Sub-triggered functions (sync-credential, send-fcm). Higher memory default for platform API calls. `min_instance_count=0` (cold start acceptable). |

## Outputs

| Name | Description |
|------|-------------|
| `function_urls` | Map of function name → HTTPS URL. |
