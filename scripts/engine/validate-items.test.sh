#!/usr/bin/env bash
# validate-items.test.sh — проби на резолвлення `repo:` у теку (repo-dir.sh).
# Запуск: bash scripts/engine/validate-items.test.sh   (потрібна парасолька STRW з клонами)
#
# ЧОМУ. tri-070 / PR strw-state #70: валідатор шукав $STRW_ROOT/strw-ops, а
# strw-ops — це сам корінь парасольки. Жоден елемент про раннер (bin/strw-run.sh)
# не міг чесно назвати repo, а «реєстр валідний» цього не бачив. Тепер словник
# один — repo-dir.sh — і ці проби тримають його в обидва боки:
#   · смуга з repo: strw-ops і owns bin/** → глоби рахуються на HEAD кореня;
#   · той самий реєстр зі СТАРИМ правилом ($root/strw-ops) → ERROR
#     (негативний контроль: набір, який не вміє почервоніти, нічого не доводить);
#   · repo поза словником → ERROR, що називає словник.
#
# Фікстура — копія ЖИВОГО реєстру (engine/ + decisions/) у tmp, парасолька справжня:
# смуги реєстру посилаються на всі п'ять репо, і підробити п'ять клонів дорожче,
# ніж прочитати справжні. Це робить пробу залежною від наявності клонів — на Mac
# фабрики вони є завжди; без них тест каже SKIP, не PASS.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="$HERE/validate-items.sh"
# Парасолька: $STRW_ROOT, інакше ../../.. від скрипта; з worktree
# (strw-factory-worktrees/<гілка>/scripts/engine) це тека worktree-ів — тоді ще
# на рівень вище. Той самий клас, що й у самого валідатора (див. його шапку).
if [ -z "${STRW_ROOT:-}" ]; then
    STRW_ROOT="$(cd "$HERE/../../.." && pwd)"
    while [ ! -d "$STRW_ROOT/strw-state/engine" ] && [ "$STRW_ROOT" != "/" ]; do
        STRW_ROOT="$(dirname "$STRW_ROOT")"
    done
fi
PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ok()  { PASS=$((PASS+1)); printf 'PASS · %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL · %s\n%s\n' "$1" "${2:-}"; }

LIVE="$STRW_ROOT/strw-state"
for need in "$LIVE/engine/lanes.yaml" "$STRW_ROOT/.git" "$STRW_ROOT/pact-ios/.git"; do
    [ -e "$need" ] || { echo "SKIP · немає $need — проба потребує парасольки STRW з клонами"; exit 0; }
done

# Фікстурний strw-state: engine/ і decisions/ поруч, як у живому.
FX="$TMP/strw-state"; mkdir -p "$FX"
cp -R "$LIVE/engine" "$FX/engine"
cp -R "$LIVE/decisions" "$FX/decisions" 2>/dev/null || true
[ -f "$LIVE/decisions-log.md" ] && cp "$LIVE/decisions-log.md" "$FX/decisions-log.md"

add_lane() { # add_lane <repo> — смуга ops-tooling з owns bin/** tests/** перед `tools:`
    python3 - "$FX/engine/lanes.yaml" "$1" <<'PY'
import sys, io
p, repo = sys.argv[1], sys.argv[2]
t = io.open(p, encoding="utf-8").read()
lane = ("  - id: ops-tooling\n    repo: %s\n    owns: [\"bin/**\", \"tests/**\"]\n"
        "    resources: []\n    codex_maker: allowed\n    codex_evidence: \"проба\"\n") % repo
k = t.index("\ntools:")
io.open(p, "w", encoding="utf-8").write(t[:k] + "\n" + lane + t[k:])
PY
}

run_v() { STRW_ROOT="$STRW_ROOT" bash "$V" "$FX/engine" 2>&1; }

# 0. контроль: фікстура без змін валідна (інакше далі міряли б не те)
out="$(run_v)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "фікстура = живий реєстр: валідна (контроль)"; else bad "фікстура без змін мала б бути валідною" "$out"; fi

# 1. негативний контроль — СТАРЕ правило ($root/strw-ops) на тій самій смузі → ERROR
add_lane strw-ops
OLD="$TMP/old-repo-dir.sh"
cat > "$OLD" <<'SH'
STRW_REPOS="strw-ops strw-state strw-factory pact-ios pact-backend"
strw_repo_dir() { printf '%s/%s' "$1" "$2"; }
strw_repo_dirs() { local r out=""; for r in $STRW_REPOS; do out="${out}${out:+:}${r}=$(strw_repo_dir "$1" "$r")"; done; printf '%s' "$out"; }
SH
out="$(STRW_REPO_DIR_SH="$OLD" run_v)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "не знайдено як git-клон"; then
    ok "негативний контроль: старе правило \$root/strw-ops → ERROR «не знайдено як git-клон»"
else bad "старе правило мало б червоніти на strw-ops" "$out"; fi

# 2. новий словник: та сама смуга → валідно, глоби bin/** tests/** матчать корінь
out="$(run_v)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q "ops-tooling"; then
    ok "repo: strw-ops → корінь парасольки; owns bin/** tests/** рахуються на HEAD кореня"
else bad "смуга ops-tooling з repo strw-ops мала б пройти" "$out"; fi

# 3. репо поза словником → ERROR, що називає словник
cp -R "$LIVE/engine" "$FX/engine.clean" && rm -rf "$FX/engine" && mv "$FX/engine.clean" "$FX/engine"
add_lane nope
out="$(run_v)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "невідоме словнику strw-factory/scripts/engine/repo-dir.sh"; then
    ok "repo: nope → ERROR із назвою словника"
else bad "вигадане репо мало б бути ERROR із назвою словника" "$out"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
