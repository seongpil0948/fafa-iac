#!/usr/bin/env bash
# setup-dlq.sh — Attach the dead-letter policy to the Eventarc-managed
# subscriptions for sync-credential, send-fcm, process-amazon-report and
# process-report.
#
# Terraform provisions the DLQ *topic* (fafa-dead-letter) but cannot modify
# Eventarc-managed subscriptions. Run this script once after `terraform apply`
# on a fresh project and after any Function re-creation.
#
# Safe to re-run: gcloud update is idempotent.
#
# Usage:
#   bash scripts/setup-dlq.sh
#   PROJECT=fafa-255a2 bash scripts/setup-dlq.sh

set -euo pipefail

PROJECT="${PROJECT:-fafa-255a2}"
REGION="${REGION:-asia-northeast3}"
MAX_DELIVERY_ATTEMPTS="${MAX_DELIVERY_ATTEMPTS:-5}"

DLQ_TOPIC="projects/${PROJECT}/topics/fafa-dead-letter"

echo "▶ Attaching DLQ to Eventarc-managed subscriptions"
echo "  project : ${PROJECT}"
echo "  region  : ${REGION}"
echo "  dlq     : fafa-dead-letter"
echo ""

# Resolve the two Eventarc-managed subscriptions. Eventarc names them
# deterministically using the function name, but the prefix can vary by
# region and project. We query dynamically to be robust.
get_eventarc_sub() {
  local TOPIC_FILTER="$1"
  # Eventarc-managed subscriptions are named `eventarc-<region>-<function>-…`.
  # Their only Eventarc label (`goog-eventarc`) has an EMPTY value, which
  # gcloud's `labels.key:*` presence filter does not match — so filter by
  # topic and match the deterministic name prefix instead (verified on
  # fafa-255a2 2026-07-17).
  # NB: exact-match the full topic path — `topic:report-requested` would
  # substring-match `amazon-report-requested` and update the wrong sub.
  gcloud pubsub subscriptions list \
    --project="${PROJECT}" \
    --filter="topic=\"projects/${PROJECT}/topics/${TOPIC_FILTER}\" AND name:eventarc-" \
    --format="value(name)" \
    2>/dev/null | head -1
}

attach_dlq() {
  local NAME="$1"
  local SUB="$2"
  if [[ -z "${SUB}" ]]; then
    echo "  ✗ ${NAME}: no Eventarc subscription found — function not deployed yet?" >&2
    return 1
  fi

  echo "  · ${NAME} → $(basename "${SUB}")"
  gcloud pubsub subscriptions modify-push-config "${SUB}" \
    --project="${PROJECT}" \
    --dead-letter-topic="${DLQ_TOPIC}" \
    --max-delivery-attempts="${MAX_DELIVERY_ATTEMPTS}" \
    --quiet 2>/dev/null || \
  gcloud pubsub subscriptions update "${SUB}" \
    --project="${PROJECT}" \
    --dead-letter-topic="${DLQ_TOPIC}" \
    --max-delivery-attempts="${MAX_DELIVERY_ATTEMPTS}" \
    --quiet
  # Dead-letter forwarding requires the Pub/Sub service agent to hold
  # roles/pubsub.subscriber ON THE SOURCE SUBSCRIPTION (publisher on the DLQ
  # topic alone is not enough) — without it messages are never forwarded.
  gcloud pubsub subscriptions add-iam-policy-binding "${SUB}" \
    --project="${PROJECT}" \
    --member="serviceAccount:${PUBSUB_SA}" \
    --role="roles/pubsub.subscriber" \
    --quiet >/dev/null
  echo "    ✓ attached (max_delivery_attempts=${MAX_DELIVERY_ATTEMPTS}, subscriber IAM granted)"
}

# Pub/Sub service agent — needs publisher on the DLQ topic and subscriber on
# each source subscription (granted inside attach_dlq).
PUBSUB_SA="service-$(gcloud projects describe "${PROJECT}" --format='value(projectNumber)')@gcp-sa-pubsub.iam.gserviceaccount.com"

# Grant the Pub/Sub service account the required roles on the DLQ topic
# so it can actually forward messages there.
grant_dlq_iam() {
  echo "  · granting roles/pubsub.publisher to Pub/Sub SA on DLQ topic"
  gcloud pubsub topics add-iam-policy-binding fafa-dead-letter \
    --project="${PROJECT}" \
    --member="serviceAccount:${PUBSUB_SA}" \
    --role="roles/pubsub.publisher" \
    --quiet >/dev/null
  echo "    ✓ done"
}

failed=0

sync_cred_sub=$(get_eventarc_sub "sync-credential-requested")
attach_dlq "sync-credential" "${sync_cred_sub}" || failed=$((failed + 1))

fcm_send_sub=$(get_eventarc_sub "fcm-send-requested")
attach_dlq "send-fcm" "${fcm_send_sub}" || failed=$((failed + 1))

amazon_report_sub=$(get_eventarc_sub "amazon-report-requested")
attach_dlq "process-amazon-report" "${amazon_report_sub}" || failed=$((failed + 1))

report_sub=$(get_eventarc_sub "report-requested")
attach_dlq "process-report" "${report_sub}" || failed=$((failed + 1))

echo ""
echo "  · ensuring Pub/Sub SA can publish to DLQ"
grant_dlq_iam

echo ""
if [[ ${failed} -gt 0 ]]; then
  echo "✗ ${failed} subscription(s) failed — re-run after deploying all functions." >&2
  exit 1
fi
echo "✓ DLQ policy attached to all Eventarc subscriptions."
