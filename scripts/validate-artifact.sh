#!/usr/bin/env bash
# validate-artifact.sh — детермінована перевірка обов'язкових секцій артефакту.
# Рівень 0 checker-фази (loop-passport §4): структуру перевіряє скрипт, зміст — LLM.
# Usage: validate-artifact.sh <type> <file>
# Types: idea-card | validation-report | prd | build-report | launch-checklist | growth-report | portfolio-brief
set -euo pipefail

usage() { echo "Usage: $0 <type> <file>" >&2; exit 2; }
[[ $# -eq 2 ]] || usage
TYPE="$1"; FILE="$2"
[[ -f "$FILE" ]] || { echo "FAIL: file not found: $FILE"; exit 1; }

# Канонічні секції за artifact-contracts.md (заголовки '## …')
case "$TYPE" in
  idea-card)         REQUIRED=("Проблема" "Сигнали попиту" "Тип" "Гіпотеза монетизації" "Чому ми" "ICE");;
  validation-report) REQUIRED=("TAM/SAM/SOM" "Конкуренти" "Попит" "Ризики" "Найдешевша перевірка" "ICE" "Рекомендація" "Critic-review");;
  prd)               REQUIRED=("Проблема і цілі" "Метрики успіху" "Scope MVP" "НЕ-цілі" "User stories" "Залежності" "Tracking" "Оцінка обсягу");;
  build-report)      REQUIRED=("Реалізовано vs PRD" "Тести" "Security" "Tracking" "Обмеження" "Deploy-checklist" "Code-review");;
  launch-checklist)  REQUIRED=("Тести" "Аналітика" "Security" "Rollback" "Сторінка продукту" "Ціни");;
  growth-report)     REQUIRED=("Кампанії" "Метрики" "Контент" "Наступний тиждень");;
  portfolio-brief)   REQUIRED=("Продукти" "Метрики фабрики" "Фокуси" "KILL" "Чекає рішення");;
  *) echo "FAIL: unknown type '$TYPE'" >&2; exit 2;;
esac

MISSING=()
for section in "${REQUIRED[@]}"; do
  # секція = заголовок будь-якого рівня (##/###), що МІСТИТЬ канонічну назву
  grep -qiE "^#{2,3} .*${section}" "$FILE" || MISSING+=("$section")
done

# Порожні секції: заголовок, за яким одразу наступний заголовок або EOF
EMPTY=()
while IFS= read -r line_no; do
  header=$(sed -n "${line_no}p" "$FILE")
  next=$(awk -v n="$line_no" 'NR>n && NF {print; exit}' "$FILE")
  [[ "$next" =~ ^#{1,3}\  || -z "$next" ]] && EMPTY+=("${header#\#\# }")
done < <(grep -nE '^#{2,3} ' "$FILE" | cut -d: -f1)

if [[ ${#MISSING[@]} -eq 0 && ${#EMPTY[@]} -eq 0 ]]; then
  echo "PASS: $TYPE structure OK ($FILE)"
  exit 0
fi
echo "FAIL: $TYPE ($FILE)"
[[ ${#MISSING[@]} -gt 0 ]] && printf '  missing section: %s\n' "${MISSING[@]}"
[[ ${#EMPTY[@]} -gt 0 ]]   && printf '  empty section: %s\n'   "${EMPTY[@]}"
exit 1
