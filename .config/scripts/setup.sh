#!/usr/bin/env bash
#
# Prepare a new project created from base-web: its GitHub secrets from the platform settings
# (mise run platform-settings), the platform module's release, and, with --deploy, the first
# deploy and the local .env files.
#
# Usage (through mise), in the new repository after choosing its components (mise run add-setup):
#   mise run setup            set the repository's secrets and the platform release
#   mise run setup --deploy   also commit, push to main, wait for the deploy, then mise run env
#
# The repository may be private: its secrets are its own, not the organization's.
#
# Environment (set in mise.toml):
#   PLATFORM_PROJECT   GCP project holding the platform settings.

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

# 1. GitHub secrets from the platform settings; values go through stdin, never printed.
settings="$(gcloud secrets versions access latest --secret=platform-settings --project="$project")" || {
  echo "Cannot read the platform settings: run mise run platform-settings first." >&2
  exit 1
}
# Through the environment, not arguments: a process list shows arguments.
export PLATFORM_SETTINGS="$settings"
names="$(python3 -c 'import json, os; print("\n".join(json.loads(os.environ["PLATFORM_SETTINGS"])))')"
while read -r name; do
  python3 -c 'import json, os, sys; sys.stdout.write(json.loads(os.environ["PLATFORM_SETTINGS"])[sys.argv[1]])' "$name" |
    gh secret set "$name" --repo "$repo"
  echo "  secret $name"
done <<<"$names"
unset PLATFORM_SETTINGS

# 2. The platform module at the latest release (replaces the template's PLATFORM_REF).
.config/scripts/platform-update.sh

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
