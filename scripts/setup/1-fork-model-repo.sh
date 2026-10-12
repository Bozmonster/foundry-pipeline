#!/usr/bin/env bash
# Step 1 - Fork the public G-Cubed model repository into your GitHub account (public).
# Run in Azure Cloud Shell or any shell with gh + git.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

bold "Step 1 of 5 - G-Cubed model repository (fork)"
need_gh_login

ask UPSTREAM_MODEL_REPO "Upstream G-Cubed model repo" "McKibbin-Software-Group/gcubed.com-model-2R"
ask GITHUB_OWNER "Your GitHub user or organisation" "$(gh api user --jq .login)"
MODEL_REPO_NAME="${UPSTREAM_MODEL_REPO#*/}"
MODEL_FORK="$GITHUB_OWNER/$MODEL_REPO_NAME"; save MODEL_FORK

if gh repo view "$MODEL_FORK" >/dev/null 2>&1; then
  ok "Fork already exists: https://github.com/$MODEL_FORK"
  if confirm "Sync it with the latest upstream changes now?"; then
    run gh repo sync "$MODEL_FORK" --source "$UPSTREAM_MODEL_REPO" --branch main
  fi
else
  info "Creating fork $MODEL_FORK"
  if [ "$GITHUB_OWNER" = "$(gh api user --jq .login)" ]; then
    run gh repo fork "$UPSTREAM_MODEL_REPO" --clone=false --default-branch-only
  else
    run gh repo fork "$UPSTREAM_MODEL_REPO" --clone=false --default-branch-only --org "$GITHUB_OWNER"
  fi
  for i in $(seq 1 12); do gh repo view "$MODEL_FORK" >/dev/null 2>&1 && break; sleep 5; done
fi

VIS=$(gh repo view "$MODEL_FORK" --json visibility --jq .visibility 2>/dev/null || echo PUBLIC)
[ "$VIS" = "PUBLIC" ] || warn "$MODEL_FORK is $VIS. The pipeline clones it without credentials, so it must be public."
MODEL_REPO_URL="https://github.com/$MODEL_FORK.git"; save MODEL_REPO_URL
ok "Model repo ready: https://github.com/$MODEL_FORK"
echo "Next: bash scripts/setup/2-create-pipeline-repo.sh"
