#!/usr/bin/env bash
# Генератор фасадів не пише у спільну копію strw-state, якщо його про це прямо не попросили (клас tri-194).
#
# ЩО КУПИЛО. 23.10 у спільній копії ~/Developer/STRW/strw-state з'явилось 10 untracked triage-inbox.*.md і
# заблокувало `pull --ff-only` інтегратора: якась сесія у worktree виконала підказку «split-monoliths.mjs
# --regen», а генератор без `--state` брав спільну копію. Тепер без `--state` — поточна тека, якщо це checkout
# strw-state; інакше --regen/--apply відмовляють (код 2) і нічого не пишуть.
#
# Стенд: підмінений HOME зі «спільною копією» (копія живого корпусу), окрема «worktree»-копія і тека не-strw-state.
# Червоне: --regen без --state з чужої теки → 2, у спільній копії ні байта змін. Контролі: з теки strw-state —
# пише туди і лише туди; явний --state — як був; читання (--check-facade) без --state — як було (спільна копія).
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="${GEN_OVERRIDE:-$PWD/scripts/brain/split-monoliths.mjs}"
SRC="${STRW_STATE:-$(cd .. && pwd)/strw-state}"
pass=0; fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
[ -d "$SRC/triage/open" ] || { echo "⬜ корпусу $SRC/triage/open нема — перевірку НЕ ВИКОНАНО (STRW_STATE=…)" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "⬜ немає node — перевірку НЕ ВИКОНАНО" >&2; exit 2; }

H="$TMP/home"; SHARED="$H/Developer/STRW/strw-state"; WT="$TMP/wt"; ELSE="$TMP/else"
mk() { # mk <тека> — копія корпусу без фасадів за продуктом (їх створює regen)
    mkdir -p "$1/products/pact-001"
    for p in budget budget.md decisions decisions-log.md triage triage-inbox.md engine; do
        [ -e "$SRC/$p" ] && cp -R "$SRC/$p" "$1/"
    done
    rm -f "$1"/triage-inbox.*.md
}
mk "$SHARED"; mk "$WT"; mkdir -p "$ELSE"
snap() { (cd "$1" && find . -type f | sort | xargs shasum 2>/dev/null) | shasum | cut -c1-40; }
SHARED0="$(snap "$SHARED")"
gen() { (cd "$1" && shift && env HOME="$H" node "$GEN" "$@" >"$TMP/out" 2>"$TMP/err"); echo $? > "$TMP/rc"; }
check() { if eval "$2"; then printf 'ok   %s\n' "$1"; pass=$((pass+1)); else printf 'FAIL %s\n     rc=%s err: %s\n' "$1" "$(cat "$TMP/rc")" "$(head -c 300 "$TMP/err")"; fail=$((fail+1)); fi; }

gen "$ELSE" --regen
check "--regen без --state поза strw-state → 2 з причиною і ліками" \
      '[ "$(cat "$TMP/rc")" = 2 ] && grep -q "не checkout strw-state" "$TMP/err" && grep -q -- "--state" "$TMP/err"'
check "…у спільній копії ні байта змін (фасадів за продуктом не з'явилось)" \
      '[ "$(snap "$SHARED")" = "$SHARED0" ] && ! ls "$SHARED"/triage-inbox.*.md >/dev/null 2>&1'
gen "$ELSE" --apply
check "--apply без --state поза strw-state → 2" '[ "$(cat "$TMP/rc")" = 2 ] && [ "$(snap "$SHARED")" = "$SHARED0" ]'
gen "$ELSE" --regen --state
check "--state без значення (останній аргумент) — те саме, що без --state → 2" '[ "$(cat "$TMP/rc")" = 2 ]'
gen "$ELSE" --state --regen
check "--state, за яким іде прапорець, — не значення → 2" '[ "$(cat "$TMP/rc")" = 2 ] && [ "$(snap "$SHARED")" = "$SHARED0" ]'

gen "$ELSE" --regen --state "$ELSE"
check "явний --state у теку не-strw-state → 2 з причиною, не ENOENT зі стеком" \
      '[ "$(cat "$TMP/rc")" = 2 ] && grep -q "немає triage-inbox.md" "$TMP/err" && ! grep -q "ENOENT" "$TMP/err"'

gen "$WT" --regen
check "з теки strw-state без --state → пише в неї" '[ "$(cat "$TMP/rc")" = 0 ] && [ -f "$WT/triage-inbox.factory.md" ]'
check "…і лише в неї: спільна копія без змін" '[ "$(snap "$SHARED")" = "$SHARED0" ]'

rm -f "$WT"/triage-inbox.*.md
gen "$ELSE" --regen --state "$WT"
check "явний --state — як був" '[ "$(cat "$TMP/rc")" = 0 ] && [ -f "$WT/triage-inbox.factory.md" ] && [ "$(snap "$SHARED")" = "$SHARED0" ]'

gen "$ELSE" --check-facade
check "читання без --state поза strw-state — як було: спільна копія (там фасадів за продуктом немає → 1)" \
      '[ "$(cat "$TMP/rc")" = 1 ] && grep -q "triage-inbox.factory.md" "$TMP/err" && grep -q -- "--state" "$TMP/err"'
gen "$WT" --check-facade
check "читання з теки strw-state — її стан (щойно згенеровано → 0)" '[ "$(cat "$TMP/rc")" = 0 ]'

printf '\nпройшло %s · впало %s\n' "$pass" "$fail"
[ "$fail" = 0 ]
