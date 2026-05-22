# module: iam

Provisions service accounts and IAM bindings for the sync pipeline.

## Service accounts

| SA name | Purpose |
|---------|---------|
| `sa-sync-runner` | Cloud Functions Gen 2 runtime identity. Reads/writes Firestore, accesses Secret Manager, publishes to Pub/Sub. |
| `sa-scheduler-invoker` | Cloud Scheduler → Cloud Run OIDC invoker. Granted `roles/run.invoker` on scheduled functions. |
| `sa-vercel-app` | Vercel app identity. Reads Firestore, mints OIDC tokens to call `sync-on-connect`. |

## Notes

- Cross-module IAM bindings (e.g., Scheduler SA invoking specific Cloud Run services) live in `main.tf` at the root, not here.
- The Vercel SA JSON key is generated manually via `gcloud iam service-accounts keys create` and is **not** stored in Terraform state. See `README.md` for the procedure.

## Inputs

| Name | Type | Description |
|------|------|-------------|
| `project_id` | `string` | GCP project ID. |

## Outputs

| Name | Description |
|------|-------------|
| `sync_runner_sa_email` | Email of `sa-sync-runner`. |
| `scheduler_invoker_sa_email` | Email of `sa-scheduler-invoker`. |
| `vercel_app_sa_email` | Email of `sa-vercel-app`. |
