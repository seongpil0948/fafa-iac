# fafa-iac Architecture

Infrastructure provisioning for **SiveraV2** on GCP/Firebase (`fafa-255a2`, `asia-northeast3`).

## Module dependency graph

```mermaid
graph TD
    project[project<br/><small>enables APIs</small>]
    kms[kms<br/><small>KMS keyring+key</small>]
    firestore[firestore<br/><small>DB + rules + indexes</small>]
    iam[iam<br/><small>service accounts</small>]
    pubsub[pubsub<br/><small>topics + DLQ</small>]
    secrets[secrets<br/><small>Secret Manager</small>]
    functions[functions<br/><small>CF Gen2 shells</small>]
    scheduler[scheduler<br/><small>Cloud Scheduler jobs</small>]

    project --> kms
    project --> firestore
    project --> iam
    project --> pubsub
    project --> secrets
    iam --> functions
    pubsub --> functions
    secrets --> functions
    functions --> scheduler
    iam --> scheduler
```

## Sync pipeline (runtime, not Terraform)

```mermaid
sequenceDiagram
    participant CS as Cloud Scheduler
    participant SD as sync-dispatch (HTTPS CF)
    participant PS as Pub/Sub<br/>sync-credential-requested
    participant SC as sync-credential (Pub/Sub CF)
    participant FF as Firestore

    CS->>SD: POST {} (OIDC, every hour)
    SD->>FF: query credentials (overdue)
    SD->>PS: publish message per credential
    PS->>SC: Eventarc trigger
    SC->>FF: write dailyMetrics / syncRuns
```

## IAM matrix

| Identity | Role | Scope |
|----------|------|-------|
| `sa-sync-runner` | `roles/datastore.user` | project |
| `sa-sync-runner` | `roles/secretmanager.secretAccessor` | each secret |
| `sa-sync-runner` | `roles/pubsub.publisher` | `sync-credential-requested`, `fcm-send-requested` |
| `sa-scheduler-invoker` | `roles/run.invoker` | sync-dispatch, cleanup, expire-trials Cloud Run services |
| `sa-vercel-app` | `roles/datastore.viewer` | project |
| `sa-vercel-app` | `roles/iam.serviceAccountTokenCreator` | self (to mint OIDC tokens) |
| `sa-vercel-app` | `roles/run.invoker` | sync-on-connect Cloud Run service |
| Build SA (`<num>-compute`) | `roles/storage.objectViewer` | artifact bucket |
| Build SA (`<num>-compute`) | `roles/artifactregistry.reader` | project |

## State backend

GCS bucket: `gs://fafa-tf-state/fafa-iac/` (versioned, `asia-northeast3`).
Run `scripts/bootstrap-state-bucket.sh` once if the bucket doesn't exist.

## Terraform version requirements

| Component | Version |
|-----------|---------|
| Terraform | `>= 1.6.0` |
| `hashicorp/google` | `~> 6.11` |
| `hashicorp/google-beta` | `~> 6.11` |
| `hashicorp/archive` | `~> 2.4` |
| `hashicorp/time` | `~> 0.12` |
