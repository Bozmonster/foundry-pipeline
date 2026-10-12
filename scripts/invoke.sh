#!/usr/bin/env bash
# Call the deployed G-Cubed API through Foundry.
# Usage: PROJECT_ENDPOINT=... ./scripts/invoke.sh '{"action":"describe"}'
#        PROJECT_ENDPOINT=... ./scripts/invoke.sh @examples/inflation-target-shock.json
set -euo pipefail
AGENT_NAME="${AGENT_NAME:-gcubed-model}"
: "${PROJECT_ENDPOINT:?Set PROJECT_ENDPOINT, e.g. https://<foundry>.services.ai.azure.com/api/projects/gcubed-project}"
DEFAULT_BODY='{"action":"health"}'
BODY="${1:-$DEFAULT_BODY}"
az rest --method POST --resource "https://ai.azure.com" \
  --url "${PROJECT_ENDPOINT}/agents/${AGENT_NAME}/endpoint/protocols/invocations?api-version=v1" \
  --headers "Content-Type=application/json" \
  --body "$BODY"
