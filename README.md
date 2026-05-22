# fafa-iac

Terraform-managed GCP infrastructure for the SiveraV2 (Firebase + GCP) backend.

- **Project**: `fafa-255a2` (existing Firebase project — imported, not created)
- **Region**: `asia-northeast3` (Seoul)
- **State**: GCS backend `fafa-tf-state` (versioned)
- **Scope**: provision-only. Cloud Functions source is deployed via
  `bash functions/scripts/deploy-all.sh` in the [SiveraV2 repo](https://github.com/seongpil0948/SiveraV2);
  Terraform only owns the function shell + IAM + trigger (lifecycle ignores `build_config.source`).
- **Companion repo**: [SiveraV2](https://github.com/seongpil0948/SiveraV2) — Next.js app + Cloud Functions source.

## Layout

```
fafa-iac/
├── versions.tf, providers.tf, backend.tf
├── variables.tf, outputs.tf, main.tf
├── terraform.tfvars.example
├── firebase/                       # firestore.rules + firestore.indexes.json (consumed by Terraform)
├── scripts/
│   ├── bootstrap-state-bucket.sh   # One-time GCS state bucket (gcloud storage, idempotent)
│   ├── apply-ttl.sh                # Manual TTL setup (idempotent, tracks succeeded/failed per collection)
│   ├── setup-dlq.sh                # Attach DLQ policy to Eventarc-managed Pub/Sub subscriptions
│   └── seed-secrets.sh             # Seed/update Secret Manager values from apps/web/.env.local
└── modules/
    ├── project/          # google_project_service (APIs)
    ├── kms/              # CMEK keyring for Firestore (asia-northeast3)
    ├── firestore/        # google_firestore_database + Firebase project/web app (imported)
    ├── iam/              # sa-sync-runner, sa-scheduler-invoker, sa-vercel-app
    ├── pubsub/           # sync-credential-requested, fcm-send-requested, fafa-dead-letter
    ├── secrets/          # Secret Manager resources + IAM bindings for platform OAuth secrets
    ├── functions/        # google_cloudfunctions2_function placeholders (stub source)
    └── scheduler/        # sync-dispatch, cleanup, expire-trials (OIDC)
```

## What each module provides

| Module | Resources | Notes |
|---|---|---|
| `project` | `google_project_service.*` | APIs enabled: firestore, identitytoolkit, cloudfunctions, cloudscheduler, pubsub, secretmanager, cloudkms, firebase, fcm |
| `kms` | `google_kms_key_ring`, `google_kms_crypto_key` | CMEK for Firestore; rotation managed |
| `firestore` | `google_firestore_database` + imported Firebase project/web app | Native mode, asia-northeast3, CMEK-encrypted, delete protection ON |
| `iam` | 3 SAs + role bindings | `sa-sync-runner` (Functions runtime), `sa-scheduler-invoker` (Scheduler→Run), `sa-vercel-app` (Vercel→Firestore+OIDC) |
| `pubsub` | 2 topics + DLQ | `sync-credential-requested`, `fcm-send-requested`, `fafa-dead-letter` |
| `secrets` | 10 `google_secret_manager_secret` + IAM bindings | Platform OAuth credentials (AMAZON, GOOGLE, META, TIKTOK); `sa-sync-runner` gets `secretAccessor`. `prevent_destroy = true`. Values seeded out-of-band (never in TF state). |
| `functions` | 6 `google_cloudfunctions2_function` shells | Source updated out-of-band; lifecycle ignores `build_config[0].source` |
| `scheduler` | 3 `google_cloud_scheduler_job` | `*/15 * * * *` sync-dispatch, `0 2 * * *` cleanup, `0 3 * * *` expire-trials |

## Bootstrap

```bash
# 1. One-time auth
gcloud auth login
gcloud auth application-default login

# 2. Create the GCS state bucket (idempotent; uses `gcloud storage`).
#    Replaces deprecated `gsutil mb` + `gsutil versioning set`.
#    Hardens with versioning + UBLA + public-access-prevention + lifecycle.
bash scripts/bootstrap-state-bucket.sh

# 3. Create the local tfvars file. variables.tf declares `project_number`
#    with no default, so without this Terraform will prompt for it on every
#    plan / import. The example file already contains the right values.
cp terraform.tfvars.example terraform.tfvars

# 4. Import existing Firebase project
terraform init
terraform import module.firestore.google_firebase_project.this fafa-255a2
terraform import module.firestore.google_firebase_web_app.web \
  projects/fafa-255a2/webApps/1:1060546657339:web:e216a7a4b567be6ad0b01e

terraform plan
terraform apply
```

> **Re-running import**: imports are idempotent in the sense that re-importing
> an already-tracked resource fails with "Resource already managed by
> Terraform". If you see that, the import has already happened — skip and run
> `terraform plan` directly.

### Importing a console-created (default) database

If the `(default)` database was ever created via the Firebase Console (the
CMEK + Terraform create flow can take 15-20 min and is sometimes interrupted),
import it instead of letting Terraform recreate it:

```bash
terraform import 'module.firestore.google_firestore_database.default' \
  'projects/fafa-255a2/databases/(default)'

terraform import 'module.firestore.google_firebaserules_release.firestore' \
  'projects/fafa-255a2/releases/cloud.firestore'

# Verify alignment — the resulting plan should NOT propose to replace the
# database. cmek_config + type + location_id are pinned via lifecycle.ignore_changes.
terraform plan
```

Note: Firestore CMEK is a create-time-only setting. The KMS module still
provisions the CMEK key for future use, but `cmek_key_name` is intentionally
left empty in `main.tf` so the imported, non-CMEK database does not show a
destructive diff.

> **gsutil → gcloud storage**: Google deprecated `gsutil` in favor of
> `gcloud storage`. See the [transition guide][gcloud-transition]. The
> bootstrap script above uses only the supported CLI. If you must inline the
> commands, the equivalents are:
>
> ```bash
> gcloud storage buckets create gs://fafa-tf-state \
>   --project=fafa-255a2 --location=asia-northeast3 \
>   --uniform-bucket-level-access --public-access-prevention
> gcloud storage buckets update gs://fafa-tf-state --versioning
> ```
>
> [gcloud-transition]: https://cloud.google.com/storage/docs/gsutil-transition-to-gcloud

## Vercel service-account key (manual, out of Terraform state)

> Preconditions:
> - `terraform apply` has succeeded (creates the SA at `modules/iam/main.tf`).
> - Active gcloud account has `roles/iam.serviceAccountKeyAdmin` on the SA
>   (the project owner role covers this). Verify with the active account:
>   ```bash
>   gcloud config list account project
>   gcloud iam service-accounts describe \
>     sa-vercel-app@fafa-255a2.iam.gserviceaccount.com \
>     --project=fafa-255a2
>   ```
>   If you see `ERROR: NOT_FOUND: Unknown service account`, either the SA
>   has not been provisioned yet (run `terraform apply` first) or your
>   active gcloud project is a different one — always pass `--project`
>   explicitly as below.

```bash
gcloud iam service-accounts keys create sa-vercel-app.json \
  --iam-account=sa-vercel-app@fafa-255a2.iam.gserviceaccount.com \
  --project=fafa-255a2
# Paste contents of sa-vercel-app.json into Vercel env var
#   GOOGLE_APPLICATION_CREDENTIALS_JSON (Production, Preview, Development)
# Delete the local file immediately:
shred -u sa-vercel-app.json
```

> **Org policy gotcha**: if `iam.disableServiceAccountKeyCreation` is enforced
> on the org or folder, this command fails with `FAILED_PRECONDITION` rather
> than `NOT_FOUND`. In that case use Workload Identity Federation from Vercel
> instead of a long-lived JSON key (out of scope for this repo).

## Firestore TTL policies (manual, not yet supported in Terraform google provider)

```bash
# Applies TTL on oauthStates / syncRuns / amazonReportCache / usageLogs.
bash scripts/apply-ttl.sh
```

## Vercel env vars sourced from Terraform outputs

```bash
# After `terraform apply` succeeds:
terraform output -json function_urls
#   →  copy `sync-on-connect` URL into Vercel env `SYNC_ON_CONNECT_URL`
```

The Vercel app uses `sa-vercel-app` to mint OIDC tokens via
`google-auth-library` and calls `SYNC_ON_CONNECT_URL` immediately after
OAuth completes. The Cloud Function `sync-on-connect` is `ALLOW_ALL`
ingress but guarded by `roles/run.invoker` granted exclusively to
`sa-vercel-app` (see `main.tf:65-72`).

## Deploy pipeline

1. `terraform plan && terraform apply` (this repo) — provisions infra, Secret Manager resources + IAM.
2. `bash scripts/apply-ttl.sh` (one-time after first apply, idempotent thereafter — re-running skips already-configured collections).
3. `bash scripts/setup-dlq.sh` (one-time after first apply — attaches DLQ policy to Eventarc-managed Pub/Sub subscriptions).
4. `bash scripts/seed-secrets.sh` — pushes OAuth secret values from `SiveraV2/apps/web/.env.local`
   into Secret Manager (idempotent: only adds new version if value differs). In CI, set `CI=true` —
   the script exits 1 if any expected secret is missing. Run whenever secret values change.
   **Never commit secret values to Terraform state.**
5. `cd .../SiveraV2 && bash functions/scripts/deploy-all.sh` — esbuild-bundles Cloud Functions
   source and deploys with `gcloud functions deploy --gen2`.
6. `terraform output function_urls` → set `SYNC_ON_CONNECT_URL` Vercel env var.
7. `git push origin <branch>` → Vercel webhook builds.

## Secret Manager secrets

Secrets are provisioned by `modules/secrets` (resource + IAM) but values are seeded
separately via `scripts/seed-secrets.sh`. This keeps secret material out of Terraform
state and remote backends.

| Secret name | Used by | Notes |
|---|---|---|
| `AMAZON_CLIENT_ID` / `AMAZON_CLIENT_SECRET` | `sync-credential` Cloud Function | LWA OAuth |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` / `GOOGLE_DEVELOPER_TOKEN` | `sync-credential` | Ads API |
| `META_APP_ID` / `META_APP_SECRET` | `sync-credential` | Graph API |
| `META_LOGIN_CONFIG_ID` | Next.js web only (OAuth callback) | Not mounted on Cloud Functions |
| `TIKTOK_APP_ID` / `TIKTOK_APP_SECRET` | `sync-credential` | Business API |

To add/update a single secret value manually:

```bash
echo -n "VALUE" | gcloud secrets versions add SECRET_NAME \
  --project=fafa-255a2 --data-file=-
```

## Validation

Static checks before every commit / PR:

```bash
terraform fmt -recursive -check
terraform validate
```

CI workflow (`.github/workflows/terraform.yml`) runs four jobs automatically:
- **validate**: `fmt -check` + `validate` on every push
- **plan**: posts plan diff as a PR comment on every pull request
- **apply**: auto-applies on merge to `main` (requires `production` environment approval)
- **drift**: daily scheduled `plan -detailed-exitcode`; opens a GitHub Issue if drift detected

State bucket sanity:

```bash
gcloud storage buckets describe gs://fafa-tf-state --project=fafa-255a2 \
  --format='value(versioning.enabled,iamConfiguration.uniformBucketLevelAccess.enabled,iamConfiguration.publicAccessPrevention)'
# Expect: True   True   enforced
```
