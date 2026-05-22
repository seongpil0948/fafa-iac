---
name: terraform-drift-sync
description: 'Detect infrastructure drift and synchronize Terraform state safely using plan, import, and query workflows. Use for state recovery, imported Firebase resources, drift between live GCP and state, and avoiding destructive Firestore replacement in fafa-iac. Keywords: terraform drift, terraform import, state sync, firestore index drift, firebase imported resource, plan replace.'
argument-hint: 'Scope keyword (firestore | functions | iam | secrets | scheduler | pubsub | all) and optional drift symptom'
user-invocable: true
disable-model-invocation: false
---

# Terraform Drift Check And State Sync

Reconcile live GCP / Firebase infrastructure with Terraform state in `fafa-iac` without destructive replacement.

## When To Use

- `terraform plan` proposes create/replace for resources that already exist in GCP.
- State was rebuilt or migrated and previously imported resources are missing.
- A new index/secret/topic was added to config and you are unsure if it already exists upstream.
- Bulk discovery of importable resources is needed (`terraform query`).
- A scope keyword is passed as the skill argument (for example `firestore`) to limit the sweep.
- The **daily drift CI job** (`.github/workflows/terraform.yml` `drift` job, runs at 02:00 UTC) opened a GitHub Issue — investigate the plan output attached to the issue and use this skill to resolve.

## Safety Rules (hard stops)

1. Never run destructive state reset (`terraform state rm` on healthy resources, `-replace`, manual state file edits).
2. Each remote object maps to exactly one Terraform address. Re-importing duplicates corrupts state.
3. If `google_firestore_database.default` shows replace / destroy in plan: STOP. Block apply and require explicit user confirmation before any further action.
4. If `google_secret_manager_secret` shows destroy: STOP. `prevent_destroy = true` should already block it; investigate config drift instead.
5. Always run from repo root so `backend.tf` + providers load.
6. Never write secret values into state. Values flow through `scripts/seed-secrets.sh` only.
7. Do not try to "fix" drift on fields covered by `lifecycle.ignore_changes` (Firestore `type`/`location_id`/`cmek_config`, Cloud Functions `build_config[0].source`, etc.) — that drift is intentional.

## Inputs To Collect

1. Scope: which module(s) or addresses are affected (use the skill argument).
2. Drift symptom verbatim from plan (`+ create`, `~ update in-place`, `-/+ destroy then create`).
3. Whether the remote object actually exists (verify before importing — see step 3).
4. Resource-specific import ID format from provider docs (see "ID Format Recipes" below).

## Procedure

### 1. Baseline

```bash
terraform fmt -recursive -check
terraform validate
terraform plan -no-color
```

Record the `Plan: X to add, Y to change, Z to destroy` line.

### 2. Narrow the scope (faster, less noisy)

When a scope is given, target it. This produces a focused plan you can reason about:

```bash
terraform plan -no-color -target=module.firestore
terraform plan -no-color -target='module.firestore.google_firestore_index.composite'
```

`-target` is a triage tool only — never use it for the final apply gate.

### 3. Categorize drift

| Case | Plan signal | Action |
|---|---|---|
| A. Exists remotely, missing in state | `+ create` for a resource you know already exists | Import (step 5) |
| B. Immutable field replacement | `-/+` on Firestore DB, KMS key, etc. | STOP — invariants, do not apply |
| C. Config-only drift | `~ update in-place` matching intended config change | Apply normally |
| D. Out-of-band managed | Changes on `build_config.source`, function source zip | Ignore — covered by `lifecycle.ignore_changes` or deployed by `deploy-all.sh` |
| E. Genuinely new resource | `+ create` and confirmed absent in GCP | Apply normally |

### 4. Verify remote existence BEFORE importing

Importing a resource that does not exist will fail; assuming existence and skipping verification wastes a state slot. Confirm with `gcloud` first.

```bash
# Firestore composite indexes
gcloud firestore indexes composite list --project=fafa-255a2 --format=json

# Firebase project / web app
gcloud firebase projects:list
gcloud firebase apps:list WEB --project=fafa-255a2

# Cloud Functions Gen 2
gcloud functions list --project=fafa-255a2 --regions=asia-northeast3 --gen2

# Cloud Scheduler jobs
gcloud scheduler jobs list --project=fafa-255a2 --location=asia-northeast3

# Pub/Sub topics
gcloud pubsub topics list --project=fafa-255a2

# Secret Manager secrets (resource only, never values)
gcloud secrets list --project=fafa-255a2

# KMS keys
gcloud kms keys list --project=fafa-255a2 --location=asia-northeast3 --keyring=<ring>
```

If the resource is absent → it is Case E, not a drift problem. Just `terraform apply`.

### 5. Ensure config block exists, then import

The Terraform address must already exist in HCL. For `for_each` resources the key must match what the config computes (in this repo, indexes use `md5(jsonencode(idx))`).

Single-resource import:

```bash
terraform import '<ADDRESS>' '<ID>'
```

For `for_each` keys, ALWAYS quote the whole address (bash globbing + brackets):

```bash
terraform import 'module.firestore.google_firestore_index.composite["<md5-key>"]' \
  'projects/fafa-255a2/databases/(default)/collectionGroups/<col>/indexes/<INDEX_ID>'
```

### 6. ID Format Recipes (Google provider)

| Resource | Import ID format | Example |
|---|---|---|
| `google_firebase_project` | `<project_id>` | `fafa-255a2` |
| `google_firebase_web_app` | `projects/<project>/webApps/<appId>` | `projects/fafa-255a2/webApps/1:1060…:web:e216…` |
| `google_firestore_database` | `projects/<project>/databases/<db>` | `projects/fafa-255a2/databases/(default)` |
| `google_firestore_index` | `projects/<project>/databases/<db>/collectionGroups/<col>/indexes/<INDEX_ID>` | `projects/fafa-255a2/databases/(default)/collectionGroups/credentials/indexes/CICAgJiUpoML` |
| `google_firebaserules_release` | `projects/<project>/releases/<name>` | `projects/fafa-255a2/releases/cloud.firestore` |
| `google_pubsub_topic` | `projects/<project>/topics/<name>` | `projects/fafa-255a2/topics/sync-credential-requested` |
| `google_secret_manager_secret` | `projects/<project>/secrets/<name>` | `projects/fafa-255a2/secrets/AMAZON_CLIENT_ID` |
| `google_cloud_scheduler_job` | `projects/<project>/locations/<loc>/jobs/<name>` | `projects/fafa-255a2/locations/asia-northeast3/jobs/sync-dispatch` |
| `google_cloudfunctions2_function` | `projects/<project>/locations/<loc>/functions/<name>` | `projects/fafa-255a2/locations/asia-northeast3/functions/sync-credential` |
| `google_service_account` | `projects/<project>/serviceAccounts/<email>` | `projects/fafa-255a2/serviceAccounts/sa-vercel-app@fafa-255a2.iam.gserviceaccount.com` |
| `google_kms_crypto_key` | `projects/<project>/locations/<loc>/keyRings/<ring>/cryptoKeys/<key>` | — |

When unsure, attempt the import and read the provider error — it usually echoes the expected ID format.

### 7. Re-plan after each import

```bash
terraform plan -no-color -target=<module>
```

The previously planned `+ create` for that address should disappear. If `~ update in-place` appears instead, that is normal — Terraform is aligning fields to config.

### 8. Bulk discovery (optional)

```bash
terraform query
terraform query -generate-config-out=to-import/generated.tf
terraform query -generate-config-out=generated.tf -json
```

Use this when many resources of the same type need importing. Review and trim the generated file before committing.

### 9. Handle complex/secondary imports

- If an import surfaces secondary state objects, add resource blocks for each before applying.
- For pure address renames, use `terraform state mv` (non-destructive). Never delete + recreate.

### 10. Final gate

Run an UN-targeted plan:

```bash
terraform plan -no-color
```

Required before apply:

- No `+ create` for resources confirmed to exist remotely.
- No `-/+` replacement on `google_firestore_database.default`, `google_kms_crypto_key`, or `google_secret_manager_secret`.
- Remaining diffs are intended config changes or known out-of-band managed fields.

If Firestore replacement still appears → STOP, request explicit user confirmation, do not apply.

## Decision Branches

1. Import error "Resource already managed by Terraform" → already in state. Skip; investigate plan for the real drift cause.
2. Import error "ID … is invalid" → wrong ID format. Check the recipe table or provider docs.
3. Plan still proposes replace after import → check `lifecycle.ignore_changes` and that the imported object actually matches the config keys (especially `for_each` md5 keys).
4. Drift on fields ignored by lifecycle → expected. Do not act.
5. Resource is provisioned by an out-of-band script (`deploy-all.sh`, `seed-secrets.sh`, `apply-ttl.sh`) → do not import; the shell is owned by Terraform, the contents are not.
6. Plan fails on missing `project_number` variable → create `terraform.tfvars` from `terraform.tfvars.example`.

## Completion Checks

1. `terraform validate` → success.
2. Final un-targeted `terraform plan` shows only intended changes.
3. No destructive replacement pending on Firestore default DB, KMS keys, or Secret Manager secrets.
4. Every imported object maps to exactly one Terraform address (`terraform state list | sort | uniq -d` returns nothing).
5. If apply is intended next, save the plan: `terraform plan -out=tfplan` and `terraform apply tfplan`.

## fafa-iac Specific Invariants

- Firestore CMEK is create-time only. The live `(default)` DB is non-CMEK; `cmek_key_name` is intentionally empty.
- Cloud Functions source/runtime knobs are out-of-band (`functions/scripts/deploy-all.sh`). Lifecycle ignores `build_config[0].source`.
- Composite index keys use `md5(jsonencode(idx))` from `firebase/firestore.indexes.json`. Editing that file changes the key — the old key plans as destroy and the new key plans as create even though the index content is identical. Use `terraform state mv` to preserve the imported index.
- TTL policies are applied via `scripts/apply-ttl.sh`, not Terraform.
- Secret values are seeded via `scripts/seed-secrets.sh`. Only the secret resource + IAM live in Terraform.

## Worked Example: Firestore Index Drift (May 2026)

Symptom: plan proposed `+ create` for one composite index under `module.firestore.google_firestore_index.composite["62f7003a51c1a37b79697ef355f8c994"]`.

```bash
# 1. Verify it exists remotely
gcloud firestore indexes composite list --project=fafa-255a2 --format=json \
  | jq '.[] | select(.fields | length == 3)'
# → found INDEX_ID=CICAgJiUpoML on collectionGroup=credentials (uid ASC, createdAt DESC)

# 2. Import into the exact for_each-keyed address (quoted)
terraform import \
  'module.firestore.google_firestore_index.composite["62f7003a51c1a37b79697ef355f8c994"]' \
  'projects/fafa-255a2/databases/(default)/collectionGroups/credentials/indexes/CICAgJiUpoML'

# 3. Confirm Firestore module is clean
terraform plan -no-color -target=module.firestore
# → No changes.

# 4. Final un-targeted plan
terraform plan -no-color
# → Plan: 0 to add, 2 to change, 0 to destroy (only intended function updates remain)
```

## References

- https://developer.hashicorp.com/terraform/cli/import
- https://developer.hashicorp.com/terraform/cli/import/usage
- https://developer.hashicorp.com/terraform/cli/commands/import
- https://developer.hashicorp.com/terraform/cli/commands/query
- https://developer.hashicorp.com/terraform/cli/state/resource-addressing
- [fafa-iac README](../../../README.md)
- [modules/firestore/main.tf](../../../modules/firestore/main.tf)
