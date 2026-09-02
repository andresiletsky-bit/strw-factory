#!/usr/bin/env bash
# Вузол журналу бюджету пізнається полем `month:`, а не текою, у якій лежить.
#
# ЩО ЦЕ ЛОВИТЬ. `budget/ledger/README.md` поля не має. Без фільтра він ставав
# рядком таблиці фасаду: місяць порожній, сума «$0» (бо Number("") === 0),
# рядків 0 — тобто фасад друкував НЕІСНУЮЧИЙ місяць із вигаданою сумою. Клас
# той самий, що «порожній набір як усе гаразд»: відсутність даних показана як
# нуль, а не як відсутність.
#
# ЧОМУ ПРОБА ОКРЕМА ВІД `split-monoliths.test.sh`. Та вимагає ДВОХ рантаймів
# (node і deno) і в контурі без deno не бігає взагалі. Ця вимагає лише node,
# тож фікс не лишається неперевіреним там, де його зробили.
#
# ДРУГЕ ТВЕРДЖЕННЯ, не менш важливе за перше: пропуск НЕ МОВЧАЗНИЙ. Файл без
# `month:` — це або README (гаразд), або зламаний вузол місяця; тихо викинути
# другий означало б замінити один дефект на тихіший.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="$PWD/scripts/brain/split-monoliths.mjs"
SRC="${STRW_STATE:-$(cd .. && pwd)/strw-state}"
pass=0; fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

if [ ! -d "$SRC/budget/ledger" ]; then
    echo "⬜ корпусу $SRC/budget/ledger нема — перевірка НЕ ВИКОНАНА" >&2
    exit 2   # не «зелено, бо нічого не знайшли»
fi

fixture() { # свіжа копія корпусу на кожен випадок
    rm -rf "$TMP/state"; mkdir -p "$TMP/state"
    for p in budget budget.md decisions decisions-log.md triage triage-inbox.md; do
        [ -e "$SRC/$p" ] && cp -R "$SRC/$p" "$TMP/state/"
    done
}
regen() { node "$GEN" --regen --state "$TMP/state" 2>"$TMP/err"; }

check() { # check <назва> <умова-як-код>
    if eval "$2"; then printf 'ok   %s\n' "$1"; pass=$((pass+1))
    else printf 'FAIL %s\n     stderr: %s\n' "$1" "$(cat "$TMP/err")"
         grep -n '^|' "$TMP/state/budget.md" | sed 's/^/     /'; fail=$((fail+1)); fi
}

# ── 1. README не стає місяцем, і про пропуск сказано вголос ─────────────────
fixture; regen
check "README.md не дає рядка з порожнім місяцем" \
      '! grep -qE "^\| +\| \\\$" "$TMP/state/budget.md"'
check "пропуск названий поіменно, а не мовчазний" \
      'grep -q "README.md" "$TMP/err"'

# ── 2. НЕГАТИВНИЙ КОНТРОЛЬ: фільтр не викидає справжні місяці ───────────────
# Без цього випадку проба 1 проходила б і тоді, коли з таблиці зникло ВСЕ.
check "справжні місяці лишаються в таблиці" \
      '[ "$(grep -cE "^\| 2026-[0-9]{2} \|" "$TMP/state/budget.md")" -ge 2 ]'

fixture
printf -- '---\nmonth: 2099-01\nexternal_usd: 7\n---\n' > "$TMP/state/budget/ledger/2099-01.md"
regen
check "новий вузол із month: зʼявляється в таблиці" \
      'grep -qE "^\| 2099-01 \| \\\$7 \|" "$TMP/state/budget.md"'

# ── 3. ЗЛАМАНИЙ вузол місяця — видно, а не тихо викинуто ────────────────────
fixture
sed -i.bak '/^month:/d' "$TMP/state/budget/ledger/2026-07.md"
regen
check "місяць без month: названий у пропущених" \
      'grep -q "2026-07.md" "$TMP/err"'
check "і його рядка в таблиці нема — краще відсутній, ніж вигаданий" \
      '! grep -qE "^\| 2026-07 \|" "$TMP/state/budget.md"'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
