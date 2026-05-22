# module: kms

Provisions a Cloud KMS keyring and key for future CMEK use.

## What it does

- Creates a KMS keyring in `asia-northeast3`.
- Creates a symmetric encryption key (`GOOGLE_SYMMETRIC_ENCRYPTION`).
- **Does not** encrypt the live Firestore `(default)` database — that database was created before CMEK support was added and cannot be encrypted retroactively.

## Critical invariant

Do **not** set `cmek_key_name` in the `firestore` module for the existing database.
`modules/firestore/main.tf` has `lifecycle.ignore_changes` for `cmek_config` to prevent accidental replacement.

## Inputs

| Name | Type | Description |
|------|------|-------------|
| `project_id` | `string` | GCP project ID. |
| `region` | `string` | GCP region for the keyring. |
| `key_name` | `string` | Name of the KMS key to create. |

## Outputs

| Name | Description |
|------|-------------|
| `key_id` | Full resource ID of the KMS key (for future use). |
