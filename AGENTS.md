# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Terraform-only **provisioning** of GCP/Firebase infrastructure for the
[SiveraV2](https://github.com/seongpil0948/SiveraV2) project
(`fafa-255a2`, region `asia-northeast3`). Cloud Functions **source code**
lives in the SiveraV2 repo and is deployed independently via
`functions/scripts/deploy-all.sh` — Terraform owns only the function shell
(IAM, trigger, build SA). Treat anything under `modules/functions/` as
infra-only; never edit a function to change runtime behavior.

State backend: `gs://fafa-tf-state` (GCS, versioned). Configured in
[backend.tf](backend.tf).

## Common commands

```bash
# Validate (run before every commit/PR)
terraform fmt -recursive -check
terraform validate

# Plan/apply
terraform plan
terraform apply

# One-time, idempotent setup
bash scripts/bootstrap-state-bucket.sh   # creates gs://fafa-tf-state
bash scripts/apply-ttl.sh                # Firestore TTL (idempotent, exit 1 on failures)
bash scripts/setup-dlq.sh                # DLQ policy on Eventarc-managed Pub/Sub subscriptions
bash scripts/seed-secrets.sh             # push secret values from SiveraV2/apps/web/.env.local

# Target a single resource during recovery
terraform plan -target=module.functions.google_cloudfunctions2_function.https
```

There is no test suite — `terraform validate` + a clean `terraform plan` is
the gate.

## Critical invariants

These are easy to violate and expensive to fix.

1. **Firestore CMEK is create-time-only.** The live `(default)` database
   was first provisioned via the Firebase Console without CMEK. Do **not**
   set `module.firestore.cmek_key_name` — `main.tf:32` pins it to `""` and
   [modules/firestore/main.tf:75-79](modules/firestore/main.tf#L75-L79)
   adds `lifecycle.ignore_changes` for `type`, `location_id`, `cmek_config`.
   The KMS module still provisions a key for future (new) databases.

2. **Cloud Functions source is owned out-of-band.** Each
   `google_cloudfunctions2_function` has
   `lifecycle.ignore_changes` for `build_config[0].source`, `entry_point`,
   `runtime`, and several `service_config` knobs (memory, timeout, env vars,
   max instances). Don't try to deploy code from Terraform — use
   `SiveraV2/functions/scripts/deploy-all.sh`.

3. **Secret values must never land in Terraform state.** `modules/secrets`
   creates secret *resources* (with `prevent_destroy = true`) and IAM
   bindings only. Values come from `SiveraV2/apps/web/.env.local` via
   `scripts/seed-secrets.sh` (idempotent — only adds a new version when the
   value diverges). The list of secret keys is duplicated in
   [modules/secrets/main.tf:16-27](modules/secrets/main.tf#L16-L27) and
   [scripts/seed-secrets.sh:31-42](scripts/seed-secrets.sh#L31-L42); keep
   them in sync.

4. **The Firebase project and web app were imported, not created.** If
   state is rebuilt, re-run the `terraform import` commands in the README
   for `google_firebase_project.this`, `google_firebase_web_app.web`, and
   (if the `(default)` DB exists) `google_firestore_database.default` +
   `google_firebaserules_release.firestore`. If a plan ever proposes to
   *replace* the Firestore database, stop and import — never let it run.

5. **Vercel SA JSON key is manual and out of state.** Generated via
   `gcloud iam service-accounts keys create` (see README), pasted into the
   Vercel `GOOGLE_APPLICATION_CREDENTIALS_JSON` env var, then shredded
   locally. `*.json` is gitignored except a small allowlist — don't fight
   the gitignore by committing keys.

## Architecture in one breath

[main.tf](main.tf) wires eight modules in dependency order. Read it
top-to-bottom for the full picture; the modules below only describe what
*isn't* obvious from the code:

| Module | Non-obvious behavior |
|---|---|
| [`modules/project`](modules/project/) | Enables 9 APIs. Adding a new API? Add it here, not in an ad-hoc `google_project_service` elsewhere. |
| [`modules/kms`](modules/kms/) | CMEK keyring exists *for future use* — the live DB is not encrypted with it (see invariant #1). |
| [`modules/firestore`](modules/firestore/) | Loads `firebase/firestore.indexes.json` + `firebase/firestore.rules` from the **root** path (`${path.root}/firebase/...`), not the module path. Edit those files; don't add Terraform `google_firestore_index` resources by hand. |
| [`modules/iam`](modules/iam/) | Three SAs: `sa-sync-runner` (Functions runtime), `sa-scheduler-invoker` (Scheduler→Cloud Run OIDC), `sa-vercel-app` (Vercel→Firestore + mints OIDC tokens to call `sync-on-connect`). |
| [`modules/pubsub`](modules/pubsub/) | DLQ topic exists but the dead-letter *policy* is **not wired** — Eventarc-managed subscriptions need either an explicit `google_pubsub_subscription` or a gcloud reach-in. Tracked as a follow-up; don't assume DLQ is live. |
| [`modules/functions`](modules/functions/) | Resolves `project_number` dynamically via `data.google_project` to grant roles to the Gen 2 build SA (`<num>-compute@developer.gserviceaccount.com`); without these roles, first build fails with "missing permission on the build service account". Stub zip in `modules/functions/stub/` is the placeholder source. |
| [`modules/secrets`](modules/secrets/) | See invariant #3. Output `secret_refs_for_gcloud` is consumed by `SiveraV2/functions/scripts/deploy-all.sh`. |
| [`modules/scheduler`](modules/scheduler/) | OIDC-authenticated POST `{}` to function HTTPS URLs. Depends on `google_cloud_run_v2_service_iam_member.scheduler_invokes_https_functions` in root — keep that ordering. |

Cross-module IAM lives in [main.tf](main.tf#L67-L89), not inside `modules/iam`:
the Vercel SA's invoke permission on `sync-on-connect` and the Scheduler
SA's invoke permission on the three scheduled functions are bound at the
Cloud Run service level because that's where Gen 2 functions live.

## Provider versions

Pinned in [versions.tf](versions.tf): `google`/`google-beta` `~> 6.11`,
Terraform `>= 1.6.0`. `firebase`, `firestore` (beta-only), and
`firebaserules` resources all use the `google-beta` provider — keep that
in mind when adding resources.

## Repo-specific gotchas

- **`gsutil` is deprecated.** Use `gcloud storage` everywhere (the
  bootstrap script already does). Don't add `gsutil` calls.
- **TTL config can't be Terraform-managed yet** — `scripts/apply-ttl.sh`
  is the canonical setup for `oauthStates`, `syncRuns`, `amazonReportCache`,
  `usageLogs` (`.expiresAt`). Re-run after adding a new TTL collection.
- **DLQ policy is not wired via Terraform** — `scripts/setup-dlq.sh` attaches
  the dead-letter policy to Eventarc-managed Pub/Sub subscriptions. Run once
  after first apply. Terraform's Pub/Sub module only creates the DLQ topic; the
  policy attachment requires `gcloud pubsub subscriptions modify-push-config` because
  Eventarc manages the subscription lifecycle.
- **`terraform.tfvars` is gitignored**; only the `.example` is committed.
  Default values in `variables.tf` cover the production project, so a plan
  works without a tfvars file in most cases.
