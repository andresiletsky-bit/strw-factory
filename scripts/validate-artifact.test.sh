#!/usr/bin/env bash
# validate-artifact.test.sh — власний тест найгарячішого гейта фабрики.
# Запуск: bash scripts/validate-artifact.test.sh
#
# ЧОМУ. F10 аудиту 2026-09-03: `validate-artifact.sh` стоїть ПЕРШИМ кроком
# checker-фази кожної петлі і власного тесту не мав. Прецедент цього ж класу
# уже був куплений: тип `design-delta`, названий у виході паспорта L7,
# у `case` скрипта був відсутній — перший крок чекера L7 віддавав би
# `unknown type` і exit 2, тобто петля не могла завершитись ніколи.
#
# ПЕРЕЛІКИ СЕКЦІЙ ТУТ — НЕЗАЛЕЖНА КОПІЯ КОНТРАКТУ, не імпорт зі скрипта.
# Тест, що читає списки з предмета перевірки, зеленів би на будь-якій зміні
# контракту — включно з мовчазним видаленням обов'язкової секції.
#
# bash 3.2 + BSD: без declare -A (тип і секції — паралельні рядки з роздільником |).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="${STRW_VALIDATE_ARTIFACT:-$HERE/validate-artifact.sh}"
GOLDEN="$HERE/../references/evals/golden"
PASS=0; FAIL=0; SKIP=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

ok()  { PASS=$((PASS+1)); printf 'PASS · %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL · %s\n%s\n' "$1" "${2:-}"; }

# Контракти (artifact-contracts.md). Роздільник — «|».
TYPES="idea-card validation-report prd design-delta regression-report build-report launch-checklist growth-report portfolio-brief retro-note copy-guide design-research design-options checker-verdict"
sections_of() {
  case "$1" in
    idea-card)         echo "Проблема|Сигнали попиту|Тип|Гіпотеза монетизації|Чому ми|ICE" ;;
    validation-report) echo "TAM/SAM/SOM|Конкуренти|Попит|Ризики|Найдешевша перевірка|ICE|Рекомендація|Critic-review|Не встановлено" ;;
    prd)               echo "Проблема і цілі|Метрики успіху|Scope MVP|НЕ-цілі|User stories|Залежності|Tracking|Оцінка обсягу" ;;
    design-delta)      echo "Змінені одиниці|Спільні причини|Непояснене|Нечитані джерела|Не встановлено" ;;
    regression-report) echo "Фаза 1|Фаза 2|Фаза 3|Що лишила кожна червона|Не встановлено" ;;
    build-report)      echo "Реалізовано vs PRD|Тести|Security|Tracking|Обмеження|Deploy-checklist|Code-review" ;;
    launch-checklist)  echo "Тести|Аналітика|Security|Rollback|Сторінка продукту|Ціни" ;;
    growth-report)     echo "Кампанії|Метрики|Контент|Наступний тиждень" ;;
    portfolio-brief)   echo "Продукти|Метрики фабрики|Фокуси|KILL|Чекає рішення|Не встановлено" ;;
    retro-note)        echo "Що спрацювало|Патерни|Health flags|Пропозиції|Не встановлено" ;;
    copy-guide)        echo "Що виміряно|Звертання|Тон|Словник|Шаблони|Чорний список|Мови|Не встановлено" ;;
    design-research)   echo "Задача і контекст|Як це розв'язують інші|Що беремо|Що свідомо відкидаємо|Ризики вибору|Не встановлено" ;;
    design-options)    echo "Варіанти|Критерії порівняння|Обраний і чому|Програшний і чому збережений|Не встановлено" ;;
    checker-verdict)   echo "Проходи|Знахідки|Детермінована дія|Не перевірено" ;;
  esac
}

# build <тип> <файл> [пропустити-секцію] [спорожнити-секцію]
build() {
  local type="$1" out="$2" skip="${3:-}" empty="${4:-}" s IFS='|'
  : > "$out"
  [ "$type" = "checker-verdict" ] && printf 'VERDICT: PASS\n\n' >> "$out"
  for s in $(sections_of "$type"); do
    [ "$s" = "$skip" ] && continue
    printf '## %s\n' "$s" >> "$out"
    if [ "$s" = "$empty" ]; then printf '\n' >> "$out"; continue; fi
    if [ "$type" = "checker-verdict" ] && [ "$s" = "Знахідки" ]; then
      printf -- '- [Nit] src/a.ts:1 — назва нічого не каже — сценарій: читач гадає.\n\n' >> "$out"
    else
      printf 'Тіло секції: одне речення, щоб вона не рахувалась порожньою.\n\n' >> "$out"
    fi
  done
  [ "$type" = "copy-guide" ] && printf '```yaml\nrules:\n  address: ви\n```\n' >> "$out"
  return 0
}

echo "── 1. Усі golden проходять рівень 0 ──"
N=0
for f in "$GOLDEN"/*.golden.md; do
  [ -f "$f" ] || continue
  t="$(basename "$f" .golden.md)"; N=$((N+1))
  if out="$(bash "$V" "$t" "$f" 2>&1)"; then ok "golden $t"; else bad "golden $t мусив пройти" "$out"; fi
done
[ "$N" -ge 6 ] && ok "знайдено $N еталонів" || bad "еталонів лише $N — набір підозріло малий"

echo "── 2. Повний синтетичний артефакт кожного типу проходить ──"
for t in $TYPES; do
  build "$t" "$TMP/$t.md"
  if out="$(bash "$V" "$t" "$TMP/$t.md" 2>&1)"; then ok "$t · повний"; else bad "$t · повний мусив пройти" "$out"; fi
done

echo "── 3. Кожна відсутня обов'язкова секція червонить І називається ──"
for t in $TYPES; do
  IFS='|'; set -- $(sections_of "$t"); unset IFS
  for s in "$@"; do
    build "$t" "$TMP/cut.md" "$s"
    out="$(bash "$V" "$t" "$TMP/cut.md" 2>&1)"; rc=$?
    if [ "$rc" -ne 1 ]; then
      bad "$t без «$s» мусив дати rc=1, дав $rc" "$out"
    elif printf '%s' "$out" | grep -q "$s"; then
      ok "$t без «$s» → FAIL із назвою секції"
    else
      bad "$t без «$s» червоніє, але назви секції у виводі немає" "$out"
    fi
  done
done

echo "── 4. Порожня секція червонить ──"
for t in $TYPES; do
  IFS='|'; set -- $(sections_of "$t"); unset IFS
  s="$1"
  build "$t" "$TMP/empty.md" "" "$s"
  out="$(bash "$V" "$t" "$TMP/empty.md" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'empty section'; then
    ok "$t · порожня «$s» → FAIL"
  else
    bad "$t · порожня «$s» мусила дати FAIL (rc=$rc)" "$out"
  fi
done

echo "── 5. Невідомий тип → rc=2, і саме 2 ──"
build idea-card "$TMP/any.md"
out="$(bash "$V" no-such-type "$TMP/any.md" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "невідомий тип → rc=2" || bad "невідомий тип дав rc=$rc, а не 2" "$out"
out="$(bash "$V" idea-card "$TMP/nope.md" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "відсутній файл → rc=1, ВІДМІННИЙ від 2 «невідомого типу»" || bad "відсутній файл дав rc=$rc" "$out"

echo "── 6. checker-verdict: три перевірки поверх секцій ──"
build checker-verdict "$TMP/cv.md"
perl -pi -e 's/^VERDICT: PASS\n$//' "$TMP/cv.md"
out="$(bash "$V" checker-verdict "$TMP/cv.md" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'VERDICT'; } \
  && ok "без рядка VERDICT → FAIL" || bad "без VERDICT дав rc=$rc" "$out"

build checker-verdict "$TMP/cv2.md"
perl -pi -e 's/^- \[Nit\] /- /' "$TMP/cv2.md"
out="$(bash "$V" checker-verdict "$TMP/cv2.md" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'severity'; } \
  && ok "знахідка без severity → FAIL" || bad "знахідка без severity дала rc=$rc" "$out"

build checker-verdict "$TMP/cv3.md"
perl -pi -e 's/^- \[Nit\] src\/a\.ts:1.*$/- [Nit] a:1 — x — y\n- [Nit] b:2 — x — y\n- [Nit] c:3 — x — y\n- [Nit] d:4 — x — y\n- [Nit] e:5 — x — y\n- [Nit] f:6 — x — y/' "$TMP/cv3.md"
out="$(bash "$V" checker-verdict "$TMP/cv3.md" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'стелі 5'; } \
  && ok "6 Nit при стелі 5 → FAIL" || bad "6 Nit дали rc=$rc" "$out"
# Рівно 5 — межа перевіряється ЧИСЛОМ, інакше «стеля» була б заборона на будь-які Nit.
perl -pi -e 's/^- \[Nit\] f:6.*$//' "$TMP/cv3.md"
out="$(bash "$V" checker-verdict "$TMP/cv3.md" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "рівно 5 Nit проходять — стеля саме 5, не «жодного»" || bad "5 Nit дали rc=$rc" "$out"

echo "── 7. persona-card: перевірки по YAML, не по заголовках ──"
P="$TMP/personas.md"
cp "$GOLDEN/persona-card.golden.md" "$P"
perl -pi -e 's/^anti_persona: .*$/anti_persona:/ if $. < 40' "$P"
out="$(bash "$V" persona-card "$P" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'anti_persona'; } \
  && ok "persona-card з порожнім anti_persona → FAIL" || bad "порожній anti_persona дав rc=$rc" "$out"

echo "── 8. НЕГАТИВНИЙ КОНТРОЛЬ: мутація скрипта ──"
# Проби вище доводять щось лише тоді, коли вміють почервоніти від правки самого
# скрипта. Тут вимикаємо перевірку секцій і перевіряємо, що випадок «без секції»
# СТАЄ зеленим — тобто проби міряють скрипт, а не власні фікстури.
M="$TMP/mutated.sh"; cp "$V" "$M"
perl -pi -e 's/\|\| MISSING\+=\("\$section"\)/|| true/' "$M"
if grep -q 'MISSING+=("$section")' "$M"; then
  bad "мутація не наклалась — контроль нічого не доводить"
else
  ok "мутація «перевірка секцій вимкнена» наклалась"
  build idea-card "$TMP/nc.md" "Гіпотеза монетизації"
  if bash "$M" idea-card "$TMP/nc.md" >/dev/null 2>&1; then
    ok "з вимкненою перевіркою секцій артефакт без секції ПРОХОДИТЬ — проба §3 міряє скрипт"
  else
    bad "мутований скрипт усе одно червонить — проба §3 червоніє з іншої причини"
  fi
fi
M2="$TMP/mutated2.sh"; cp "$V" "$M2"
# Перейменування накопичувача, а не видалення рядка: видалити `EMPTY+=` з гілки
# `if … then` лишило б `then` без тіла, скрипт помер би синтаксисом — і
# «порожня секція пройшла» було б неправдою про причину.
perl -pi -e 's/(?<!IGNORED_)EMPTY\+=/IGNORED_EMPTY+=/g' "$M2"
if [ "$(grep -c 'IGNORED_EMPTY+=' "$M2")" -ge 2 ] && bash -n "$M2" 2>/dev/null; then
  ok "мутація «перевірка порожніх секцій вимкнена» наклалась"
  build portfolio-brief "$TMP/nc2.md" "" "Продукти"
  if bash "$M2" portfolio-brief "$TMP/nc2.md" >/dev/null 2>&1; then
    ok "з вимкненою перевіркою порожнеч порожня секція ПРОХОДИТЬ — проба §4 міряє скрипт"
  else
    bad "мутований скрипт усе одно червонить на порожній секції"
  fi
else
  bad "мутація порожніх секцій не наклалась — контроль §4 нічого не доводить"
fi

# Файл, який grep не може прочитати (chmod 000), — 2 з причиною. Доки заголовки
# читались через `done < <(grep … | cut …)`, падіння grep = «порожніх секцій
# немає» (форма procsub-loop-input, strw-state/scripts/lib/nonportable-forms.tsv).
printf '## Що спрацювало\nx\n' > "$TMP/unreadable.md"; cp "$TMP/unreadable.md" "$TMP/readable.md"; chmod 000 "$TMP/unreadable.md"
if cat "$TMP/unreadable.md" >/dev/null 2>&1; then
  SKIP=$((SKIP+1)); printf 'SKIP · (видимий, у підсумку) chmod 000 не блокує читання (uid=%s) — проба «файл не читається» тут не вимірюється\n' "$(id -u)"
else
  OUT_U="$(bash "$V" retro-note "$TMP/unreadable.md" 2>&1)"; RC_U=$?
  if [ "$RC_U" = 2 ] && printf '%s' "$OUT_U" | grep -q 'не прочитав'; then ok "файл не читається → 2 з причиною (grep не прочитав), не «порожніх секцій немає»"
  else bad "файл не читається мав дати 2 з причиною (дав $RC_U)" "$OUT_U"; fi
fi
chmod 644 "$TMP/unreadable.md"
# Нуль заголовків — легально: це grep=1, не збій. Регресія «_grc -eq 0» зробила б
# кожен файл без ##/### FAIL 2, і близнюк із заголовком цього б не зловив.
printf 'просто текст без жодного заголовка\n' > "$TMP/noheaders.md"
OUT_N="$(bash "$V" retro-note "$TMP/noheaders.md" 2>&1)"; RC_N=$?
if [ "$RC_N" != 2 ] && ! printf '%s' "$OUT_N" | grep -q 'не прочитав'; then ok "нуль заголовків → не 2 і без «не прочитав» (grep=1 легально, rc=$RC_N)"
else bad "нуль заголовків мав бути легальним (дав $RC_N)" "$OUT_N"; fi
# Контроль-близнюк: той самий вміст читабельним — НЕ 2 і без «не прочитав»
# (інакше регресія «завжди exit 2 з цим текстом» пройшла б проба вище).
OUT_R="$(bash "$V" retro-note "$TMP/readable.md" 2>&1)"; RC_R=$?
if [ "$RC_R" != 2 ] && ! printf '%s' "$OUT_R" | grep -q 'не прочитав'; then ok "контроль: читабельна копія — не 2 і без «не прочитав» (rc=$RC_R)"
else bad "контроль: читабельна копія дала 2 або «не прочитав»" "$OUT_R"; fi

echo
echo "Разом: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
