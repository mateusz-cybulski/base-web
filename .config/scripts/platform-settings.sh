#!/usr/bin/env bash
#
# Store the settings every project of the platform shares (GCP billing account, organization,
# folder, DNS, Terraform state bucket, Workload Identity, developers) as one secret in the
# platform project's Secret Manager. `mise run setup` reads it and sets these as the new
# repository's GitHub secrets. Run it once, and again when a setting changes.
#
# Usage (through mise):
#   mise run platform-settings            open a file to fill in, store it, delete the file
#   mise run platform-settings --names    list the settings stored (names only, never values)
#
# Environment (set in mise.toml):
#   PLATFORM_PROJECT   GCP project holding the settings (the one with the DNS zone).

set -euo pipefail

project="${PLATFORM_PROJECT:?PLATFORM_PROJECT is not set (see [env] in mise.toml)}"
SECRET_ID=platform-settings

# Every GitHub secret the Terraform workflow reads that is the same for all projects.
SETTINGS=(
  GCP_WORKLOAD_IDENTITY_PROVIDER
  GCP_SERVICE_ACCOUNT
  GCP_TF_STATE_BUCKET
  GCP_BILLING_ACCOUNT_ID
  GCP_ORG_ID
  GCP_FOLDER_ID
  GCP_DNS_PROJECT_ID
  GCP_DNS_MANAGED_ZONE_NAME
  DEVELOPERS
)

if ! gcloud services list --enabled --project="$project" --filter="config.name=secretmanager.googleapis.com" \
  --format="value(config.name)" 2>/dev/null | grep -q .; then
  echo "Secret Manager is not enabled in $project. Enable it once:" >&2
  echo "  gcloud services enable secretmanager.googleapis.com --project=$project" >&2
  exit 1
fi

if [[ "${1:-}" == "--names" ]]; then
  if ! stored="$(gcloud secrets versions access latest --secret="$SECRET_ID" --project="$project" 2>/dev/null)"; then
    echo "No platform settings stored in $project yet: run mise run platform-settings." >&2
    exit 1
  fi
  STORED="$stored" python3 -c 'import json, os; print("\n".join(sorted(json.loads(os.environ["STORED"]))))'
  exit 0
fi

# Outside the repository, readable only by you, removed however the script ends.
draft="$(mktemp "${TMPDIR:-/tmp}/platform-settings.XXXXXX")"
chmod 600 "$draft"
trap 'rm -f "$draft"' EXIT
{
  echo "# One NAME=value per line; a line left empty is not stored."
  echo "# DEVELOPERS: IAM members allowed to pull local secrets, e.g. group:developers@example.com"
  for name in "${SETTINGS[@]}"; do echo "$name="; done
} >"$draft"

"${EDITOR:-vi}" "$draft"

DRAFT="$draft" python3 - >"$draft.json" <<'PYTHON'
import json
import os

values = {}
for line in open(os.environ["DRAFT"]):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        name, value = line.split("=", 1)
        if value.strip():
            values[name.strip()] = value.strip()
print(json.dumps(values))
PYTHON
chmod 600 "$draft.json"
trap 'rm -f "$draft" "$draft.json"' EXIT

if ! gcloud secrets describe "$SECRET_ID" --project="$project" >/dev/null 2>&1; then
  gcloud secrets create "$SECRET_ID" --project="$project" --replication-policy=automatic >/dev/null
fi
gcloud secrets versions add "$SECRET_ID" --project="$project" --data-file="$draft.json" >/dev/null
echo "Stored in $project/$SECRET_ID:"
python3 -c 'import json, sys; print("\n".join("  " + name for name in sorted(json.load(open(sys.argv[1])))))' "$draft.json"
