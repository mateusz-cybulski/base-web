#!/usr/bin/env bash
#
# Prepare a new project created from base-web: its GitHub variables, found in the platform's
# Google Cloud (organization, billing account, DNS zone, Terraform state bucket, the deploy's
# service account and Workload Identity provider), the platform module's release, and, with
# --deploy, the first deploy and the local .env files.
#
# Usage (through mise), in the new repository after choosing its components (mise run add-setup):
#   mise run setup            set the repository's secrets and the platform release
#   mise run setup --deploy   also commit, push to main, wait for the deploy, then mise run env
#
# The repository may be private: its variables are its own, not the organization's.
#
# Environment (set in mise.toml):
#   PLATFORM_PROJECT   GCP project with the DNS zone, the state bucket and the deploy's identity.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

deploy=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deploy) deploy=true ;;
    *) echo "Usage: mise run setup [--deploy]" >&2; exit 1 ;;
  esac
  shift
done

project="${PLATFORM_PROJECT:?PLATFORM_PROJECT is not set (see [env] in mise.toml)}"
repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || {
  echo "This folder is not a GitHub repository yet: create it (gh repo create) and set origin." >&2
  exit 1
}
echo "Repository: $repo"
# base-web itself is the template, not a project: setting it up would give it a project's
# settings and replace its newer scripts with a release.
if [[ "$repo" == "$(basename "$(dirname "${TEMPLATE_REPO%.git}")")/$(basename "${TEMPLATE_REPO%.git}")" ]]; then
  echo "This is the template ($repo) itself; run setup in a repository created from it." >&2
  exit 1
fi

# 1. Shared settings, found in Google Cloud: they are identifiers, not passwords, so nothing is
# typed or stored. A variable already set (e.g. in mise.local.toml) wins over what is found.
# pick <NAME> <command...>: the variable NAME if already set, else the one line the command prints;
# anything else stops setup and says what to set.
pick() {
  local name="$1"; shift
  if [[ -n "${!name:-}" ]]; then echo "${!name}"; return; fi
  local found
  found="$("$@" 2>/dev/null | sed '/^$/d')" || true
  if [[ -z "$found" || "$(wc -l <<<"$found" | tr -d ' ')" != 1 ]]; then
    echo "Cannot tell $name (found: ${found:-nothing}). Set $name in mise.local.toml." >&2
    return 1
  fi
  echo "$found"
}

# macOS ships bash 3.2: no associative arrays, so one function names each value.
value_of() {
  case "$1" in
    GCP_DNS_PROJECT_ID) echo "$project" ;;
    GCP_ORG_ID) pick GCP_ORG_ID gcloud organizations list --format='value(name)' ;;
    GCP_BILLING_ACCOUNT_ID) pick GCP_BILLING_ACCOUNT_ID \
      gcloud billing accounts list --filter=open=true --format='value(name)' ;;
    GCP_FOLDER_ID) echo "${GCP_FOLDER_ID:-}" ;;  # empty: projects go straight under the organization
    GCP_DNS_MANAGED_ZONE_NAME) pick GCP_DNS_MANAGED_ZONE_NAME \
      gcloud dns managed-zones list --project="$project" --format='value(name)' ;;
    GCP_TF_STATE_BUCKET) pick GCP_TF_STATE_BUCKET \
      gcloud storage buckets list --project="$project" --filter='name~-tfstate$' --format='value(name)' ;;
    GCP_SERVICE_ACCOUNT) pick GCP_SERVICE_ACCOUNT \
      gcloud iam service-accounts list --project="$project" --filter='email~^gh-actions-ci@' --format='value(email)' ;;
    GCP_WORKLOAD_IDENTITY_PROVIDER) pick GCP_WORKLOAD_IDENTITY_PROVIDER \
      gcloud iam workload-identity-pools providers list --workload-identity-pool=github-actions \
      --location=global --project="$project" --format='value(name)' ;;
    # Who may pull local secrets: you, unless a group is set.
    DEVELOPERS) echo "${DEVELOPERS:-user:$(gcloud config get-value account 2>/dev/null)}" ;;
  esac
}

names="GCP_DNS_PROJECT_ID GCP_ORG_ID GCP_BILLING_ACCOUNT_ID GCP_FOLDER_ID GCP_DNS_MANAGED_ZONE_NAME
  GCP_TF_STATE_BUCKET GCP_SERVICE_ACCOUNT GCP_WORKLOAD_IDENTITY_PROVIDER DEVELOPERS"
# Everything is found before anything is set: an unclear value stops setup with no half-done repo.
for name in $names; do
  value_of "$name" >/dev/null || exit 1
done
# Repository variables: visible and editable in the repository settings. A variable is printed in
# the Actions logs, so in a public repository DEVELOPERS (people's addresses) is a secret instead.
visibility="$(gh repo view "$repo" --json visibility -q .visibility)"
for name in $names; do
  value="$(value_of "$name")"
  if [[ -z "$value" ]]; then
    echo "  $name: empty, not set"
    continue
  fi
  kind=variable
  if [[ "$name" == DEVELOPERS && "$visibility" == PUBLIC ]]; then
    kind=secret
  fi
  # Through stdin, not arguments: a process list shows arguments.
  printf '%s' "$value" | gh "$kind" set "$name" --repo "$repo"
  echo "  $kind $name"
done
if [[ "$visibility" == PUBLIC ]]; then
  echo "  (public repository: DEVELOPERS is a secret, so the Actions logs do not show addresses)"
fi

# 2. The platform module at the latest release (replaces the template's PLATFORM_REF). The copy of
# the module the template brought along is not used: the project takes it by version.
.config/scripts/platform-update.sh
rm -rf terraform/app
rmdir terraform 2>/dev/null || true

if ! $deploy; then
  echo "Done. Commit and push to main to deploy, then run: mise run env"
  exit 0
fi

# 3. First deploy, then the local secrets.
git add -A
git commit -q -m "Set up the project on platform $(cat .config/platform-ref)" || true
git push -q origin HEAD:main
sleep 10
run="$(gh run list --repo "$repo" --workflow Infrastructure --branch main --limit 1 --json databaseId -q '.[0].databaseId')"
echo "Deploying (run $run)..."
gh run watch "$run" --repo "$repo" --exit-status >/dev/null
.config/scripts/env-pull.sh
echo "Done: deployed, and the local .env files are written."
