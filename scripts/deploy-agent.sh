#!/usr/bin/env bash
# Create (or add a new version to) the Foundry hosted agent and wait until active.
# Requires: az CLI logged in with a Foundry data-plane role on the project.
# Env: PROJECT_ENDPOINT, IMAGE, AGENT_NAME (default gcubed-model)
set -euo pipefail

AGENT_NAME="${AGENT_NAME:-gcubed-model}"
API="api-version=v1"
RES="https://ai.azure.com"
: "${PROJECT_ENDPOINT:?}" "${IMAGE:?}"

DEF=$(cat <<JSON
{
  "kind": "hosted",
  "container_configuration": { "image": "${IMAGE}" },
  "cpu": "${AGENT_CPU:-1}",
  "memory": "${AGENT_MEMORY:-2Gi}",
  "protocol_versions": [ { "protocol": "invocations", "version": "${INVOCATIONS_PROTOCOL_VERSION:-2.0.0}" } ],
  "environment_variables": { "GCUBED_LOG_LEVEL": "WARNING" }
}
JSON
)

if az rest --method GET --resource "$RES" --url "${PROJECT_ENDPOINT}/agents/${AGENT_NAME}?${API}" >/dev/null 2>&1; then
  echo "Agent exists - creating a new version"
  OUT=$(az rest --method POST --resource "$RES" \
    --url "${PROJECT_ENDPOINT}/agents/${AGENT_NAME}/versions?${API}" \
    --headers "Content-Type=application/json" \
    --body "{\"definition\": ${DEF}, \"description\": \"G-Cubed model ${IMAGE##*:}\"}")
else
  echo "Creating agent ${AGENT_NAME}"
  OUT=$(az rest --method POST --resource "$RES" \
    --url "${PROJECT_ENDPOINT}/agents?${API}" \
    --headers "Content-Type=application/json" \
    --body "{\"name\": \"${AGENT_NAME}\", \"description\": \"G-Cubed macroeconomic model API\", \"definition\": ${DEF}}")
fi
echo "$OUT"
VERSION=$(echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("version") or d.get("versions",{}).get("latest",{}).get("version"))')
echo "Agent version: ${VERSION}"

for i in $(seq 1 60); do
  STATUS_JSON=$(az rest --method GET --resource "$RES" --url "${PROJECT_ENDPOINT}/agents/${AGENT_NAME}/versions/${VERSION}?${API}")
  STATUS=$(echo "$STATUS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')
  echo "[$i] status=${STATUS}"
  case "$STATUS" in
    active) break ;;
    failed) echo "$STATUS_JSON"; exit 1 ;;
  esac
  sleep 10
done
[ "$STATUS" = "active" ] || { echo "Timed out waiting for agent"; exit 1; }
echo "agent_version=${VERSION}" >> "${GITHUB_OUTPUT:-/dev/null}"
