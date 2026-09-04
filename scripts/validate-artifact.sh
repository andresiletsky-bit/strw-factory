#!/usr/bin/env bash
# validate-artifact.sh — детермінована перевірка обов'язкових секцій артефакту.
# Рівень 0 checker-фази (loop-passport §4): структуру перевіряє скрипт, зміст — LLM.
# Usage: validate-artifact.sh <type> <file>
# Types: idea-card | validation-report | prd | design-delta | regression-report | build-report | launch-checklist | growth-report | portfolio-brief | retro-note | persona-card | copy-guide | design-research | design-options | checker-verdict
set -euo pipefail

usage() { echo "Usage: $0 <type> <file>" >&2; exit 2; }
[[ $# -eq 2 ]] || usage
TYPE="$1"; FILE="$2"
[[ -f "$FILE" ]] || { echo "FAIL: file not found: $FILE"; exit 1; }

# persona-card: перевірки по YAML-блоках (```yaml … ```), не по заголовках —
# контракт у artifact-contracts.md, схема — концепт Persona Layer розд. 3.
if [[ "$TYPE" == "persona-card" ]]; then
  ERRORS=()
  CARDS=$(awk '/^```yaml/{n++} END{print n+0}' "$FILE")
  [[ "$CARDS" -ge 3 && "$CARDS" -le 5 ]] || ERRORS+=("cards: $CARDS карт (контракт: 3–5 на продукт)")

  for ((i=1; i<=CARDS; i++)); do
    BLOCK=$(awk -v k="$i" '/^```yaml/{n++; if(n==k){f=1; next}} /^```$/{if(f) exit} f' "$FILE")
    for key in persona_id archetype status weight weight_source demographics context behavior \
               unexpected_trait anti_persona tracking_binding open_assumptions; do
      grep -qE "^${key}:" <<<"$BLOCK" || ERRORS+=("card $i: відсутнє поле '$key'")
    done
    CTX=$(awk '/^context:/{f=1; next} /^[a-z_]/{if(f) exit} f' <<<"$BLOCK")
    grep -q '\[E\]' <<<"$CTX" || ERRORS+=("card $i: у context немає жодного [E]-джерела")
    if grep -qE '^unexpected_trait:' <<<"$BLOCK"; then
      grep -E '^unexpected_trait:' <<<"$BLOCK" | grep -q '\[E\]' \
        || ERRORS+=("card $i: unexpected_trait без тегу [E] (анти-каррикатура вимагає реального джерела)")
    fi
    grep -qE '^anti_persona:[[:space:]]*[^[:space:]]' <<<"$BLOCK" \
      || ERRORS+=("card $i: anti_persona порожнє")
  done

  YAML_ALL=$(awk '/^```yaml/{f=1; next} /^```$/{f=0} f' "$FILE")
  read -r NA NE NI <<<"$(awk '{a+=gsub(/\[A\]/,""); e+=gsub(/\[E\]/,""); i+=gsub(/\[I\]/,"")} \
    END{print a+0, e+0, i+0}' <<<"$YAML_ALL")"
  TAGS=$((NA + NE + NI))
  if [[ "$TAGS" -eq 0 ]]; then
    ERRORS+=("жодного тегу [E]/[I]/[A] у YAML-блоках — атрибути без походження")
  elif [[ $((NA * 2)) -gt "$TAGS" ]]; then
    ERRORS+=("[A]-частка ${NA}/${TAGS} тегів >50% — це фантазія, не персони (P1)")
  fi

  # PII (P7): email · телефон · повне ім'я — персона є агрегатом, не профілем людини
  if grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' <<<"$YAML_ALL"; then
    ERRORS+=("PII: email-патерн у YAML")
  fi
  if grep -qE '\+[0-9][0-9 ()-]{8,}|[0-9]{3}[-. ][0-9]{3}[-. ][0-9]{4}' <<<"$YAML_ALL"; then
    ERRORS+=("PII: телефонний патерн у YAML")
  fi
  if grep -qE "^[[:space:]]*(full_?name|first_name|last_name|real_name):" <<<"$YAML_ALL" \
     || grep -qE "^[[:space:]]*[a-z_]*name:[[:space:]]*[\"']?[А-ЯІЇЄҐA-Z][а-яіїєґa-z]+[[:space:]]+[А-ЯІЇЄҐA-Z]" <<<"$YAML_ALL"; then
    ERRORS+=("PII: патерн повного імені у YAML")
  fi

  if [[ ${#ERRORS[@]} -eq 0 ]]; then
    echo "PASS: persona-card structure OK ($FILE, $CARDS карт, [A] ${NA}/${TAGS} тегів)"
    exit 0
  fi
  echo "FAIL: persona-card ($FILE)"
  printf '  %s\n' "${ERRORS[@]}"
  exit 1
fi

# Канонічні секції за artifact-contracts.md (заголовки '## …')
case "$TYPE" in
  idea-card)         REQUIRED=("Проблема" "Сигнали попиту" "Тип" "Гіпотеза монетизації" "Чому ми" "ICE");;
  validation-report) REQUIRED=("TAM/SAM/SOM" "Конкуренти" "Попит" "Ризики" "Найдешевша перевірка" "ICE" "Рекомендація" "Critic-review" "Не встановлено");;
  prd)               REQUIRED=("Проблема і цілі" "Метрики успіху" "Scope MVP" "НЕ-цілі" "User stories" "Залежності" "Tracking" "Оцінка обсягу");;
  design-delta)      REQUIRED=("Змінені одиниці" "Спільні причини" "Непояснене" "Нечитані джерела" "Не встановлено");;
  regression-report) REQUIRED=("Фаза 1" "Фаза 2" "Фаза 3" "Що лишила кожна червона" "Не встановлено");;
  build-report)      REQUIRED=("Реалізовано vs PRD" "Тести" "Security" "Tracking" "Обмеження" "Deploy-checklist" "Code-review");;
  launch-checklist)  REQUIRED=("Тести" "Аналітика" "Security" "Rollback" "Сторінка продукту" "Ціни");;
  growth-report)     REQUIRED=("Кампанії" "Метрики" "Контент" "Наступний тиждень");;
  portfolio-brief)   REQUIRED=("Продукти" "Метрики фабрики" "Фокуси" "KILL" "Чекає рішення" "Не встановлено");;
  retro-note)        REQUIRED=("Що спрацювало" "Патерни" "Health flags" "Пропозиції" "Не встановлено");;
  # Три типи заведено 2026-08-24 (рішення CEO: якість дизайну і текстів).
  # copy-guide: секції 0–7 + машинний блок rules — його наявність тут теж
  # примушується, бо гайд без блоку лінтер відкидає (rc=2), і артефакт,
  # що пройшов рівень 0 без блоку, був би валідним гайдом-нездарою.
  copy-guide)        REQUIRED=("Що виміряно" "Звертання" "Тон" "Словник" "Шаблони" "Чорний список" "Мови" "Не встановлено");;
  design-research)   REQUIRED=("Задача і контекст" "Як це розв'язують інші" "Що беремо" "Що свідомо відкидаємо" "Ризики вибору" "Не встановлено");;
  design-options)    REQUIRED=("Варіанти" "Критерії порівняння" "Обраний і чому" "Програшний і чому збережений" "Не встановлено");;
  # checker-verdict: єдиний формат вердикту всіх чекерів (references/review-policy.md,
  # заведено 2026-09-04 за П1.3 аудиту). Секцій мало навмисно — цінність не в
  # заголовках, а в трьох машинних перевірках нижче (VERDICT, severity, стеля Nit).
  checker-verdict)   REQUIRED=("Проходи" "Знахідки" "Детермінована дія" "Не перевірено");;
  *) echo "FAIL: unknown type '$TYPE'" >&2; exit 2;;
esac

MISSING=()
for section in "${REQUIRED[@]}"; do
  # секція = заголовок будь-якого рівня (##/###), що МІСТИТЬ канонічну назву
  grep -qiE "^#{2,3} .*${section}" "$FILE" || MISSING+=("$section")
done

# Порожні секції: заголовок, за яким одразу заголовок ТОГО Ж або вищого рівня, або EOF.
# Глибший заголовок (## → ###) — це вміст секції, не порожнеча: retro-note тримає
# патерни й пропозиції саме підсекціями (латентний баг, спійманий golden'ом 15.08).
EMPTY=()
# Не `done < <(grep … | cut …)`: підстановка процесу ковтає код виходу producer'а
# (форма procsub-loop-input, strw-state/scripts/lib/nonportable-forms.tsv; pact-ios #167).
# grep=1 — «заголовків немає», це легально; >1 — файл не прочитано, і це FAIL,
# а не «порожніх розділів немає».
# Один файл із mktemp (повний шаблон — і BSD, і GNU; код виходу перевірено),
# trap прибирає його на будь-якому виході. Редирект — у цей самий файл, не в
# похідне ім'я: провал відкриття тут гучний (код 2), а не «grep=1 = порожньо».
# Без другого ступеня (cut): номер рядка ріжеться в bash із того ж запису.
_hdr="$(mktemp "${TMPDIR:-/tmp}/validate-artifact-hdr.XXXXXX")" || { echo "FAIL: mktemp не дав файлу"; exit 2; }
trap 'rm -f "$_hdr"' EXIT
if ! : > "$_hdr"; then echo "FAIL: не відкрити $_hdr для запису"; exit 2; fi
grep -nE '^#{2,3} ' "$FILE" > "$_hdr"; _grc=$?
[[ $_grc -le 1 ]] || { echo "FAIL: grep не прочитав $FILE (код $_grc)"; exit 2; }
while IFS= read -r _rec; do
  line_no="${_rec%%:*}"; header="${_rec#*:}"
  hashes="${header%% *}"; level=${#hashes}
  next=$(awk -v n="$line_no" 'NR>n && NF {print; exit}' "$FILE")
  if [[ -z "$next" ]]; then
    EMPTY+=("${header#\#\# }")
  elif [[ "$next" =~ ^(#{1,6})[[:space:]] ]]; then
    nlevel=${#BASH_REMATCH[1]}
    (( nlevel <= level )) && EMPTY+=("${header#\#\# }")
  fi
done < "$_hdr"

# copy-guide без машинного блоку — гайд-нездара: проза є, гейта немає.
# Перевіряється ІМЕННО ключ rules усередині yaml-блоку, не сам блок: гайд із
# ```yaml без rules пройшов би на самому факті трьох бектиків.
if [[ "$TYPE" == "copy-guide" ]]; then
  awk '/^```yaml/{f=1; next} /^```$/{f=0} f' "$FILE" | grep -qE '^rules:' \
    || MISSING+=("машинний блок \`\`\`yaml з ключем rules:")
fi

# checker-verdict: три перевірки, яких заголовок не робить. Вони тут, а не в
# рубриці, бо кожна детермінована — і саме через їхню відсутність F8 аудиту
# нарахував чотири різні шкали в п'яти чекерів.
EXTRA=()
if [[ "$TYPE" == "checker-verdict" ]]; then
  # (а) рядок вердикту. «Перший рядок» — перший рядок САМОГО вердикту, тож
  # преамбула golden'а (заголовок + цитата) легальна, а от вердикт, схований
  # після першої секції, — ні: читач бачить знахідки раніше за присуд.
  # `|| true` обов'язкові: під `set -e` + `pipefail` пайп, де grep нічого не
  # знайшов, завалює САМЕ ПРИСВОЄННЯ — і скрипт мовчки виходить кодом 1 без
  # жодного рядка діагностики. Тобто «немає VERDICT» і «скрипт помер» стали б
  # невідрізненні. Знайдено власним тестом (§6), не оком.
  VLINE="$(grep -nE '^VERDICT:[[:space:]]*(PASS|PASS-WITH-NOTES|FAIL)[[:space:]]*$' "$FILE" | head -1 | cut -d: -f1 || true)"
  FIRSTH="$(grep -nE '^#{2,3} ' "$FILE" | head -1 | cut -d: -f1 || true)"
  if [[ -z "$VLINE" ]]; then
    EXTRA+=("немає рядка 'VERDICT: PASS|PASS-WITH-NOTES|FAIL'")
  elif [[ -n "$FIRSTH" && "$VLINE" -gt "$FIRSTH" ]]; then
    EXTRA+=("рядок VERDICT стоїть після першої секції (рядок $VLINE проти $FIRSTH)")
  fi

  # (б) severity на КОЖНІЙ знахідці. Знахідка без severity — це і є та сама
  # «шкала на око», яку політика скасовує.
  FINDINGS="$(awk '/^#{2,3} .*Знахідки/{f=1; next} /^#{2,3} /{f=0} f' "$FILE")"
  NOSEV="$(grep -cE '^- ' <<<"$FINDINGS" || true)"
  WITHSEV="$(grep -cE '^- \[(Blocker|Important|Nit)\]' <<<"$FINDINGS" || true)"
  if [[ "${NOSEV:-0}" -ne "${WITHSEV:-0}" ]]; then
    EXTRA+=("знахідок без severity: $((NOSEV - WITHSEV)) (формат: '- [Blocker|Important|Nit] файл:рядок — …')")
  fi

  # (в) стеля дрібниць. 5 — з політики; решта подається числом, не списком.
  NITS="$(grep -cE '^- \[Nit\]' <<<"$FINDINGS" || true)"
  if [[ "${NITS:-0}" -gt 5 ]]; then
    EXTRA+=("Nit-знахідок ${NITS} при стелі 5 — решта подається числом (review-policy.md)")
  fi
fi

if [[ ${#MISSING[@]} -eq 0 && ${#EMPTY[@]} -eq 0 && ${#EXTRA[@]} -eq 0 ]]; then
  echo "PASS: $TYPE structure OK ($FILE)"
  exit 0
fi
echo "FAIL: $TYPE ($FILE)"
[[ ${#MISSING[@]} -gt 0 ]] && printf '  missing section: %s\n' "${MISSING[@]}"
[[ ${#EMPTY[@]} -gt 0 ]]   && printf '  empty section: %s\n'   "${EMPTY[@]}"
[[ ${#EXTRA[@]} -gt 0 ]]   && printf '  %s\n'                   "${EXTRA[@]}"
exit 1
