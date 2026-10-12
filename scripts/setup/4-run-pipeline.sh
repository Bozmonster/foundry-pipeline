#!/usr/bin/env bash
# Step 4 - Run the GitHub Actions pipeline, watch it, then call the deployed API and save the HTML report.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

bold "Step 4 of 5 - Run the deployment pipeline"
need_gh_login
ask PIPELINE_REPO "GitHub pipeline repository (owner/name)" "Bozmonster/foundry-pipeline"
ask MODEL_REF "Model branch or tag to deploy" "main"
ask GCUBED_TAG "gcubed package tag" "gcubed-5-0-1-4"

for v in AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_RESOURCE_GROUP; do
  gh variable list --repo "$PIPELINE_REPO" --json name --jq '.[].name' | grep -qx "$v" \
    || die "Repository variable $v is missing - run step 3 first"
done

run gh workflow run deploy-gcubed.yml --repo "$PIPELINE_REPO" \
  -f model_ref="$MODEL_REF" -f gcubed_tag="$GCUBED_TAG" -f deploy=true
sleep 8
RUN_ID=$(gh run list --repo "$PIPELINE_REPO" --workflow deploy-gcubed.yml --limit 1 --json databaseId --jq '.[0].databaseId')
info "Watching run $RUN_ID (about 4 minutes)"
gh run watch "$RUN_ID" --repo "$PIPELINE_REPO" --exit-status || die "Pipeline failed: gh run view $RUN_ID --repo $PIPELINE_REPO --log-failed"
ok "Pipeline succeeded"

if [ -n "${PROJECT_ENDPOINT:-}" ] && command -v az >/dev/null; then
  info "Calling the deployed API and saving the HTML report to ./gcubed-report"
  PROJECT_ENDPOINT="$PROJECT_ENDPOINT" bash "$SETUP_ROOT/scripts/invoke-report.sh" \
    "$SETUP_ROOT/examples/inflation-target-shock.json" gcubed-report
else
  info "Download the 'gcubed-sample-result' artifact from the run to see the HTML report:"
  echo "  gh run download $RUN_ID --repo $PIPELINE_REPO -n gcubed-sample-result"
fi
