#!/usr/bin/env bash
# Send a G-Cubed payload to the Foundry-hosted API and save the HTML reports it returns.
#
#   PROJECT_ENDPOINT=https://<foundry>.services.ai.azure.com/api/projects/gcubed-project \
#     bash scripts/invoke-report.sh examples/inflation-target-shock.json out/
#
# Needs: az CLI logged in with the "Azure AI User" role on the Foundry project, python3.
set -euo pipefail
AGENT_NAME="${AGENT_NAME:-gcubed-model}"
: "${PROJECT_ENDPOINT:?Set PROJECT_ENDPOINT}"
PAYLOAD="${1:-examples/inflation-target-shock.json}"
OUT="${2:-gcubed-report}"
mkdir -p "$OUT"

# add "report": "html" to the payload
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["report"]="html"; json.dump(d,open(sys.argv[2],"w"))' \
  "$PAYLOAD" "$OUT/request.json"

echo "POST ${PROJECT_ENDPOINT}/agents/${AGENT_NAME}/endpoint/protocols/invocations"
start=$(date +%s.%N)
az rest --method POST --resource "https://ai.azure.com" \
  --url "${PROJECT_ENDPOINT}/agents/${AGENT_NAME}/endpoint/protocols/invocations?api-version=v1" \
  --headers "Content-Type=application/json" --body "@$OUT/request.json" > "$OUT/response.json"
end=$(date +%s.%N)

python3 - "$OUT" "$start" "$end" <<'PY'
import json, re, sys, pathlib
out = pathlib.Path(sys.argv[1]); r = json.loads((out / "response.json").read_text())
if "error" in r:
    sys.exit(f"API error: {r['error']}")
reports = r.pop("html_reports", {})
for name, html in reports.items():
    safe = re.sub(r"[^A-Za-z0-9._+-]+", "_", name)
    (out / safe).write_text(html, encoding="utf-8")
    print(f"saved {out / safe} ({len(html):,} bytes)")
(out / "response.json").write_text(json.dumps(r, indent=2))
print(f"model compute {r.get('elapsed_seconds')}s, round trip {float(sys.argv[3]) - float(sys.argv[2]):.1f}s")
for k, v in list(r.get("deviation_from_baseline", {}).items())[:3]:
    print(f"{k:>12} deviation: {[round(x, 3) for x in v[:6]]}")
PY
