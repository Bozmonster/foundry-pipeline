# foundry-pipeline

CI/CD pipeline that deploys the **G-Cubed** macroeconomic model (model 2R, build 199) to **Microsoft Foundry** as a containerised **hosted agent**, and exposes it through an **HTTP JSON API** (Foundry Invocations protocol).

```
Bozmonster/gcubed.com-model-2R ─┐
gcubed wheel (5.0.1.4) ─────────┼─► GitHub Actions ─► Docker image ─► Azure Container Registry
this repo (API + infra) ────────┘        │                                     │
                                         └─ Bicep ─► Foundry resource/project ◄┘ pulls image
                                                          │
                       client ── POST .../agents/gcubed-model/endpoint/protocols/invocations
```

## Repository layout

| Path | Purpose |
|---|---|
| `app/gcubed_service.py` | Loads the solved model, runs the baseline and custom shock experiments, and returns JSON |
| `app/main.py` | Invocations-protocol server (`POST /invocations`, port 8088) |
| `app/prepare.py` | Solves the model during `docker build` (this also acts as a build-time test) |
| `Dockerfile` | Python 3.14.5 + gcubed wheel + model files + API |
| `infra/main.bicep` | ACR (Basic), Foundry resource and project, and the AcrPull role assignments |
| `.github/workflows/deploy-gcubed.yml` | Build → local container test → Bicep → push → deploy agent → smoke test |
| `scripts/bootstrap-azure.ps1` | One-time Azure setup: resource group, OIDC app registration, roles, and GitHub variables |
| `scripts/fetch-sources.sh` | Clones the model fork and the gcubed wheel into `model/` and `vendor/` |
| `scripts/deploy-agent.sh` | Creates or versions the Foundry hosted agent and waits for `active` |
| `scripts/invoke.sh` | Calls the deployed API |

## One-time setup

1. `az login`, then run `./scripts/bootstrap-azure.ps1` from PowerShell.
2. If the GitHub CLI isn't installed, copy the printed values into the repo's **Actions variables**.
3. Push to `main` or run the workflow manually. It uses OIDC, so it needs no Azure secrets.

## API

`POST {projectEndpoint}/agents/gcubed-model/endpoint/protocols/invocations?api-version=v1`. Authenticate with an Entra token for `https://ai.azure.com`; the caller needs the **Azure AI User** role.

| Body | Result |
|---|---|
| `{"action":"health"}` | Status and model load time |
| `{"action":"describe"}` | Years, regions, and variable prefixes with descriptions and units |
| `{"action":"run","variables":["GDPR","INFL"],"first_year":2023,"last_year":2035}` | Baseline projections |
| …plus `"shocks":[{"variable":"INFX(USA)","value":1,"start_year":2024,"end_year":2030}]` | Baseline, experiment, and deviation from baseline |

Variables can be full names (`GDPR(USA)`) or prefixes (`GDPR`, which expands to every region). G-Cubed itself validates the shock variables. The OpenAPI spec is served at `GET /invocations/docs/openapi.json` inside the container.

```bash
PROJECT_ENDPOINT=https://<foundry>.services.ai.azure.com/api/projects/gcubed-project \
  ./scripts/invoke.sh @examples/inflation-target-shock.json
```

## Run locally

```bash
./scripts/fetch-sources.sh
docker build -t gcubed-api .
docker run -p 8088:8088 gcubed-api
curl -X POST localhost:8088/invocations -d @examples/inflation-target-shock.json
```

## Cost

- ACR Basic is about US$5/month.
- The Foundry resource has no model deployments, so it costs nothing at rest.
- The hosted agent bills CPU and memory only while a session is active. Compute is released after 15 minutes idle.
- To remove everything, delete the `rg-gcubed-foundry` resource group.

## Licensing note

The `gcubed` package is published by McKibbin Software Group under "All rights reserved". This pipeline downloads it at build time from their public prerequisites repo and doesn't redistribute it in this repository. The container image stays in your private ACR.
