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
# l4-trace звіряє email рев'юера з company-context: golden — проти фікстури набору,
# не живого strw-state (там email немає — і golden червонів би з причини стану фабрики).
export STRW_COMPANY_CONTEXT="$HERE/../references/evals/fixtures/company-context.md"

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
      bad "$t без «${s}» мусив дати rc=1, дав $rc" "$out"
    elif printf '%s' "$out" | grep -q "$s"; then
      ok "$t без «${s}» → FAIL із назвою секції"
    else
      bad "$t без «${s}» червоніє, але назви секції у виводі немає" "$out"
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
    ok "$t · порожня «${s}» → FAIL"
  else
    bad "$t · порожня «${s}» мусила дати FAIL (rc=$rc)" "$out"
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

echo "── 9. l4-trace: виклики Metricool у trace, не секції ──"
# Seeded-фікстури (references/evals/seeded/l4-trace) ганяє run.sh; тут — гілки, яких
# там немає: помилка ForReview, чужий стан, хибні червоні на датах і пунктах, і
# мутація самого правила. Кожен випадок — golden плюс одна правка.
LG="$GOLDEN/l4-trace.golden.md"
l4() { # l4 <назва> <rc> <підрядок-виводу або ""> <perl-вираз>
  local name="$1" want="$2" needle="$3" out rc
  cp "$LG" "$TMP/l4.md"; perl -0pi -e "$4" "$TMP/l4.md"
  if cmp -s "$LG" "$TMP/l4.md"; then bad "$name: правка не наклалась — випадок нічого не доводить"; return; fi
  out="$(bash "$V" l4-trace "$TMP/l4.md" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then bad "$name: rc=$rc, чекав $want" "$out"
  elif [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then bad "$name: rc=$want, але причини «${needle}» у виводі немає" "$out"
  else ok "$name"; fi
}
out="$(bash "$V" l4-trace "$LG" 2>&1)" && ok "l4-trace golden → PASS" || bad "l4-trace golden мусив пройти" "$out"
out="$(bash "$V" growth-report "$LG" 2>&1)" && ok "той самий golden — валідний growth-report" || bad "l4-trace golden не проходить growth-report" "$out"
l4 "без секції Trace (L4) → FAIL" 1 "немає секції «Trace (L4)»" 's/### Trace \(L4\)/### Хід роботи/'
l4 "заголовок лише МІСТИТЬ «Trace (L4)» — це звіт, не trace (р.3 P02)" 1 "без тегу" 's/## Метрики\n/## Метрики (з Trace (L4))\n- TikTok: перегляди — 48 000.\n/'
l4 "\`- call:\` під заголовком, що лише МІСТИТЬ «Trace (L4)», — поза trace → FAIL" 1 "поза «Trace (L4)»" 's/(## Наступний тиждень\n)/## Додаток (з Trace (L4))\n- call: getBestTimeToPostByNetwork {}\n  > {}\n\n$1/'
l4 "вигаданий інструмент → FAIL" 1 "немає серед дев'яти" 's/- call: getAnalyticsDataByMetrics/- call: publishPost/'
# Помилка ForReview (тариф без team management): без повтору і з карткою — PASS; повтор — FAIL.
GSP='- call: getScheduledPosts \{[^\n]*\}'
ERR='s/  > \{"id": 501, "uuid": "u-501", "plannerUrl": "[^"]+"\}/  > {"error": "Your plan does not allow the approval system"}/'
CARD2='s/- inbox: tri-NNN — TikTok/- inbox: tri-NNN — виклик #2 відповів помилкою; TikTok/'
REPEAT="s/(${GSP}\n  > \[\{\"id\": 501[^\n]*\n[^\n]*\n)/\$1- call: createScheduledPostForReview {\"blogId\": 1, \"reviewers\": \"ceo\\\@strw.example\", \"approvalSystem\": \"all\", \"info\": {\"autoPublish\": false}}\n  > {\"error\": \"retry\"}\n- call: getScheduledPosts {}\n  > []\n/"
STOP='s/- call: updateScheduledPost .*?(- inbox: )/$1/s'
l4 "ForReview відповів помилкою, далі нічого не пише, картка про #2 → PASS" 0 "" "$ERR; $CARD2; $STOP"
l4 "ForReview відповів помилкою, картка є, але про інше (TikTok) → FAIL" 1 "про цей виклик" "$ERR; $STOP"
l4 "ForReview відповів помилкою і повторений → FAIL" 1 "після нього є запис" "$ERR; $CARD2; $STOP; $REPEAT"
l4 "після помилки ForReview — update і send того ж поста → FAIL (р.4 A12)" 1 "після нього є запис" "$ERR; $CARD2"
l4 "ForReview відповів помилкою, картки в inbox немає → FAIL" 1 "inbox" "$ERR; $STOP; s/- inbox: [^\n]*\n//"
l4 "«Forbidden» у message без ключа error — не помилка, але й поста немає → FAIL (р.1 I)" 1 "немає uuid/id" 's/  > \{"id": 501, "uuid": "u-501", "plannerUrl": "[^"]+"\}/  > {"message": "Forbidden"}/'
l4 "«without errors» у message — не помилка; пост з autoPublish true → FAIL (р.4 A11)" 1 "autoPublish: true" 's/  > \{"id": 503, "uuid": "u-501", "plannerUrl": "[^"]+"\}/  > {"id": 503, "uuid": "u-501", "plannerUrl": "https:\/\/app.metricool.com\/planner\/u-501", "message": "Sent for review without errors"}/; s/  > \[\{"id": 503, "uuid": "u-501", /  > [{"id": 503, "uuid": "u-501", "autoPublish": true, /'
l4 "«Помилки…» в ехо тексту поста — не помилка → PASS (р.3 F19)" 0 "" 's/"id": 501, "uuid": "u-501", "plannerUrl": "([^"]+)"\}/"id": 501, "uuid": "u-501", "plannerUrl": "$1", "text": "Помилки новачків у звичках"}/'
# Стан і пост у getScheduledPosts (паспорт 4b–4c).
l4 "стан не pending review, картка про #2 є → PASS (4c)" 0 "" 's/стан: поле стану не встановлено — доказ «на затвердження» — plannerUrl у відповіді виклику #2/стан: scheduled/; s/- inbox: tri-NNN — TikTok/- inbox: tri-NNN — виклик #2 не на затвердженні; TikTok/'
l4 "стан не pending review, картки немає → FAIL" 1 "не pending review" 's/стан: поле стану не встановлено — доказ «на затвердження» — plannerUrl у відповіді виклику #2/стан: scheduled/'
l4 "«стан: not pending review» — заперечення, картки немає → FAIL (р.2 M18)" 1 "не pending review" 's/стан: поле стану не встановлено — доказ «на затвердження» — plannerUrl у відповіді виклику #6/стан: not pending review/'
l4 "«pending review» без поля стану у відповіді → FAIL (р.4 A10)" 1 "поля стану у відповіді немає" 's/стан: поле стану не встановлено — доказ «на затвердження» — plannerUrl у відповіді виклику #6/стан: pending review/'
l4 "під getScheduledPosts після ForReview немає рядка стан → FAIL" 1 "стан:" 's/  стан: [^\n]*виклику #2\n//'
l4 "«не встановлено», plannerUrl немає → FAIL" 1 "plannerUrl" 's/"id": 503, "uuid": "u-501", "plannerUrl": "[^"]+"/"id": 503, "uuid": "u-501"/'
l4 "plannerUrl: null → FAIL (р.1 D2)" 1 "plannerUrl" 's/"id": 503, "uuid": "u-501", "plannerUrl": "[^"]+"/"id": 503, "uuid": "u-501", "plannerUrl": null/'
l4 "plannerUrl «n/a» — не посилання → FAIL (р.2 M09)" 1 "plannerUrl" 's/"id": 503, "uuid": "u-501", "plannerUrl": "[^"]+"/"id": 503, "uuid": "u-501", "plannerUrl": "n\/a"/'
l4 "поста немає в getScheduledPosts, картки немає → FAIL (р.1 D)" 1 "поста немає у відповіді" 's/  > \[\{"id": 503[^\n]*/  > []/'
l4 "два пости з тим самим uuid → FAIL (р.3 S4)" 1 "постів із" 's/  > \[\{"id": 503, "uuid": "u-501", ([^\n]*)\]/  > [{"id": 503, "uuid": "u-501", $1, {"id": 504, "uuid": "u-501", "status": "SCHEDULED"}]/'
l4 "«не встановлено», а у відповіді status PUBLISHED → FAIL (р.2 S1)" 1 "поле є" 's/  > \[\{"id": 503, "uuid": "u-501", /  > [{"id": 503, "uuid": "u-501", "status": "PUBLISHED", /'
l4 "status лише у вкладеному providers → теж поле → FAIL (р.3 S3)" 1 "поле є" 's/  > \[\{"id": 503, "uuid": "u-501", /  > [{"id": 503, "uuid": "u-501", "providers": [{"network": "instagram", "status": "PUBLISHED"}], /'
l4 "autoPublish true усередині info-рядка поста → FAIL (р.3 S3)" 1 "autoPublish: true" 's/  > \[\{"id": 503, "uuid": "u-501", /  > [{"id": 503, "uuid": "u-501", "info": "{\\"autoPublish\\": true}", /'
l4 "autoPublish true у пості → FAIL" 1 "autoPublish: true" 's/  > \[\{"id": 503, "uuid": "u-501", /  > [{"id": 503, "uuid": "u-501", "autoPublish": true, /'
l4 "«pending review», а status SCHEDULED → FAIL (р.2 S2)" 1 "а у відповіді стан SCHEDULED" 's/  > \[\{"id": 503, "uuid": "u-501", /  > [{"id": 503, "uuid": "u-501", "status": "SCHEDULED", /; s/стан: поле стану не встановлено — доказ «на затвердження» — plannerUrl у відповіді виклику #6/стан: pending review/'
l4 "«pending review», а status NOT_IN_REVIEW → FAIL (р.3 S5)" 1 "NOT_IN_REVIEW" 's/  > \[\{"id": 503, "uuid": "u-501", /  > [{"id": 503, "uuid": "u-501", "status": "NOT_IN_REVIEW", /; s/стан: поле стану не встановлено — доказ «на затвердження» — plannerUrl у відповіді виклику #6/стан: pending review/'
l4 "«pending review», а reviewState SCHEDULED → FAIL (р.3 N22)" 1 "SCHEDULED" 's/  > \[\{"id": 503, "uuid": "u-501", /  > [{"id": 503, "uuid": "u-501", "reviewState": "SCHEDULED", /; s/стан: поле стану не встановлено — доказ «на затвердження» — plannerUrl у відповіді виклику #6/стан: pending review/'
l4 "«pending review» і status PENDING_REVIEW → PASS" 0 "" 's/  > \[\{"id": 503, "uuid": "u-501", /  > [{"id": 503, "uuid": "u-501", "status": "PENDING_REVIEW", /; s/стан: поле стану не встановлено — доказ «на затвердження» — plannerUrl у відповіді виклику #6/стан: pending review/'
l4 "id рядком без uuid — пост звіряється по id → PASS (р.3 F20)" 0 "" 's/  > \{"id": 502, "uuid": "u-501"\}/  > {"id": "502"}/'
# Передумова 4a і канон запису.
l4 "reviewer оголошено ПІСЛЯ ForReview-виклику → FAIL (р.1 M01)" 1 "перед викликом немає" 's/(- reviewer: [^\n]*\n)((?:.*\n)*?)(- call: getScheduledPosts \{[^\n]*\}\n  > \[\{"id": 501)/$2$1$3/'
l4 "виклик без цитати відповіді → FAIL (р.1 M16)" 1 "немає цитати відповіді" 's/(- call: getAnalyticsDataByMetrics [^\n]*\n)  > [^\n]*\n/$1/'
l4 "reviewer не з company-context → FAIL" 1 "company-context" 's/ceo\@strw.example/smm\@strw.example/g'
l4 "reviewer — підрядок email Andrii → FAIL (р.1 E)" 1 "не email Andrii" 's/ceo\@strw.example/o\@strw.exam/g'
l4 "аргументи запису не JSON → FAIL" 1 "не JSON" 's/(- call: updateScheduledPost) \{[^\n]*/$1 id=501, autoPublish=false/'
l4 "info рядком із JSON, autoPublish false → PASS (р.2 R1)" 0 "" 's/"info": \{"text": "Як не зірвати звичку на вихідних", "providers": \[\{"network": "instagram"\}\], "autoPublish": false\}/"info": "{\\"text\\": \\"x\\", \\"autoPublish\\": false}"/'
l4 "info рядком із JSON, autoPublish true → FAIL (р.2 R2)" 1 "autoPublish: false" 's/"info": \{"text": "Як не зірвати звичку на вихідних", "providers": \[\{"network": "instagram"\}\], "autoPublish": false\}/"info": "{\\"text\\": \\"x\\", \\"autoPublish\\": true}"/'
l4 "createScheduledPost прозою в тілі звіту → FAIL (р.1 C2)" 1 "звіт рядок" 's/(## Контент\n)/$1- Ще одну чернетку опубліковано напряму через createScheduledPost.\n/'
l4 "create_scheduled_post прозою в trace → FAIL (р.1 C3)" 1 "createscheduledpost" 's/(- inbox: )/- Також create_scheduled_post для другої чернетки.\n$1/'
l4 "createscheduledpost малими в trace → FAIL (р.1 C4)" 1 "createscheduledpost" 's/(- inbox: )/- Також createscheduledpost для другої.\n$1/'
l4 "MCP не підключено, а тег Metricool є → FAIL" 1 "connected" 's/«Status: ✔ Connected»/«Status: ✘ Needs authentication»/'
l4 "без рядка mcp → FAIL" 1 "немає рядка \`- mcp:\`" 's/- mcp: [^\n]*\n//'
# Числа — варіант A (рішення CEO 21.10): КОЖНЕ число з тегом; скрипт не вгадує, про що воно.
l4 "дата, час, id, пункти паспорта — не числа → PASS" 0 "" 's/(## Контент\n)/$1- Instagram-допис pact-001 стоїть на 2026-10-25 09:00 (паспорт п. 4b–4c, п. 5); W43, L4, tri-138, v0.11.0; strw-factory #33, strw-ops #28, andresiletsky-bit\/strw-state#237; з 2026-10-21 о 9:00; loops\/L4-growth.md; 2–3 [план] Reels.\n/'
l4 "число без тегу будь-де у звіті → FAIL" 1 "без тегу джерела" 's/(## Кампанії\n)/$1- Бюджет 50 \$.\n/'
l4 "те саме число з тегом [план] → PASS" 0 "" 's/(## Кампанії\n)/$1- Бюджет 50 [план] \$.\n/'
l4 "«2 Reels і 1 карусель» з тегом на кожне → PASS" 0 "" 's/(## Наступний тиждень\n)/$1- 2 [план] Reels і 1 [план] карусель.\n/'
l4 "один тег на два числа → FAIL" 1 "один тег — одне число" 's/(## Наступний тиждень\n)/$1- 2 Reels і 1 [план] карусель.\n/'
l4 "вигадане число перед тегом Metricool → FAIL (р.3 Q1)" 1 "один тег — одне число" 's/охоплення — 1 240 \[#1 IGRE11\]/перегляди 48 000, охоплення — 1 240 [#1 IGRE11]/'
l4 "число у вільному тексті trace → FAIL (р.3 P01)" 1 "trace рядок" 's/(- inbox: )/- Підсумок: TikTok — 48 000 переглядів за тиждень.\n$1/'
l4 "«Інста», «Bluesky», «Тік Ток» — назви не важливі, число без тегу → FAIL (р.3 P05–P09)" 1 "без тегу" 's/(## Контент\n)/$1- Інста: охоплення — 48 000; Bluesky: 900 показів.\n/'
l4 "«48000 хвилин» перегляду — без тегу → FAIL (р.3 P10)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: загальний час перегляду — 48000 хвилин.\n/'
l4 "таблиця з числом без тегу → FAIL (р.2 N3)" 1 "без тегу" 's/(## Контент\n)/$1| Мережа | Охоплення |\n|---|---|\n| TikTok | 48 000 |\n/'
l4 "«x48000» — не id, число → FAIL (р.2 N11)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: перегляди x48000.\n/'
l4 "число в бектиках — теж число → FAIL" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: `48000` переглядів.\n/'
l4 "«5k» без тегу — число → FAIL" 1 "без тегу" 's/(## Контент\n)/$1- Instagram: 5k нових переглядів.\n/'
l4 "«1,2k» з тегом Metricool → FAIL (р.3 N17)" 1 "зі скороченням біля тегу" 's/охоплення — 1 240 \[#1 IGRE11\]/охоплення — 1,2k [#1 IGRE11]/'
# Тег Metricool звіряється з викликом і відповіддю.
l4 "тег на поле невиміряного конектора → FAIL" 1 "не виміряно" 's/вподобання — 312 \[#1 IGRE10\]/вподобання — 312 [#1 IGPO02]/; s/"IGRE10", "IGRE08"\]/"IGRE10", "IGRE08", "IGPO02"]/; s/"IGRE10": 312,/"IGRE10": 312, "IGPO02": 312,/'
l4 "тег, значення не збігається з відповіддю → FAIL" 1 "≠ значенню" 's/вподобання — 312 \[#1 IGRE10\]/вподобання — 313 [#1 IGRE10]/'
l4 "тег на поле, якого немає в metrics виклику → FAIL" 1 "немає в \`metrics\`" 's/"metrics": \["IGRE11", "IGRE10", "IGRE08"\]/"metrics": ["IGRE11", "IGRE08"]/'
l4 "тег на виклик, що не аналітика → FAIL" 1 "не getAnalyticsDataByMetrics" 's/312 \[#1 IGRE10\]/312 [#2 IGRE10]/'
l4 "«%» біля тегу Metricool — одиницю не виміряно → FAIL (р.4 A13/A17)" 1 "з «%»" 's/engagement — 45,2 \[#1 IGRE08\]/engagement — 45,2% [#1 IGRE08]/'
l4 "45,3 при 45.23 → FAIL (округлення до показаних знаків)" 1 "≠ значенню" 's/engagement — 45,2 \[#1 IGRE08\]/engagement — 45,3 [#1 IGRE08]/'
l4 "45 при 45.23 → PASS (ціле — округлення)" 0 "" 's/engagement — 45,2 \[#1 IGRE08\]/engagement — 45 [#1 IGRE08]/'
l4 "45,3 при 45.25 → PASS (звичайне округлення half-up, р.4 L08)" 0 "" 's/engagement — 45,2 \[#1 IGRE08\]/engagement — 45,3 [#1 IGRE08]/; s/"IGRE08": 45.23/"IGRE08": 45.25/'
l4 "«1,240» — англійський роздільник тисяч → PASS (р.3 F17)" 0 "" 's/охоплення — 1 240 \[#1 IGRE11\]/охоплення — 1,240 [#1 IGRE11]/'
l4 "значення поля — денний ряд, не підсумок → FAIL (р.3 S6)" 1 "ряд" 's/"IGRE11": 1240,/"IGRE11": [1200, 40],/'
# Раунд 4: винятки «не число» — лише точні форми контракту; рядки trace — без хованок.
l4 "«x10» — не id → FAIL (р.4 A04)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: перегляди зросли x10 за тиждень.\n/'
l4 "«#3 у трендах» — не PR → FAIL (р.4 A05)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: ролик — #3 у трендах.\n/'
l4 "«- 48000. …» — не нумерація списку → FAIL (р.4 A06)" 1 "без тегу" 's/(## Контент\n)/$1- 48000. Стільки переглядів набрав TikTok-ролик.\n/'
l4 "«ER-4,5%» — не id → FAIL (р.4 A07)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: ER-4,5% за тиждень.\n/'
l4 "«2b показів» — не пункт → FAIL (р.4 A08)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: 2b показів хештегу.\n/'
l4 "дата не ISO без тегу → FAIL (контракт: дата — лише ISO)" 1 "без тегу" 's/(## Контент\n)/$1- Звіт за тиждень 14.10–20.10.\n/'
l4 "«н/д» з датою ISO виміру → PASS" 0 "" 's/недоступна на тарифі бренду\./недоступна на тарифі бренду (перевірено 2026-10-21)./'
l4 "текст після виводу в рядку mcp → FAIL (р.4 A01)" 1 "лише «- mcp:" 's/(«Status: ✔ Connected»)/$1 TikTok — 48 000 переглядів/'
l4 "число в хвості рядка reviewer → FAIL (р.4 A02)" 1 "без тегу" 's/(- reviewer: ceo\@strw.example — company-context.md, розділ «Рев.юер черги Metricool»)/$1; TikTok — 48 000 переглядів/'
l4 "число в хвості рядка стан → FAIL (р.4 A03)" 1 "без тегу" 's/(plannerUrl у відповіді виклику #6)/$1; TikTok — 48 000 переглядів/'
l4 "ключ аргументу поза схемою → FAIL (р.4 A14)" 1 "поза схемою" 's/(## Наступний тиждень\n)/$1/; s/(- inbox: )/- call: getBestTimeToPostByNetwork {"note": "TikTok 48000 views"}\n  > []\n$1/'
l4 "autoPublish \"true\" рядком у пості → FAIL (р.4 A15)" 1 "autoPublish: true" 's/  > \[\{"id": 503, "uuid": "u-501", /  > [{"id": 503, "uuid": "u-501", "autoPublish": "true", /'
l4 "значення поля — ряд об'єктів {date, value} → FAIL (р.4 M29)" 1 "ряд" 's/"IGRE11": 1240,/"IGRE11": [{"date": "20XX-NN-01", "value": 1240}],/'
# Раунд 5: закритий перелік «не чисел»; хованки у виводі mcp, відповіді й значеннях аргументів.
l4 "«0:45» — тривалість, не час → FAIL (р.5 T07)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: середній час перегляду — 0:45 на ролик.\n/'
l4 "«TikTok-48000» — не id → FAIL (р.5 B04)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok-48000 переглядів за тиждень.\n/'
l4 "«ER-45» — не id → FAIL (р.5 B05)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: ER-45 за тиждень.\n/'
l4 "«Top-3» — не id → FAIL (р.5 B03)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: ролик — Top-3 у трендах тижня.\n/'
l4 "«TikTok\/Reels #3» — не owner\/repo → FAIL (р.5 B06)" 1 "без тегу" 's/(## Контент\n)/$1- Ролик TikTok\/Reels #3 у трендах.\n/'
l4 "«for-you #3» — не репо → FAIL (р.5 B07)" 1 "без тегу" 's/(## Контент\n)/$1- Ролик у for-you #3 тижня.\n/'
l4 "«ролик #3 у трендах» — не виклик → FAIL (р.5 R22)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: ролик #3 у трендах.\n/'
l4 "«48. Стільки…» на початку рядка — не нумерація → FAIL (р.5 B19)" 1 "без тегу" 's/(## Контент\n)/$1\n48. Стільки тисяч переглядів зібрав TikTok-ролик.\n/'
l4 "«48.000.000» — не версія → FAIL (р.5 R20)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: 48.000.000 переглядів.\n/'
l4 "дата ISO в кінці речення → PASS (р.5 T04)" 0 "" 's/(## Контент\n)/$1- Звіт за тиждень до 2026-10-21.\n/'
l4 "час після «о» в кінці речення → PASS (р.5 T01)" 0 "" 's/(## Контент\n)/$1- Публікація в суботу о 09:00.\n/'
l4 "ISO з часом через T у кінці речення → PASS (р.5 T12)" 0 "" 's/(## Контент\n)/$1- Слот 2026-10-24T09:00:00+03:00.\n/'
l4 "«9:16» з тегом [не метрика] — один токен → PASS (р.5 T06)" 0 "" 's/(## Контент\n)/$1- Reels 9:16 [не метрика], вертикальний.\n/'
l4 "цифра у виводі mcp поза URL → FAIL (р.5 B08)" 1 "цифра поза URL" 's/«Status: ✔ Connected»/«Status: ✔ Connected; TikTok — 48 000 переглядів за тиждень»/'
l4 "відповідь не JSON і не помилка → FAIL (р.5 B09)" 1 "не JSON і не текст помилки" 's/(- inbox: )/- call: getBrandSettings\n  > TikTok — 48 000 переглядів за тиждень\n$1/'
l4 "відповідь — текст помилки сервера → PASS (live-check §1.2)" 0 "" 's/(- inbox: )/- call: getAnalyticsAvailableMetrics\n  > The result exceeds the maximum allowed size (~83328 tokens, limit: 25000).\n$1/'
l4 "значення socialNetwork поза переліком → FAIL (р.5 B10)" 1 "поза типом" 's/(- inbox: )/- call: getBestTimeToPostByNetwork {"socialNetwork": "TikTok — 48 000 переглядів за тиждень"}\n  > []\n$1/'
l4 "дата аргументу не ISO → FAIL" 1 "поза типом" 's/"from": "2026-09-23T00:00:00\+03:00"/"from": "23.09.2026"/'
l4 "«%» після тегу Metricool → FAIL (р.5 B11)" 1 "одиниця після тегу" 's/engagement — 45,2 \[#1 IGRE08\]/engagement — 45,2 [#1 IGRE08]%/'
l4 "«відсотка» між числом і тегом → FAIL (р.5 B12)" 1 "тег Metricool стоїть одразу після числа" 's/engagement — 45,2 \[#1 IGRE08\]/engagement — 45,2 відсотка [#1 IGRE08]/'
l4 "поле — у ряді рядків по днях → FAIL (р.5 B13)" 1 "ряд" 's/  > \{"IGRE11": 1240, /  > {"series": [{"date": "d1", "IGRE11": 48000}, {"date": "d2", "IGRE11": 1240}], /'
l4 "status числом при «не встановлено» → FAIL (р.5 B14)" 1 "поле є" 's/  > \[\{"id": 503, "uuid": "u-501", /  > [{"id": 503, "uuid": "u-501", "status": 2, /'
l4 "status об'єктом при «не встановлено» → FAIL (р.5 B15)" 1 "поле є" 's/  > \[\{"id": 503, "uuid": "u-501", /  > [{"id": 503, "uuid": "u-501", "status": {"name": "SCHEDULED"}, /'
l4 "autoPublish: 1 у пості → FAIL (р.5 B16)" 1 "autoPublish: true" 's/  > \[\{"id": 503, "uuid": "u-501", /  > [{"id": 503, "uuid": "u-501", "autoPublish": 1, /'
l4 "autoPublish: null у пості — не явне «ні» → FAIL" 1 "autoPublish: true" 's/  > \[\{"id": 503, "uuid": "u-501", /  > [{"id": 503, "uuid": "u-501", "autoPublish": null, /'
l4 "«T3» — не L\/G\/W\/M-позначка → FAIL" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: ролик T3 у трендах.\n/'
l4 "autoPublish в обгортці поста → FAIL (р.5 B17)" 1 "autoPublish: true" 's/  > \[\{"id": 503, "uuid": "u-501", "text": "([^"]+)"\}\]/  > [{"post": {"id": 503, "uuid": "u-501", "text": "$1"}, "autoPublish": true}]/'
l4 "картка згадує «strw-ops #6», не виклик → FAIL (р.5 B21)" 1 "не pending review" 's/стан: поле стану не встановлено — доказ «на затвердження» — plannerUrl у відповіді виклику #6/стан: scheduled/; s/- inbox: tri-NNN — TikTok/- inbox: tri-NNN — strw-ops #6; TikTok/'
l4 "відповідь запису в {\"data\": …} → PASS (р.5 K01)" 0 "" 's/  > \{"id": 503, "uuid": "u-501", "plannerUrl": "([^"]+)"\}/  > {"data": {"id": 503, "uuid": "u-501", "plannerUrl": "$1"}}/'
l4 "getScheduledPosts у {\"data\": […]} → PASS (live-check §1.3)" 0 "" 's/  > (\[\{"id": 503[^\n]*\])/  > {"data": $1}/'
l4 "create-scheduled-post з дефісами в звіті → FAIL (р.5 B18)" 1 "createscheduledpost" 's/(## Контент\n)/$1- Одну чернетку виставив через create-scheduled-post напряму.\n/'
# Раунд 6: час лише після «о/об»; закритий перелік звужено; одиниці в реченні; пост після помилки.
l4 "«до 00:45» — тривалість → FAIL (р.6 N01)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: середній час перегляду зріс до 00:45.\n/'
l4 "«з 00:30 до 00:45» → FAIL (р.6 N02)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: середній перегляд — з 00:30 до 00:45 за тиждень.\n/'
l4 "«перегляд 00:45» без прийменника → FAIL (р.6 M01)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: перегляд 00:45.\n/'
l4 "«о 9:00» — час → PASS (р.6 F01, M20)" 0 "" 's/(## Контент\n)/$1- Публікація о 9:00.\n/'
l4 "«о 48:00» — не година → FAIL" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: перегляди о 48:00.\n/'
l4 "«п. 48» — не пункт паспорта → FAIL (р.6 N20)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: п. 48 у рейтингу wellness.\n/'
l4 "«виклик #2» у звіті, хоч виклик #2 існує → FAIL" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: наш виклик #2 тижня.\n/'
l4 "«виклик #2» у вільному тексті trace (не inbox) → FAIL" 1 "без тегу" 's/(- inbox: )/- Підсумок: наш виклик #2 тижня.\n$1/'
l4 "«top-100» — не id реєстру → FAIL (р.6 N04)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: ролик увійшов у top-100 трендів тижня.\n/'
l4 "«наш виклик #1 у трендах» у звіті — не посилання на виклик → FAIL (р.6 N05)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: наш виклик #1 у трендах тижня.\n/'
l4 "«виклик #9» в inbox — такого виклику немає → FAIL" 1 "без тегу" 's/- inbox: tri-NNN — TikTok/- inbox: tri-NNN — виклик #9; TikTok/'
l4 "«PR #1 тижня» без репо → FAIL (р.6 N08)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: PR #1 тижня серед wellness-брендів.\n/'
l4 "«M48» → FAIL (р.6 N17)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: M48 переглядів.\n/'
l4 "«§48000» → FAIL (р.6 N19)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: §48000 переглядів.\n/'
l4 "«4800-00-00» — не дата → FAIL (р.6 N07)" 1 "без тегу" 's/(## Контент\n)/$1- TikTok: 4800-00-00 переглядів.\n/'
l4 "«ER, %:» у реченні з тегом Metricool → FAIL (р.6 N09)" 1 "у реченні з тегом Metricool" 's/engagement — 45,2 \[#1 IGRE08\] взаємодії на тисячу охоплених/ER, %: 45,2 [#1 IGRE08]/'
l4 "«(у відсотках)» після тегу Metricool → FAIL (р.6 N10)" 1 "у реченні з тегом Metricool" 's/engagement — 45,2 \[#1 IGRE08\] взаємодії на тисячу охоплених/engagement — 45,2 [#1 IGRE08] (у відсотках)/'
l4 "«48,000» при значенні 48 — лише тисячі → FAIL (р.6 N16)" 1 "≠ значенню" 's/охоплення — 1 240 \[#1 IGRE11\]/охоплення — 1,240 [#1 IGRE11]/; s/"IGRE11": 1240,/"IGRE11": 1.24,/'
l4 "текст «помилки» з «(limit)» — не помилка → FAIL (р.6 N12b)" 1 "не JSON і не текст помилки" 's/(- inbox: )/- call: getBrandSettings\n  > TikTok — переглядів за тиждень (limit)\n$1/'
l4 "createScheduledPost прозою в рядку стан → FAIL (р.6 S05)" 1 "createscheduledpost" 's/(plannerUrl у відповіді виклику #6)/$1; виставлено через createScheduledPost напряму/'
l4 "createScheduledPost у відповіді → FAIL (р.6 S04)" 1 "createscheduledpost" 's/(- inbox: )/- call: getBrandSettings\n  > {"note": "createScheduledPost done"}\n$1/'
l4 "send після правки — інший пост → FAIL (р.6 S02)" 1 "правку не перенадіслано" 's/(- call: sendScheduledPostForReview \{"id": )502, "uuid": "u-501"/${1}999, "uuid": "u-999"/'
l4 "помилка ForReview без id, але пост із тим текстом і autoPublish true у черзі → FAIL (р.6 S01)" 1 "Metricool опублікує сам" "$ERR; $CARD2; $STOP; s/  > \[\{\"id\": 501, \"uuid\": \"u-501\", \"text\": \"Як не зірвати звичку на вихідних\"\}\]/  > [{\"id\": 777, \"uuid\": \"u-777\", \"text\": \"Як не зірвати звичку на вихідних\", \"autoPublish\": true}]/"
l4 "поле двічі без дати — ряд → FAIL (р.6 M07)" 1 "ряд" 's/  > \{"IGRE11": 1240, /  > {"a": {"IGRE11": 1240}, "b": {"IGRE11": 1240}, /'
l4 "одне входження поля поруч із date — ряд → FAIL (р.6 M18)" 1 "ряд" 's/  > \{"IGRE11": 1240, /  > {"day1": {"date": "2026-10-20", "IGRE11": 1240}, /'
l4 "два пости з одним uuid у {\"data\": […]} → FAIL (р.6 M24)" 1 "постів із" 's/  > (\[\{"id": 503, "uuid": "u-501", "text": "[^"]+"\})\]/  > {"data": $1, {"id": 504, "uuid": "u-501", "status": "SCHEDULED"}]}/'
# Межа рівня 0 (рішення CEO: мережу рядка не вгадувати): тег поля Instagram у рядку
# TikTok звіряє LLM-чекер (brand-reviewer, п. 5), не скрипт. Пін на те, що межа ця, а не інша.
l4 "межа: тег Instagram у рядку TikTok — рівень 0 мережу рядка не звіряє → PASS" 0 "" 's/(## Контент\n)/$1- TikTok: перегляди — 1 240 [#1 IGRE11].\n/'
# Передумова 4a: лише рядок `- Andrii:` розділу «Рев'юер черги Metricool» (р.2 E2, р.3 Q2).
cc_case() { # cc_case <назва> <rc> <що дописати в company-context> <email у trace>
  printf '%b' "$3" | cat "$STRW_COMPANY_CONTEXT" - > "$TMP/cc-x.md"
  cp "$LG" "$TMP/ccx.md"; perl -pi -e "s/ceo\\@strw.example/$4/g" "$TMP/ccx.md"
  [ "$4" = 'ceo\@strw.example' ] || ! cmp -s "$LG" "$TMP/ccx.md" || { bad "$1: правка email не наклалась"; return; }
  out="$(STRW_COMPANY_CONTEXT="$TMP/cc-x.md" bash "$V" l4-trace "$TMP/ccx.md" 2>&1)"; rc=$?
  if [ "$rc" -eq "$2" ] && { [ "$2" -eq 0 ] || printf '%s' "$out" | grep -q 'не email Andrii'; }; then ok "$1"; else bad "$1: rc=$rc" "$out"; fi
}
cc_case "email з іншого розділу («погоджено з Andrii») → FAIL (р.2 E2)" 1 '\n## Підрядники\n- SMM-підрядник (погоджено з Andrii): smm@agency.example\n' 'smm\@agency.example'
cc_case "«- Andrii: …» поза розділом рев'юера → FAIL" 1 '\n## Контакти\n- Andrii: andrii.personal@strw.example\n' 'andrii.personal\@strw.example'
cc_case "інший рядок у розділі рев'юера (резерв-підрядник) → FAIL (р.3 Q2)" 1 '- Резерв (SMM-підрядник): smm@agency.example\n' 'smm\@agency.example'
cc_case "контроль-близнюк: той самий company-context, email Andrii → PASS" 0 '\n## Підрядники\n- SMM-підрядник (погоджено з Andrii): smm@agency.example\n' 'ceo\@strw.example'

# Негативний контроль: мутація правила autoPublish у копії python-скрипта робить
# фікстуру «autoPublish: true» зеленою — випадки вище міряють скрипт, а не себе.
MD="$TMP/l4mut"; mkdir -p "$MD"; cp "$V" "$MD/validate-artifact.sh"; cp "$HERE/validate-l4-trace.py" "$MD/"
perl -pi -e 's/info\.get\("autoPublish"\) is not False/False/' "$MD/validate-l4-trace.py"
if grep -q 'info.get("autoPublish") is not False' "$MD/validate-l4-trace.py"; then
  bad "мутація правила autoPublish не наклалась — контроль нічого не доводить"
else
  cp "$LG" "$TMP/l4ap.md"; perl -0pi -e 's/"autoPublish": false\}\}\n  > \{"id": 502/"autoPublish": true}}\n  > {"id": 502/' "$TMP/l4ap.md"
  if bash "$MD/validate-artifact.sh" l4-trace "$TMP/l4ap.md" >/dev/null 2>&1 && ! bash "$V" l4-trace "$TMP/l4ap.md" >/dev/null 2>&1; then
    ok "контроль: без правила autoPublish «autoPublish: true» проходить, з правилом — ні"
  else
    bad "контроль autoPublish: мутований і живий скрипти не розходяться"
  fi
fi
echo
echo "Разом: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
