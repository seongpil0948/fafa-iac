#!/usr/bin/env bash
#
# Create (or reconcile) the GCS bucket that holds Terraform remote state.
# Idempotent — re-running on an existing bucket only re-applies hardening flags.
#
# Uses `gcloud storage` exclusively. `gsutil` is deprecated:
#   https://cloud.google.com/storage/docs/gsutil-transition-to-gcloud
#
# Hardening applied:
#   - Versioning ON (so a corrupt apply can be rolled back to a prior state)
#   - Uniform bucket-level access (no fine-grained ACLs — IAM only)
#   - Public access prevention ENFORCED (defense-in-depth)
#   - Lifecycle rule: keep newest 10 noncurrent versions, delete the rest
#
set -euo pipefail

PROJECT="${PROJECT:-fafa-255a2}"
LOCATION="${LOCATION:-asia-northeast3}"
BUCKET="${BUCKET:-fafa-tf-state}"

# --- preconditions -----------------------------------------------------------
command -v gcloud >/dev/null 2>&1 || {
  echo "✗ gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install" >&2
  exit 1
}

# Application Default Credentials must be available for `terraform init`
# later. `gcloud storage` itself authenticates via gcloud's own credentials.
if ! gcloud auth print-access-token >/dev/null 2>&1; then
  echo "✗ gcloud is not logged in. Run: gcloud auth login && gcloud auth application-default login" >&2
  exit 1
fi

echo "▸ Project=${PROJECT}  Location=${LOCATION}  Bucket=gs://${BUCKET}"

# --- create if missing -------------------------------------------------------
if gcloud storage buckets describe "gs://${BUCKET}" --project="${PROJECT}" >/dev/null 2>&1; then
  echo "  · bucket already exists — will reconcile settings"
else
  echo "  · creating bucket"
  gcloud storage buckets create "gs://${BUCKET}" \
    --project="${PROJECT}" \
    --location="${LOCATION}" \
    --uniform-bucket-level-access \
    --public-access-prevention \
    --default-storage-class=STANDARD
fi

# --- reconcile hardening -----------------------------------------------------
echo "  · enabling object versioning"
gcloud storage buckets update "gs://${BUCKET}" \
  --project="${PROJECT}" \
  --versioning

echo "  · enforcing uniform bucket-level access"
gcloud storage buckets update "gs://${BUCKET}" \
  --project="${PROJECT}" \
  --uniform-bucket-level-access

echo "  · enforcing public access prevention"
gcloud storage buckets update "gs://${BUCKET}" \
  --project="${PROJECT}" \
  --public-access-prevention

# Lifecycle: cap noncurrent-version sprawl. State buckets rarely need >10
# rollbacks, and old state copies can leak secrets if a previous apply staged
# them inline.
LIFECYCLE_TMP="$(mktemp)"
trap 'rm -f "${LIFECYCLE_TMP}"' EXIT
cat >"${LIFECYCLE_TMP}" <<'JSON'
{
  "lifecycle": {
    "rule": [
      {
        "action": { "type": "Delete" },
        "condition": { "numNewerVersions": 10, "isLive": false }
      }
    ]
  }
}
JSON

echo "  · applying lifecycle (keep newest 10 noncurrent versions)"
gcloud storage buckets update "gs://${BUCKET}" \
  --project="${PROJECT}" \
  --lifecycle-file="${LIFECYCLE_TMP}"

echo "✓ State bucket ready: gs://${BUCKET}"
echo "  Now run: terraform init"
