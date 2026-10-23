#!/usr/bin/env bash
# Фасади inbox за продуктом (D4 розведення STRW і продуктів, рішення CEO 20.10, tri-199 ★ п. 4 і 6).
#
# ЩО ДОВОДИТЬ. `triage-inbox.md` змішує картки фабрики й Pact; сесія Pact мусить бачити свій зріз. Генератор
# дописує `triage-inbox.<ключ>.md` для `factory` і КОЖНОЇ теки `products/<id>/` (набір стабільний: відсутній
# фасад = «не згенеровано», не «0 відкритих»). Головне твердження —
# РОЗБИТТЯ, не вибірка: кожна відкрита картка рівно в одному фасаді за продуктом, і сума «Чекає рішення» по
# них = загальному. Ключ — за властивістю: провідний id `xxx-NNN` у `product:` (лапки, `[[ ]]`, регістр
# знімаються), якщо `products/<id>/` існує; інакше `factory` (`—`, порожнє, `factory …`, id без теки продукту).
#
# Корпус — копія реального strw-state (STRW_STATE=…, типово ../strw-state) + синтетичні картки всіх форм
# `product:`, що є в живому корпусі. Потрібен node; рівність node ≡ deno — якщо deno є.
#
# НЕГАТИВНІ КОНТРОЛІ: регенерація СТАРИМ генератором (origin/main) фасадів за продуктом не дає — тобто проби
# 1–3 червоніють без коду; ручна правка, відсутній і зайвий фасад — `--check-facade` 1; загальний фасад
# побайтово той самий, що дає старий генератор (D4 його не змінює).
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="${GEN_OVERRIDE:-$PWD/scripts/brain/split-monoliths.mjs}"
SRC="${STRW_STATE:-$(cd .. && pwd)/strw-state}"
pass=0; fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

if [ ! -d "$SRC/triage/open" ]; then
    echo "⬜ корпусу $SRC/triage/open нема — перевірку НЕ ВИКОНАНО (STRW_STATE=…)" >&2
    exit 2
fi
command -v node >/dev/null 2>&1 || { echo "⬜ немає node — перевірку НЕ ВИКОНАНО" >&2; exit 2; }

S="$TMP/state"
fixture() {
    rm -rf "$S"; mkdir -p "$S/products/pact-001" "$S/products/tea-001" "$S/products/zzz-001" "$S/products/carlog-001"
    for p in budget budget.md decisions decisions-log.md triage triage-inbox.md; do
        [ -e "$SRC/$p" ] && cp -R "$SRC/$p" "$S/"
    done
    # Регістр статусу корпусу — не предмет цієї проби (його міряє triage-status-case.test.sh).
    find "$S/triage" -name "*.md" -exec sed -i.bak \
        -e "s/^status: *OPEN *$/status: open/" -e "s/^status: *RESOLVED *$/status: resolved/" {} +
    find "$S/triage" -name "*.bak" -delete
    rm -f "$S"/triage-inbox.*.md
}
card() { # card <тека open|resolved/…> <n> <status> <рядок product: як є>
    mkdir -p "$S/triage/$1"
    cat > "$S/triage/$1/2099-01-01-$2-question.md" <<EOF
---
type: triage-item
id: tri-$2
status: $3
kind: question
date: 2099-01-01
loop: L3-build
product: $4
---
## [OPEN] 2099-01-01 · L3-build · question

- ПРОБА-$2: картка проби ключа продукту.
EOF
}
regen() { node "$GEN" --regen --state "$S" >"$TMP/out" 2>"$TMP/err"; echo $? > "$TMP/rc"; }
cf()    { node "$GEN" --check-facade ${1:+"$1"} --state "$S" >"$TMP/out" 2>"$TMP/err"; echo $? > "$TMP/rc"; }
opens() { sed -n 's/^\*\*Чекає рішення: \([0-9]*\)\.\*\*.*/\1/p' "$1" 2>/dev/null; }
sum_keys() { local t=0 f n; for f in "$S"/triage-inbox.*.md; do [ -f "$f" ] || continue; n="$(opens "$f")"; t=$((t + ${n:-0})); done; echo "$t"; }
in_facades() { grep -l "ПРОБА-$1:" "$S"/triage-inbox.*.md 2>/dev/null | sed 's#.*/triage-inbox\.##; s#\.md$##' | tr '\n' ' ' | sed 's/ $//'; }
check() { # check <назва> <умова-як-код>
    if eval "$2"; then printf 'ok   %s\n' "$1"; pass=$((pass+1))
    else printf 'FAIL %s\n     rc=%s stderr: %s\n' "$1" "$(cat "$TMP/rc" 2>/dev/null)" "$(head -c 400 "$TMP/err" 2>/dev/null)"; fail=$((fail+1)); fi
}

# ── 1. Набір і розбиття на живому корпусі + усі форми product: ─────────────
fixture
card open 901 open '"[[pact-001]]"'
card open 902 open 'pact-001'
card open 903 open 'factory'
card open 904 open '"—"'
card open 905 open ''
card open 906 open 'homeinspect-001 (не заведено в портфель)'
card open 907 open 'factory (наслідки — pact-001)'
card open 908 open 'tea-001'
card open 909 open '"Pact-001"'
card resolved/2099-W01 910 resolved 'pact-001'
card open 912 open 'factory (наслідки — pact-001, бета)'
card open 913 open '"[[tea-001]]"'
# product: лише з frontmatter — рядок «product:» у ТІЛІ картки без поля в frontmatter нічого не переводить
mkdir -p "$S/triage/open"; printf -- '---\ntype: triage-item\nid: tri-914\nstatus: open\nkind: question\ndate: 2099-01-01\nloop: L3-build\n---\n## [OPEN] 2099-01-01 · L3-build · question\n\nproduct: pact-001\n- ПРОБА-914: поле лише в тілі.\n' > "$S/triage/open/2099-01-01-914-question.md"
regen
check "regen → 0" '[ "$(cat "$TMP/rc")" = 0 ]'
check "є triage-inbox.factory.md і triage-inbox.pact-001.md" '[ -f "$S/triage-inbox.factory.md" ] && [ -f "$S/triage-inbox.pact-001.md" ]'
check "сума «Чекає рішення» фасадів за продуктом = загальному (розбиття)" '[ -n "$(opens "$S/triage-inbox.md")" ] && [ "$(sum_keys)" = "$(opens "$S/triage-inbox.md")" ]'
check "[[pact-001]] у лапках → pact-001"            '[ "$(in_facades 901)" = "pact-001" ]'
check "pact-001 → pact-001"                         '[ "$(in_facades 902)" = "pact-001" ]'
check "factory → factory"                           '[ "$(in_facades 903)" = "factory" ]'
check "«—» → factory"                               '[ "$(in_facades 904)" = "factory" ]'
check "порожнє → factory"                           '[ "$(in_facades 905)" = "factory" ]'
check "homeinspect-001 без теки продукту → factory" '[ "$(in_facades 906)" = "factory" ]'
check "factory (наслідки — pact-001) → factory"     '[ "$(in_facades 907)" = "factory" ]'
check "tea-001 з відкритою карткою → власний фасад" '[ "$(in_facades 908)" = "tea-001" ]'
check "Pact-001 (регістр) → pact-001"               '[ "$(in_facades 909)" = "pact-001" ]'
check "factory (наслідки — pact-001, бета) → factory" '[ "$(in_facades 912)" = "factory" ]'
check "[[tea-001]] у лапках → tea-001"              '[ "$(in_facades 913)" = "tea-001" ]'
check "product: лише в тілі картки → factory"       '[ "$(in_facades 914)" = "factory" ]'
check "закрита картка pact-001 — у «Останніх закритих» фасаду pact-001, не у відкритих" \
      'grep -q "2099-01-01" "$S/triage-inbox.pact-001.md" && [ "$(in_facades 910)" = "" ]'
check "фасад за продуктом — згенерований (маркер) і посилається на загальний" \
      'grep -q "brain:generated" "$S/triage-inbox.pact-001.md" && grep -q "triage-inbox.md" "$S/triage-inbox.pact-001.md"'
check "набір стабільний: фасад є і в продукту без відкритих карток (carlog-001: «Порожньо»)" \
      '[ -f "$S/triage-inbox.carlog-001.md" ] && [ "$(opens "$S/triage-inbox.carlog-001.md")" = 0 ] && grep -q "_Порожньо._" "$S/triage-inbox.carlog-001.md"'

# ── 2. Негативний контроль: старий генератор (origin/main) фасадів за продуктом не дає ─
if git cat-file -e origin/main:scripts/brain/split-monoliths.mjs 2>/dev/null; then
    OLD="$PWD/scripts/brain/.old-split-monoliths.mjs"   # поруч із lib.mjs — без нього старий не стартує
    git show origin/main:scripts/brain/split-monoliths.mjs > "$OLD"
    fixture; card open 902 open 'pact-001'
    node "$OLD" --regen --state "$S" >/dev/null 2>"$TMP/err"; echo $? > "$TMP/rc"
    cp "$S/triage-inbox.md" "$TMP/main.old"
    check "старий генератор відпрацював і фасадів за продуктом не дав (проби вище без коду червоні)" \
          '[ "$(cat "$TMP/rc")" = 0 ] && grep -q "ПРОБА-902" "$TMP/main.old" && ! ls "$S"/triage-inbox.*.md >/dev/null 2>&1'
    regen
    check "загальний фасад побайтово той самий, що дає старий генератор" 'cmp -s "$S/triage-inbox.md" "$TMP/main.old"'
    rm -f "$OLD"
fi

# ── 3. Набір рухається лише з теками products/ ──────────────────────────────
# zzz-001 — синтетичний продукт (у живому корпусі карток немає).
fixture; card open 911 open 'zzz-001'; regen
check "zzz-001: картка у фасаді zzz-001" '[ "$(in_facades 911)" = "zzz-001" ]'
rm -rf "$S/products/zzz-001"; regen
check "теку zzz-001 прибрано → regen прибрав фасад, картка перейшла у factory" \
      '[ "$(cat "$TMP/rc")" = 0 ] && [ ! -e "$S/triage-inbox.zzz-001.md" ] && grep -q "прибрано triage-inbox.zzz-001.md" "$TMP/out" && [ "$(in_facades 911)" = "factory" ]'
printf '# руками\n' > "$S/triage-inbox.yyy-001.md"; regen
check "triage-inbox.*.md БЕЗ маркера — regen не чіпає і відмовляє з назвою" \
      '[ "$(cat "$TMP/rc")" = 1 ] && [ -f "$S/triage-inbox.yyy-001.md" ] && grep -q "triage-inbox.yyy-001.md" "$TMP/err"'
rm -f "$S/triage-inbox.yyy-001.md"

# ── 4. --check-facade ловить розбіжність, відсутній і зайвий фасад ─────────
fixture; card open 902 open 'pact-001'; regen
cf;                               check "чистий стан: --check-facade → 0" '[ "$(cat "$TMP/rc")" = 0 ]'
cf triage-inbox.pact-001.md;      check "--check-facade triage-inbox.pact-001.md → 0" '[ "$(cat "$TMP/rc")" = 0 ]'
cf triage-inbox.nope-001.md;      check "фасад поза набором → 2 «невідомий фасад»" '[ "$(cat "$TMP/rc")" = 2 ]'
printf '\nруками\n' >> "$S/triage-inbox.pact-001.md"
cf triage-inbox.pact-001.md;      check "ручна правка фасаду pact-001 → 1" '[ "$(cat "$TMP/rc")" = 1 ]'
cf;                               check "…і без цілі → 1" '[ "$(cat "$TMP/rc")" = 1 ]'
regen; rm -f "$S/triage-inbox.factory.md"
cf;                               check "фасад набору відсутній → 1 з назвою" '[ "$(cat "$TMP/rc")" = 1 ] && grep -q "triage-inbox.factory.md" "$TMP/err"'
regen; cp "$S/triage-inbox.pact-001.md" "$S/triage-inbox.nodir-001.md"
cf;                               check "зайвий згенерований фасад (теки продукту немає) → 1 з назвою" '[ "$(cat "$TMP/rc")" = 1 ] && grep -q "triage-inbox.nodir-001.md" "$TMP/err"'

# ── 5. node ≡ deno ─────────────────────────────────────────────────────────
if command -v deno >/dev/null 2>&1; then
    fixture; card open 901 open '"[[pact-001]]"'; card open 908 open 'tea-001'; regen
    mkdir -p "$TMP/n"; cp "$S"/triage-inbox*.md "$TMP/n/"
    rm -f "$S"/triage-inbox.*.md
    deno run -q --allow-read --allow-write --allow-env "$GEN" --regen --state "$S" >/dev/null 2>&1
    same=1; for f in "$TMP/n"/triage-inbox*.md; do cmp -s "$f" "$S/$(basename "$f")" || same=0; done
    check "node ≡ deno побайтово для всіх фасадів inbox" '[ "$same" = 1 ] && [ "$(ls "$S"/triage-inbox*.md | wc -l)" = "$(ls "$TMP/n"/triage-inbox*.md | wc -l)" ]'
else
    echo "⬜ немає deno — рівність рантаймів не поміряно"
fi

printf '\nпройшло %s · впало %s\n' "$pass" "$fail"
[ "$fail" = 0 ]
