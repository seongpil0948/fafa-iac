#!/usr/bin/env bash
# setup-dlq.sh — Attach the dead-letter policy to the Eventarc-managed
# subscriptions for sync-credential and fcm-send.
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
  gcloud pubsub subscriptions list \
    --project="${PROJECT}" \
    --filter="topic:${TOPIC_FILTER} AND labels.goog-managed-by=eventarc" \
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
  echo "    ✓ attached (max_delivery_attempts=${MAX_DELIVERY_ATTEMPTS})"
}

# Grant the Pub/Sub service account the required roles on the DLQ topic
# so it can actually forward messages there.
grant_dlq_iam() {
  local PUBSUB_SA
  PUBSUB_SA="service-$(gcloud projects describe "${PROJECT}" --format='value(projectNumber)')@gcp-sa-pubsub.iam.gserviceaccount.com"
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

echo ""
echo "  · ensuring Pub/Sub SA can publish to DLQ"
grant_dlq_iam

echo ""
if [[ ${failed} -gt 0 ]]; then
  echo "✗ ${failed} subscription(s) failed — re-run after deploying all functions." >&2
  exit 1
fi
echo "✓ DLQ policy attached to all Eventarc subscriptions."
