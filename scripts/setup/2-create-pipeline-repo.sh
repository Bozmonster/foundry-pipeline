#!/usr/bin/env bash
# Step 2 - Create the pipeline repository (API, Dockerfile, Bicep, workflow) in your GitHub account
# and push this code to it. Run from a clone of foundry-pipeline.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

bold "Step 2 of 5 - Pipeline repository"
need_gh_login; need git

ask GITHUB_OWNER "GitHub user or organisation for the pipeline repo" "$(gh api user --jq .login)"
ask PIPELINE_REPO_NAME "Pipeline repository name" "foundry-pipeline"
ask PIPELINE_VISIBILITY "Visibility (public/private)" "public"
PIPELINE_REPO="$GITHUB_OWNER/$PIPELINE_REPO_NAME"; save PIPELINE_REPO

cd "$SETUP_ROOT"
if gh repo view "$PIPELINE_REPO" >/dev/null 2>&1; then
  ok "Repository exists: https://github.com/$PIPELINE_REPO"
else
  run gh repo create "$PIPELINE_REPO" "--$PIPELINE_VISIBILITY" \
    --description "Deploys the G-Cubed model to Microsoft Foundry as a containerised API"
fi

[ -d .git ] || run git init -b main
if git remote get-url origin >/dev/null 2>&1; then
  CURRENT=$(git remote get-url origin)
  if [[ "$CURRENT" != *"$PIPELINE_REPO"* ]] && confirm "origin is $CURRENT. Point it at $PIPELINE_REPO?"; then
    run git remote set-url origin "https://github.com/$PIPELINE_REPO.git"
  fi
else
  run git remote add origin "https://github.com/$PIPELINE_REPO.git"
fi
git config user.name >/dev/null || run git config user.name "$GITHUB_OWNER"
git config user.email >/dev/null || run git config user.email "$GITHUB_OWNER@users.noreply.github.com"

run git add -A
git diff --cached --quiet || run git commit -m "G-Cubed Foundry pipeline"
info "Pushing. The first workflow run builds and tests only; it deploys once step 3 has set the Azure variables."
run git push -u origin HEAD:main

# GitHub environment used by the workflow (and by the OIDC subject)
run gh api -X PUT "repos/$PIPELINE_REPO/environments/azure" --silent
ok "Environment 'azure' ready"

if [ -n "${MODEL_REPO_URL:-}" ]; then
  run gh variable set MODEL_REPO --repo "$PIPELINE_REPO" --body "$MODEL_REPO_URL"
  ok "MODEL_REPO variable -> $MODEL_REPO_URL"
fi
ok "Pipeline repo ready: https://github.com/$PIPELINE_REPO"
echo "Next: bash scripts/setup/3-azure.sh"
