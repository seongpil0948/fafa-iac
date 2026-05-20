#!/usr/bin/env bash
# Post-chat validation for fafa-iac (Terraform-only repo).
# Runs: fmt check, validate.
# Triggered by the Stop hook in .github/hooks/post-chat-validate.json.
# Exit 0 = all clear; exit 2 = blocking failure (agent will surface the error).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

FAIL=0

run() {
  local label="$1"; shift
  echo "▶ $label"
  if "$@"; then
    echo "✓ $label passed"
  else
    echo "✗ $label FAILED" >&2
    FAIL=1
  fi
}

# --- Terraform ---
run "fmt check"  terraform fmt -recursive -check
run "validate"   terraform validate

if [[ $FAIL -ne 0 ]]; then
  echo ""
  echo "One or more post-chat validation steps failed. Fix the issues before committing." >&2
  exit 2
fi

echo ""
echo "All post-chat checks passed."
