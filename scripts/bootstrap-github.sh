#!/usr/bin/env bash
#
# STRW factory — one-time GitHub bootstrap
# -----------------------------------------------------------------------------
# Wires the strw-factory plugin folder to its OWN GitHub repo and pushes.
# Safe to re-run. It will:
#   1. Ensure this folder is a git repo with at least one commit.
#   2. Remove any wrong 'origin' (e.g. one pointing at strw-state).
#   3. Create the strw-factory repo on GitHub if it doesn't exist, else connect it.
#   4. Push 'main', handling the "remote already has a README" case.
#
# Run it once:  ./scripts/bootstrap-github.sh
# -----------------------------------------------------------------------------

set -euo pipefail

REPO_NAME="strw-factory"     # target repo name on GitHub (must NOT be strw-state)
VISIBILITY="private"          # private | public
BRANCH="main"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -t 1 ]; then
  B=$(printf '\033[1m'); R=$(printf '\033[31m'); G=$(printf '\033[32m'); Y=$(printf '\033[33m'); Z=$(printf '\033[0m')
else B=""; R=""; G=""; Y=""; Z=""; fi
info(){ printf '%s\n' "• $*"; }
ok(){   printf '%s\n' "${G}✓${Z} $*"; }
warn(){ printf '%s\n' "${Y}!${Z} $*" >&2; }
die(){  printf '%s\n' "${R}✗ $*${Z}" >&2; exit 1; }

cd "$PLUGIN_DIR"
info "Plugin folder: ${B}$PLUGIN_DIR${Z}"

# --- prerequisites -----------------------------------------------------------
command -v git >/dev/null 2>&1 || die "git not found"
command -v gh  >/dev/null 2>&1 || die "gh (GitHub CLI) not found"
gh auth status >/dev/null 2>&1 || die "gh not authenticated. Run: gh auth login"

OWNER="$(gh api user --jq .login)"
[ -n "$OWNER" ] || die "Could not read your GitHub username via gh."
FULL="$OWNER/$REPO_NAME"
info "GitHub account: ${B}$OWNER${Z}  →  target repo: ${B}$FULL${Z}"

[ "$REPO_NAME" = "strw-state" ] && die "Refusing to use strw-state as the plugin repo."

# --- 1) ensure git repo + a commit ------------------------------------------
if [ ! -d .git ]; then
  info "Initializing git repository"
  git init -b "$BRANCH" >/dev/null
else
  ok "git repository present"
fi
# make sure we're on the target branch
git rev-parse --verify "$BRANCH" >/dev/null 2>&1 || git checkout -b "$BRANCH" >/dev/null 2>&1 || true
git symbolic-ref -q HEAD >/dev/null || true

if ! git rev-parse HEAD >/dev/null 2>&1; then
  info "Creating initial commit"
  git add -A
  git commit -m "chore: import $REPO_NAME v0.1.0" >/dev/null
  ok "initial commit created"
elif [ -n "$(git status --porcelain)" ]; then
  info "Committing pending changes"
  git add -A
  git commit -m "chore: bootstrap $REPO_NAME" >/dev/null
  ok "changes committed"
else
  ok "working tree clean, commit already present"
fi

# --- 2) fix the origin remote -----------------------------------------------
if git remote get-url origin >/dev/null 2>&1; then
  CUR="$(git remote get-url origin)"
  case "$CUR" in
    *"/$REPO_NAME".git|*"/$REPO_NAME")
      ok "origin already points at $REPO_NAME ($CUR)" ;;
    *)
      warn "origin points at the wrong repo: $CUR"
      git remote remove origin
      ok "removed wrong origin" ;;
  esac
fi

# --- 3) create or connect the repo ------------------------------------------
if gh repo view "$FULL" >/dev/null 2>&1; then
  ok "repo $FULL already exists on GitHub"
  if ! git remote get-url origin >/dev/null 2>&1; then
    git remote add origin "https://github.com/$FULL.git"
    ok "connected origin → https://github.com/$FULL.git"
  fi
else
  info "Creating repo $FULL on GitHub ($VISIBILITY) and pushing"
  gh repo create "$FULL" --"$VISIBILITY" --source=. --remote=origin --push
  ok "repo created and pushed"
  git branch --set-upstream-to="origin/$BRANCH" "$BRANCH" >/dev/null 2>&1 || true
  echo; ok "${B}Done.${Z} Plugin is live at https://github.com/$FULL"
  exit 0
fi

# --- 4) push (repo already existed) -----------------------------------------
info "Pushing $BRANCH to origin"
if git push -u origin "$BRANCH"; then
  ok "pushed"
else
  warn "push rejected — remote likely has a README/license. Merging then retrying."
  git pull origin "$BRANCH" --allow-unrelated-histories --no-edit
  git push -u origin "$BRANCH"
  ok "pushed after merge"
fi

echo; ok "${B}Done.${Z} Plugin is live at https://github.com/$FULL"
