# Recreating the G-Cubed → Microsoft Foundry pipeline

This guide rebuilds everything from scratch, in a new GitHub account and a new Azure subscription if you want.

Every component can be set up in one of two ways:

- **Scripted:** an interactive script asks for names and confirms before it changes anything.
- **Manual:** a step-by-step guide with annotated screenshots.

| # | Component | What it is | Script | Manual guide |
|---|---|---|---|---|
| 1 | **G-Cubed model repo** | Public fork of `McKibbin-Software-Group/gcubed.com-model-2R` | `scripts/setup/1-fork-model-repo.sh` | [01-model-repo.md](01-model-repo.md) |
| 2 | **Pipeline repo** | This repo: API, Dockerfile, Bicep, workflow | `scripts/setup/2-create-pipeline-repo.sh` | [02-pipeline-repo.md](02-pipeline-repo.md) |
| 3 | **Azure** | Resource group, OIDC identity, roles, ACR, Foundry resource and project | `scripts/setup/3-azure.sh` | [03-azure.md](03-azure.md) |
| 4 | **GitHub Actions** | Repo variables, run the pipeline, read the results | `scripts/setup/4-run-pipeline.sh` | [04-github-actions.md](04-github-actions.md) |
| 5 | **Using the API** | Send a payload, get JSON and HTML back, grant access, tear down | `scripts/invoke-report.sh`, `scripts/setup/5-grant-api-access.sh`, `scripts/setup/teardown.sh` | [05-use-the-api.md](05-use-the-api.md) |

## The quickest route (about 15 minutes)

1. Sign in to <https://shell.azure.com> and choose **Bash**. Cloud Shell already has `az`, `gh`, `git` and `python3`. It also works in tenants with MFA "security defaults", which block a local Azure CLI from creating identities.
2. Run:

   ```bash
   git clone https://github.com/Bozmonster/foundry-pipeline && cd foundry-pipeline
   bash scripts/setup/setup-all.sh
   ```

3. Answer the prompts. The defaults reproduce the current setup. Your answers are saved to `setup.env`, so you can re-run any single step later.

`gh auth login` (step 1) opens a device-code page in your browser. Approve it with the GitHub account that should own the repositories.

## What you need

| Need | Why |
|---|---|
| GitHub account | Owns the model fork and the pipeline repo; runs GitHub Actions |
| Azure subscription where you are **Owner** | Owner can create role assignments. The free trial is fine: the running cost is about US$5/month for the registry. |
| A region that supports Foundry hosted agents | The default is `australiaeast`; `3-azure.sh` lists the others |

## Order matters

```
1 model fork ──► 2 pipeline repo ──► 3 Azure ──► 4 run pipeline ──► 5 call API
                     │                  ▲
                     └── repo IDs ──────┘   (Azure trusts GitHub's OIDC token for this exact repo)
```

The Azure step needs the pipeline repo to exist first. GitHub now issues OIDC tokens with immutable IDs (`repo:Owner@ownerId/repo@repoId:…`), and Azure must trust that exact subject.
