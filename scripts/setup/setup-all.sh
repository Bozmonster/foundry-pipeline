#!/usr/bin/env bash
# Run every setup step in order. Each step asks before changing anything and remembers answers in setup.env.
#   git clone https://github.com/Bozmonster/foundry-pipeline && cd foundry-pipeline
#   bash scripts/setup/setup-all.sh
set -euo pipefail
DIR="$(dirname "$0")"
bash "$DIR/1-fork-model-repo.sh"
bash "$DIR/2-create-pipeline-repo.sh"
bash "$DIR/3-azure.sh"
bash "$DIR/4-run-pipeline.sh"
echo
echo "Done. Grant other people access with: bash $DIR/5-grant-api-access.sh"
