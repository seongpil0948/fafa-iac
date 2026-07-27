#!/usr/bin/env bash
#
# Apply Firestore TTL policies on the four ephemeral collections.
#
# The google Terraform provider does NOT yet support `google_firestore_field`
# with TTL config, so this script is the canonical way to enable TTL. It is
# idempotent — re-running has no adverse effect.
#
# Reference: https://firebase.google.com/docs/firestore/ttl
#
set -euo pipefail

PROJECT="${PROJECT:-fafa-255a2}"

# --- preconditions -----------------------------------------------------------
command -v gcloud >/dev/null 2>&1 || {
  echo "✗ gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install" >&2
  exit 1
}

if ! gcloud auth print-access-token >/dev/null 2>&1; then
  echo "✗ gcloud is not logged in. Run: gcloud auth login" >&2
  exit 1
fi

# Verify the project exists and the caller can see it. Cheaper than waiting
# for the first `gcloud firestore` call to fail with an opaque permission error.
if ! gcloud projects describe "${PROJECT}" >/dev/null 2>&1; then
  echo "✗ Cannot describe project ${PROJECT}. Check spelling, or run: gcloud auth login" >&2
  exit 1
fi

echo "▸ Applying Firestore TTL policies on project=${PROJECT}"

succeeded=0
failed=0

apply_ttl() {
  local COLLECTION_GROUP="$1"
  local FIELD="$2"

  # Idempotency check: skip if TTL is already configured for this field.
  if timeout 10s gcloud firestore fields describe "${FIELD}" \
       --collection-group="${COLLECTION_GROUP}" \
       --project="${PROJECT}" \
       --format="value(ttlConfig)" \
       --quiet 2>/dev/null | grep -q "state"; then
    echo "  = ${COLLECTION_GROUP}.${FIELD}: TTL already enabled — skipping"
    succeeded=$((succeeded + 1))
    return
  fi

  echo "  · ${COLLECTION_GROUP}.${FIELD}: enabling TTL"
  if timeout 30s gcloud firestore fields ttls update "${FIELD}" \
       --collection-group="${COLLECTION_GROUP}" \
       --enable-ttl \
       --project="${PROJECT}" \
       --quiet; then
    succeeded=$((succeeded + 1))
  else
    echo "  ✗ ${COLLECTION_GROUP}.${FIELD}: failed" >&2
    failed=$((failed + 1))
  fi
}

apply_ttl oauthStates       expiresAt
apply_ttl syncRuns          expiresAt
apply_ttl amazonMetricCache expiresAt
apply_ttl amazonReportCache expiresAt
apply_ttl usageLogs         expiresAt

# NOTE deliberately ABSENT: amazonReports and reportJobs. Both persist rows
# in a `rows` subcollection, which Firestore TTL cannot cascade to — a TTL
# reaper deleting the parent orphans the rows forever. The daily `cleanup`
# Cloud Function is the deleter of record for these two collections
# (cascade: drain rows, then delete parent). Their TTL policies were
# disabled on 2026-07-27; do not re-add them here.

# Raw platform metric mirrors (90-day retention for reconciliation/audit).
apply_ttl dailyMetrics_raw             expiresAt
apply_ttl campaignDailyMetrics_raw     expiresAt
apply_ttl adGroupDailyMetrics_raw      expiresAt
apply_ttl adSetDailyMetrics_raw        expiresAt
apply_ttl adDailyMetrics_raw           expiresAt
apply_ttl gmvMaxItemDailyMetrics_raw   expiresAt

echo ""
echo "✓ TTL policies done. succeeded=${succeeded} failed=${failed}"
if [[ "${failed}" -gt 0 ]]; then
  echo "✗ ${failed} collection(s) failed — review errors above and re-run." >&2
  exit 1
fi
echo "  Documents past their expiresAt will be deleted within ~24h."
