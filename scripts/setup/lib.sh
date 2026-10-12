#!/usr/bin/env bash
# Shared helpers for the interactive setup scripts.
# Settings are remembered in setup.env (repo root) so later steps can reuse them.

SETUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP_ENV="${SETUP_ENV:-$SETUP_ROOT/setup.env}"
[ -f "$SETUP_ENV" ] && . "$SETUP_ENV"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m ✔\033[0m %s\n' "$*"; }
warn() { printf '\033[33m !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m ✘ %s\033[0m\n' "$*" >&2; exit 1; }

# ask VAR "Question" "default"  -> prompts (unless NONINTERACTIVE=1), stores in setup.env
ask() {
  local var="$1" question="$2" default="${!1:-$3}" answer
  if [ "${NONINTERACTIVE:-0}" = "1" ]; then
    answer="$default"
  else
    read -r -p "$question [${default}]: " answer
    answer="${answer:-$default}"
  fi
  [ -n "$answer" ] || die "$var is required"
  printf -v "$var" '%s' "$answer"
  save "$var"
}

# confirm "Question" -> returns 0 for yes (default yes)
confirm() {
  [ "${NONINTERACTIVE:-0}" = "1" ] && return 0
  local a; read -r -p "$1 [Y/n]: " a
  [[ -z "$a" || "$a" =~ ^[Yy] ]]
}

save() {
  local var="$1"
  touch "$SETUP_ENV"
  sed -i "/^${var}=/d" "$SETUP_ENV"
  printf '%s=%q\n' "$var" "${!var}" >> "$SETUP_ENV"
}

# run: prints the command, executes it unless DRY_RUN=1
run() {
  printf '\033[2m$ %s\033[0m\n' "$*"
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  "$@"
}

need() { for t in "$@"; do command -v "$t" >/dev/null || die "Missing tool: $t (run this in Azure Cloud Shell, or install it)"; done; }

need_gh_login() {
  need gh
  if ! gh auth status >/dev/null 2>&1; then
    warn "GitHub CLI is not logged in. Starting 'gh auth login' (choose GitHub.com, HTTPS, login with a web browser)."
    gh auth login -h github.com -p https -w || die "GitHub login failed"
  fi
  gh auth setup-git >/dev/null 2>&1 || true
  ok "GitHub CLI logged in as $(gh api user --jq .login)"
}

need_az_login() {
  need az
  az account show >/dev/null 2>&1 || az login --use-device-code >/dev/null || die "Azure login failed"
}
