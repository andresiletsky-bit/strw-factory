#!/usr/bin/env bash
# validate-artifact.sh — детермінована перевірка обов'язкових секцій артефакту.
# Рівень 0 checker-фази (loop-passport §4): структуру перевіряє скрипт, зміст — LLM.
# Usage: validate-artifact.sh <type> <file>
# Types: idea-card | validation-report | prd | design-delta | regression-report | build-report | launch-checklist | growth-report | portfolio-brief | retro-note | persona-card
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
while IFS= read -r line_no; do
  header=$(sed -n "${line_no}p" "$FILE")
  hashes="${header%% *}"; level=${#hashes}
  next=$(awk -v n="$line_no" 'NR>n && NF {print; exit}' "$FILE")
  if [[ -z "$next" ]]; then
    EMPTY+=("${header#\#\# }")
  elif [[ "$next" =~ ^(#{1,6})[[:space:]] ]]; then
    nlevel=${#BASH_REMATCH[1]}
    (( nlevel <= level )) && EMPTY+=("${header#\#\# }")
  fi
done < <(grep -nE '^#{2,3} ' "$FILE" | cut -d: -f1)

if [[ ${#MISSING[@]} -eq 0 && ${#EMPTY[@]} -eq 0 ]]; then
  echo "PASS: $TYPE structure OK ($FILE)"
  exit 0
fi
echo "FAIL: $TYPE ($FILE)"
[[ ${#MISSING[@]} -gt 0 ]] && printf '  missing section: %s\n' "${MISSING[@]}"
[[ ${#EMPTY[@]} -gt 0 ]]   && printf '  empty section: %s\n'   "${EMPTY[@]}"
exit 1
