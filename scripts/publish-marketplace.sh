#!/usr/bin/env bash
#
# STRW factory — publish / update the plugin marketplace
# -----------------------------------------------------------------------------
# Makes the strw-factory plugin installable via a Claude plugin marketplace:
#   1. Commits any pending changes (incl. .claude-plugin/marketplace.json) and pushes.
#   2. Ensures the GitHub repo is public (so the marketplace can be cloned without auth).
#   3. Prints the /plugin commands to add the marketplace and install the plugin.
#
# Safe to re-run — use it any time you update the marketplace manifest.
#
#   ./scripts/publish-marketplace.sh            # commit, push, make public, show commands
#   ./scripts/publish-marketplace.sh --no-public  # commit + push only, keep repo private
# -----------------------------------------------------------------------------

set -euo pipefail

MAKE_PUBLIC="true"
[ "${1:-}" = "--no-public" ] && MAKE_PUBLIC="false"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$PLUGIN_DIR/.claude-plugin/marketplace.json"

if [ -t 1 ]; then
  B=$(printf '\033[1m'); R=$(printf '\033[31m'); G=$(printf '\033[32m'); Y=$(printf '\033[33m'); Z=$(printf '\033[0m')
else B=""; R=""; G=""; Y=""; Z=""; fi
info(){ printf '%s\n' "• $*"; }
ok(){   printf '%s\n' "${G}✓${Z} $*"; }
warn(){ printf '%s\n' "${Y}!${Z} $*" >&2; }
die(){  printf '%s\n' "${R}✗ $*${Z}" >&2; exit 1; }

cd "$PLUGIN_DIR"
command -v git >/dev/null 2>&1 || die "git not found"
command -v gh  >/dev/null 2>&1 || die "gh (GitHub CLI) not found"
gh auth status >/dev/null 2>&1 || die "gh not authenticated. Run: gh auth login"
[ -f "$MANIFEST" ] || die "marketplace manifest missing: $MANIFEST"
git remote get-url origin >/dev/null 2>&1 || die "no 'origin' remote. Run scripts/bootstrap-github.sh first."

# repo slug (owner/name) from origin
ORIGIN="$(git remote get-url origin)"
SLUG="$(printf '%s' "$ORIGIN" | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##')"
PLUGIN_NAME="$(grep -Eo '"name"[[:space:]]*:[[:space:]]*"[^"]+"' "$MANIFEST" | head -1 | sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
info "Repo: ${B}$SLUG${Z}  ·  marketplace: ${B}$PLUGIN_NAME${Z}"

# 1) commit + push
if [ -n "$(git status --porcelain)" ]; then
  info "Committing pending changes"
  git add -A
  git commit -m "chore: update marketplace manifest" >/dev/null
  ok "changes committed"
else
  ok "working tree clean"
fi
info "Pushing to origin"
git push >/dev/null 2>&1 && ok "pushed" || { git push; }

# 2) visibility
if [ "$MAKE_PUBLIC" = "true" ]; then
  VIS="$(gh repo view "$SLUG" --json visibility --jq .visibility 2>/dev/null || echo UNKNOWN)"
  if [ "$VIS" = "PUBLIC" ]; then
    ok "repo already public"
  else
    info "Making repo public"
    gh repo edit "$SLUG" --visibility public --accept-visibility-change-consequences
    ok "repo is now public"
  fi
else
  warn "--no-public: leaving repo visibility unchanged"
fi

# 3) instructions
echo
ok "${B}Marketplace published.${Z}"
echo "Run these inside Claude Code / Cowork:"
echo "    ${B}/plugin marketplace add $SLUG${Z}"
echo "    ${B}/plugin install $PLUGIN_NAME@$PLUGIN_NAME${Z}"
echo
echo "Already installed? Update to the latest version with:"
echo "    ${B}/plugin marketplace update $PLUGIN_NAME${Z}"
