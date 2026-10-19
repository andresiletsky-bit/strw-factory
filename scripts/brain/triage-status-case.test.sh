#!/usr/bin/env bash
# Статус вузла тріажу читається ОДНИМ місцем, і воно не вміє мовчки викидати.
#
# ЩО ЦЕ ЛОВИТЬ (знахідка 19.10 при заведенні tri-176). `facadeTriage` бере лише
# вузли з `status === "open"` (малими). Картка зі `status: OPEN` (великими) —
# а так писав вузол tri-175 на гілці outbox/2026-09-30-L3-PM-mac — не
# потрапляла ні в «Чекає рішення: N», ні в тіло фасаду. Гейт при цьому зелений:
# `--check-facade` порівнює фасад із виводом ГЕНЕРАТОРА, а генератор ту саму
# картку теж не бачить, тож обидва боки однаково сліпі й рівні. Монолітний
# розбір (`parseTriage`) такого не допускає — заголовок, схожий на запис і не
# розібраний, там кидає виняток; читач вузлів цього захисту не мав.
#
# МЕХАНІЗМ — один, у читачі вузлів (`triageStatus`): регістр і крайові пробіли
# нормалізуються, а значення, що після цього не `open`/`resolved`, зупиняє
# генератор з назвою файлу. Гейт П1.6 у strw-state НЕ чіпається: він бачить
# лише ДОДАНІ вузли, а закриття картки (`git mv` + правка) — це R+M, повз нього.
#
# ЧОМУ ПРОБА ОКРЕМА. Потрібен лише node (як `ledger-month-required.test.sh`),
# тож не залежить від deno. Корпус — копія реального `strw-state`
# (`STRW_STATE=…`, типово `../strw-state`; у worktree типове невірне — задайте).
#
# НЕГАТИВНІ КОНТРОЛІ (без них червоний випадок міг бути червоним не з тієї
# причини): та сама картка з `status: open` МУСИТЬ рахуватись — отже вузол
# придатний, і різницю дає саме регістр; а випадок 6 доводить, що
# `--check-facade` справді червоніє, коли фасад і вузли розійшлись.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="${GEN_OVERRIDE:-$PWD/scripts/brain/split-monoliths.mjs}"
SRC="${STRW_STATE:-$(cd .. && pwd)/strw-state}"
pass=0; fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

if [ ! -d "$SRC/triage/open" ]; then
    echo "⬜ корпусу $SRC/triage/open нема — перевірка НЕ ВИКОНАНА (STRW_STATE=…)" >&2
    exit 2   # не «зелено, бо нічого не знайшли»
fi
command -v node >/dev/null 2>&1 || { echo "⬜ немає node — перевірка НЕ ВИКОНАНА" >&2; exit 2; }

fixture() { # свіжа копія корпусу на кожен випадок
    rm -rf "$TMP/state"; mkdir -p "$TMP/state"
    for p in budget budget.md decisions decisions-log.md triage triage-inbox.md; do
        [ -e "$SRC/$p" ] && cp -R "$SRC/$p" "$TMP/state/"
    done
    # Корпус — лише форма й обсяг: власні `status: OPEN` у ньому (на момент
    # написання untracked-картки 162–165 спільної копії) не мають давати шум.
    # Регістр, який міряємо, задають лише `card` нижче.
    find "$TMP/state/triage" -name "*.md" -exec sed -i.bak \
        -e "s/^status: *OPEN *$/status: open/" -e "s/^status: *RESOLVED *$/status: resolved/" {} +
    find "$TMP/state/triage" -name "*.bak" -delete
    node "$GEN" --regen --state "$TMP/state" >/dev/null 2>"$TMP/err" \
        || { echo "FAIL: фікстура не перегенерувалась: $(cat "$TMP/err")"; exit 1; }
}
# card <тека> <число> <status-як-є>: мінімальний вузол тріажу.
card() {
    local dir="$1" n="$2" st="$3"
    mkdir -p "$TMP/state/triage/$dir"
    cat > "$TMP/state/triage/$dir/2099-01-01-${n}-question.md" <<EOF
---
type: triage-item
id: tri-${n}
status: ${st}
kind: question
date: 2099-01-01
loop: L3-build
---
## [OPEN] 2099-01-01 · L3-build · question

- ПРОБА-${n}: картка для проби регістру статусу.
EOF
}
regen() { node "$GEN" --regen --state "$TMP/state" >"$TMP/out" 2>"$TMP/err"; echo $? > "$TMP/rc"; }
opens()    { sed -n 's/^\*\*Чекає рішення: \([0-9]*\)\.\*\*.*/\1/p' "$TMP/state/triage-inbox.md"; }
resolved() { sed -n 's/^\*\*Чекає рішення: [0-9]*\.\*\* .*(\([0-9]*\))\.$/\1/p' "$TMP/state/triage-inbox.md"; }

check() { # check <назва> <умова-як-код>
    if eval "$2"; then printf 'ok   %s\n' "$1"; pass=$((pass+1))
    else printf 'FAIL %s\n     rc=%s stderr: %s\n' "$1" "$(cat "$TMP/rc" 2>/dev/null)" "$(head -c 400 "$TMP/err")"; fail=$((fail+1)); fi
}

fixture; BASE_OPEN="$(opens)"; BASE_RES="$(resolved)"
check "база виміряна (лічильники — числа, не порожнеча)" \
      '[ -n "$BASE_OPEN" ] && [ -n "$BASE_RES" ]'

# ── 1. НЕГАТИВНИЙ КОНТРОЛЬ: та сама картка малими літерами рахується ────────
fixture; card open 901 open; regen
check "status: open (малі) → лічильник +1" '[ "$(opens)" = "$((BASE_OPEN+1))" ]'
check "status: open (малі) → тіло картки у фасаді" 'grep -q "ПРОБА-901" "$TMP/state/triage-inbox.md"'

# ── 2. ГОЛОВНЕ: status: OPEN (великі) не випадає з фасаду ───────────────────
fixture; card open 902 OPEN; regen
check "status: OPEN (великі) → лічильник +1" '[ "$(opens)" = "$((BASE_OPEN+1))" ]'
check "status: OPEN (великі) → тіло картки у фасаді" 'grep -q "ПРОБА-902" "$TMP/state/triage-inbox.md"'

# ── 3. Крайові пробіли й змішаний регістр — той самий клас ──────────────────
fixture; card open 903 'Open  '; regen
check "status: 'Open  ' (змішаний регістр, пробіли) → лічильник +1" '[ "$(opens)" = "$((BASE_OPEN+1))" ]'

# ── 3b. Лапки: `status: 'open'` — теж open (CHANGELOG обіцяє нормалізацію лапок) ───
fixture; card open 907 "'open'"; regen
check "status: 'open' (лапки) → лічильник +1" '[ "$(opens)" = "$((BASE_OPEN+1))" ]'

# ── 4. Закрита картка з великими: не випадає з лічильника закритих ──────────
fixture; card resolved/2099-W01 904 RESOLVED; regen
check "status: RESOLVED → закритих +1" '[ "$(resolved)" = "$((BASE_RES+1))" ]'

# ── 5. Невідоме значення зупиняє генератор вголос, а не викидається ─────────
fixture; card open 905 opne; regen
check "status: opne (друкарська помилка) → rc≠0" '[ "$(cat "$TMP/rc")" != 0 ]'
check "і повідомлення називає файл і значення" \
      'grep -q "905-question.md" "$TMP/err" && grep -q "opne" "$TMP/err"'

# ── 5b. Ключ з великої: `Status:` генератор не бачить — повідомлення мусить це сказати ──
fixture; card open 908 open; sed -i.bak "s/^status:/Status:/" "$TMP/state/triage/open/2099-01-01-908-question.md"; regen
check "Status: (ключ з великої) → rc≠0 і підказка про ключ" '[ "$(cat "$TMP/rc")" != 0 ] && grep -q "малими" "$TMP/err"'

# ── 6. ДОСЯЖНІСТЬ: гейт --check-facade червоніє на фасаді без картки OPEN ───
# Фасад зроблено ДО появи картки (як у коміті, що додав вузол без --regen).
# До фіксу генератор картку ігнорував → фасад «рівний» → гейт мовчав.
fixture; card open 906 OPEN
node "$GEN" --check-facade triage-inbox.md --state "$TMP/state" >"$TMP/out" 2>"$TMP/err"; echo $? > "$TMP/rc"
check "--check-facade: фасад без картки OPEN → rc=1 (не мовчить)" '[ "$(cat "$TMP/rc")" = 1 ]'
# Контроль: без картки той самий виклик зелений — червоне вище дала саме вона.
fixture
node "$GEN" --check-facade triage-inbox.md --state "$TMP/state" >"$TMP/out" 2>"$TMP/err"; echo $? > "$TMP/rc"
check "--check-facade: чистий корпус → rc=0 (контроль)" '[ "$(cat "$TMP/rc")" = 0 ]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
