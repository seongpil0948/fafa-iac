# module: secrets

Creates Secret Manager secret resources and IAM bindings. Does **not** store secret values in Terraform state.

## What it does

- Creates one `google_secret_manager_secret` per key listed in `var.secret_names` (with `prevent_destroy = true`).
- Grants `roles/secretmanager.secretAccessor` to the sync-runner SA on all secrets.

## Secret values

Values are **never** managed by Terraform. Populate them via:

```bash
bash scripts/seed-secrets.sh   # idempotent — only adds a new version when value changes
```

The list of secret keys is duplicated between this module (`var.secret_names`) and `scripts/seed-secrets.sh`. Keep them in sync when adding new secrets.

## Invariants

- `prevent_destroy = true` on every secret resource.
- Never reference secret values in Terraform locals, outputs, or variables.

## Inputs

| Name | Type | Description |
|------|------|-------------|
| `project_id` | `string` | GCP project ID. |
| `secret_names` | `list(string)` | Names of secrets to create. |
| `accessor_sa_email` | `string` | SA granted secretAccessor on all secrets. |

## Outputs

| Name | Description |
|------|-------------|
| `secret_refs_for_gcloud` | Map of secret name → `projects/ID/secrets/NAME` for use in deploy scripts. |
