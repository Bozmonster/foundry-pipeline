#!/usr/bin/env bash
# Populate model/ and vendor/ for the Docker build.
# Used by the GitHub Actions workflow and for local builds.
set -euo pipefail

MODEL_REPO="${MODEL_REPO:-https://github.com/Bozmonster/gcubed.com-model-2R.git}"
MODEL_REF="${MODEL_REF:-main}"
PREREQ_REPO="${PREREQ_REPO:-https://github.com/McKibbin-Software-Group/gcubed-public-prerequisites.git}"
GCUBED_TAG="${GCUBED_TAG:-gcubed-5-0-1-4}"

cd "$(dirname "$0")/.."
rm -rf model vendor .prereq
git clone --depth 1 --branch "$MODEL_REF" "$MODEL_REPO" model
rm -rf model/.git model/.devcontainer model/results

git clone --depth 1 --branch "$GCUBED_TAG" "$PREREQ_REPO" .prereq
mkdir -p vendor
cp .prereq/*.whl vendor/
rm -rf .prereq
ls vendor
