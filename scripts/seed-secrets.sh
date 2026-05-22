#!/usr/bin/env bash
#
# Idempotently push the platform OAuth/API secrets from the SiveraV2 web
# app's .env.local into GCP Secret Manager. Designed to be re-run safely:
#
#   - If the secret resource is missing, abort with a hint to run
#     `terraform apply` (the resource is owned by modules/secrets/).
#   - If no existing version matches the .env.local value, add a new
#     version. Otherwise, skip — saves on Secret Manager versions quota
#     and avoids unnecessary "latest" pointer churn.
#
# Source of truth: SiveraV2/apps/web/.env.local. The secret KEY names match
# the env-var names referenced inside @app/platforms (process.env.X).
#
# Usage:
#   bash scripts/seed-secrets.sh                          # uses default path
#   ENV_FILE=/path/to/.env.local bash scripts/seed-secrets.sh
#
set -euo pipefail

PROJECT="${PROJECT:-fafa-255a2}"
ENV_FILE="${ENV_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../SiveraV2/apps/web" && pwd)/.env.local}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "✗ Env file not found at ${ENV_FILE}" >&2
  echo "  Pass ENV_FILE=/path/to/.env.local explicitly." >&2
  exit 1
fi

# Names mirror modules/secrets/main.tf -> local.platform_secret_names.
SECRETS=(
  AMAZON_CLIENT_ID
  AMAZON_CLIENT_SECRET
  GOOGLE_CLIENT_ID
  GOOGLE_CLIENT_SECRET
  GOOGLE_DEVELOPER_TOKEN
  META_APP_ID
  META_APP_SECRET
  META_LOGIN_CONFIG_ID
  TIKTOK_APP_ID
  TIKTOK_APP_SECRET
)

echo "▸ Project:  ${PROJECT}"
echo "▸ Env file: ${ENV_FILE}"

# Strip optional surrounding quotes and trailing CR.
read_env_value() {
  local key="$1"
  awk -F= -v k="$key" '
    $1 == k {
      sub(/^[^=]+=/, "")
      gsub(/\r$/, "")
      gsub(/^"|"$/, "")
      gsub(/^'\''|'\''$/, "")
      print
      exit
    }' "${ENV_FILE}"
}

added=0
skipped=0
missing=0

for name in "${SECRETS[@]}"; do
  value="$(read_env_value "${name}")"
  if [[ -z "${value}" ]]; then
    echo "  ⚠ ${name}: not set in .env.local — skipping"
    missing=$((missing + 1))
    continue
  fi

  # Confirm the secret resource exists (created by Terraform).
  if ! gcloud secrets describe "${name}" --project="${PROJECT}" >/dev/null 2>&1; then
    echo "  ✗ ${name}: secret resource missing — run 'terraform apply' first" >&2
    exit 1
  fi

  current="$(gcloud secrets versions access latest --secret="${name}" --project="${PROJECT}" 2>/dev/null || echo "")"
  if [[ "${current}" == "${value}" ]]; then
    echo "  = ${name}: up-to-date"
    skipped=$((skipped + 1))
    continue
  fi

  # `gcloud secrets versions add` reads the value from --data-file; using
  # /dev/stdin avoids writing the secret to a temp file on disk.
  printf '%s' "${value}" | gcloud secrets versions add "${name}" \
    --project="${PROJECT}" \
    --data-file=- >/dev/null
  echo "  + ${name}: new version added"
  added=$((added + 1))
done

echo ""
echo "✓ Done. added=${added} skipped=${skipped} missing=${missing}"

# In CI mode, fail hard when secrets are absent so rotations are never silently skipped.
if [[ -n "${CI:-}" ]] && [[ "${missing}" -gt 0 ]]; then
  echo "✗ CI mode: ${missing} secret(s) missing from .env.local — aborting." >&2
  exit 1
fi
