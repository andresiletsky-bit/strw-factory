#!/usr/bin/env bash
# repo-dir.sh — ЄДИНЕ місце, де `repo:` з реєстру стає текою на диску.
#
# Джерело правди для всіх, хто резолвить репо: validate-items.sh (глоби `owns`
# рахуються на HEAD цієї теки) і bin/strw-worktree.sh у strw-ops (worktree
# заводиться від неї). До 06.09 їх було два, і вони розійшлися рівно на
# strw-ops: worktree-helper знав, що strw-ops — це КОРІНЬ парасольки STRW, а
# валідатор шукав $STRW_ROOT/strw-ops, якого не існує, — тож жоден елемент про
# раннер (bin/strw-run.sh) не міг чесно назвати своє репо (tri-070, PR #70).
#
# Використання (source, не exec):
#   . "$STRW_ROOT/strw-factory/scripts/engine/repo-dir.sh"
#   strw_repo_dir  <root> <repo>   → тека; невідоме репо → rc 64 і рядок у stderr
#   strw_repo_dirs <root>          → "repo=тека:repo=тека…" для python (validate-items)
#
# bash 3.2: без declare -A; перелік і case — паралельні, і саме тут, ніде більше.
STRW_REPOS="strw-ops strw-state strw-factory pact-ios pact-backend"

strw_repo_dir() {
    case "${2:-}" in
        strw-ops) printf '%s' "$1" ;;
        strw-state|strw-factory|pact-ios|pact-backend) printf '%s/%s' "$1" "$2" ;;
        *) printf 'невідоме репо: %s (словник — strw-factory/scripts/engine/repo-dir.sh)\n' "${2:-}" >&2; return 64 ;;
    esac
}

strw_repo_dirs() {
    local r out=""
    for r in $STRW_REPOS; do
        out="${out}${out:+:}${r}=$(strw_repo_dir "$1" "$r")"
    done
    printf '%s' "$out"
}
