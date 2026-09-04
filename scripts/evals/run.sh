#!/usr/bin/env bash
# run.sh — evals-раннер для агентів фабрики (П1.2 аудиту 2026-09-03, F7/F10/F21).
#
# ЧОМУ ВІН Є. Правило «регресія на golden перед bump» було записане в чотирьох
# файлах і не мало жодного виконавця: promпт агента, скіл чи паспорт мінялись і
# випускались без перевірки поведінки. «Сіді-кейси» жили прозою в кінці golden'а
# — тобто описом дефекту, який ніхто не міг прогнати. Тут вони стають файлами.
#
# Usage: scripts/evals/run.sh [--offline] [--type <artifact-type>] [--no-results]
#
#   --offline      лише рівень 0 (детермінований). Типовий режим pre-commit і release.sh.
#   --type <t>     обмежити прогін одним типом артефакту.
#   --no-results   не писати references/evals/results/ (для гейтів: хук не має
#                  бруднити дерево, яке сам же перевіряє).
#
# Онлайн-режим вмикається змінною STRW_EVALS_ONLINE=1 (і НЕ вмикається прапорцем:
# платний виклик не має вмикатись одруком у команді).
#
# Коди виходу: 0 — зелено · 1 — червоно · 2 — набір порожній або помилка виклику.
# Порожній набір це ПОМИЛКА, не успіх: раннер, що нічого не знайшов, звітував би
# «0 падінь» — рівно клас «зелено, бо не рахує» (docs/testing.md).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVALS_DIR="${STRW_EVALS_DIR:-$REPO/references/evals}"
VALIDATOR="${STRW_VALIDATE_ARTIFACT:-$REPO/scripts/validate-artifact.sh}"
RESULTS_DIR="${STRW_EVALS_RESULTS_DIR:-$EVALS_DIR/results}"
STATE_REPO="${STATE_REPO:-$HOME/Developer/STRW/strw-state}"
LANES="$STATE_REPO/engine/lanes.yaml"

OFFLINE="false"; TYPE_FILTER=""; WRITE_RESULTS="true"
while [ $# -gt 0 ]; do
  case "$1" in
    --offline)     OFFLINE="true"; shift ;;
    --type)        TYPE_FILTER="${2:-}"; [ -n "$TYPE_FILTER" ] || { echo "run.sh: --type без значення" >&2; exit 2; }; shift 2 ;;
    --no-results)  WRITE_RESULTS="false"; shift ;;
    -h|--help)     sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "run.sh: невідомий аргумент '$1'" >&2; exit 2 ;;
  esac
done
[ "${STRW_EVALS_ONLINE:-0}" = "1" ] || OFFLINE="true"

[ -x "$VALIDATOR" ] || [ -f "$VALIDATOR" ] || { echo "run.sh: немає валідатора $VALIDATOR" >&2; exit 2; }
[ -d "$EVALS_DIR/golden" ] || { echo "run.sh: немає теки golden у $EVALS_DIR" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ROWS="$TMP/rows"; : > "$ROWS"
PASS=0; FAIL=0; SKIP=0

# ── допоміжне ───────────────────────────────────────────────────────────────
fm() { # fm <файл> <ключ> — значення поля frontmatter (перший блок ---…---)
  awk -v k="$2" 'NR==1&&/^---$/{f=1;next} f&&/^---$/{exit}
                 f&&index($0,k": ")==1{print substr($0,length(k)+3)}' "$1"
}
body() { # body <файл> <куди> — артефакт без frontmatter; валідується саме тіло
  awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{f=0;next} !f' "$1" > "$2"
}
say() { printf '%s\n' "$*"; }
esc() { printf '%s' "$1" | tr '\n\t' '  ' | sed 's/\\/\\\\/g; s/"/'"'"'/g'; }
row() { # row <kind> <type> <case> <level> <expect> <got> <ok> <detail>
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$(esc "$8")" >> "$ROWS"
}
green() { PASS=$((PASS+1)); say "PASS · $1"; }
red()   { FAIL=$((FAIL+1)); say "FAIL · $1"; }

# Тип артефакту → петля, чия роль checker його оцінює. Мапа тут, а не в
# lanes.yaml: lanes.yaml — джерело про МОДЕЛІ ролей, а «який тип чий» —
# властивість контрактів артефактів, і дублювати її в чужий файл не можна.
loop_of() {
  case "$1" in
    idea-card)                      echo "L1-discovery" ;;
    validation-report|persona-card|prd) echo "L2-validation" ;;
    build-report|checker-verdict|launch-checklist) echo "L3-build" ;;
    growth-report)                  echo "L4-growth" ;;
    portfolio-brief)                echo "L5-portfolio" ;;
    retro-note)                     echo "L6-retro" ;;
    design-delta|design-research|design-options|copy-guide) echo "L7-design" ;;
    regression-report)              echo "L8-regression" ;;
    *)                              echo "" ;;
  esac
}

# Модель чекера петлі з lanes.yaml (єдине джерело, strw-state — читається живим).
# Петля без агента-чекера (L5 — субагентський прохід, L6 — людина) моделі не
# має; тоді береться STRW_EVALS_MODEL або opus, і це названо в звіті, а не
# сховане: «модель за замовчуванням» мовчки — те саме, що невідома модель.
checker_model() {
  local loop="$1" m=""
  if [ -n "$loop" ] && [ -f "$LANES" ]; then
    m="$(awk -v l="  $loop:" '
      $0==l {inloop=1; next}
      inloop && /^  [A-Za-z]/ {exit}
      inloop && /^    checker:/ {
        if (match($0, /model: [A-Za-z0-9._-]+/)) print substr($0, RSTART+7, RLENGTH-7)
        exit
      }' "$LANES")"
  fi
  case "$m" in ""|null) m="${STRW_EVALS_MODEL:-opus}" ;; esac
  printf '%s' "$m"
}

# ── рівень 0 ────────────────────────────────────────────────────────────────
level0() { # level0 <type> <файл-тіла> → 0 PASS / 1 FAIL / 2 помилка виклику
  bash "$VALIDATOR" "$1" "$2" >"$TMP/out" 2>&1; local rc=$?
  return $rc
}

# ── рівень 1 (LLM-чекер) ────────────────────────────────────────────────────
level1() { # level1 <type> <файл-тіла> <модель> → друкує сирий вивід у $TMP/llm
  local type="$1" file="$2" model="$3"
  local prompt="$TMP/prompt"
  {
    echo "Ти — checker фабрики STRW. Оціни артефакт типу '$type' за рубрикою."
    echo "ПЕРШИЙ РЯДОК відповіді — рівно одне слово: PASS або FAIL."
    echo "Далі — нумеровані заперечення: що саме хибне і чому. Структуру секцій"
    echo "уже перевірив скрипт рівня 0; ти оцінюєш ЗМІСТ."
    echo
    echo "=== РУБРИКА (references/evals/rubrics.md) ==="
    cat "$EVALS_DIR/rubrics.md"
    if [ -f "$REPO/references/review-policy.md" ]; then
      echo; echo "=== ПОЛІТИКА РЕВ'Ю (references/review-policy.md) ==="
      cat "$REPO/references/review-policy.md"
    fi
    echo; echo "=== АРТЕФАКТ ==="
    cat "$file"
  } > "$prompt"
  claude -p --model "$model" --output-format json < "$prompt" > "$TMP/raw" 2>"$TMP/err" || return 2
  python3 - "$TMP/raw" > "$TMP/llm" <<'PY' || return 2
import io, json, sys
d = json.load(io.open(sys.argv[1], encoding="utf-8"))
sys.stdout.write(d.get("result") or d.get("text") or "")
PY
  return 0
}

verdict_of() { awk 'NF{print toupper($1); exit}' "$1" | tr -d ':'; }

mentions_defect() { # mentions_defect <файл-відповіді> <keywords-рядок>
  local kw text lc
  text="$(tr 'A-Z' 'a-z' < "$1")"
  # bash 3.2: без mapfile — розбір по комі через IFS
  local IFS=','
  for kw in $2; do
    lc="$(printf '%s' "$kw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"
    [ -n "$lc" ] || continue
    case "$text" in *"$lc"*) return 0 ;; esac
  done
  return 1
}

# ── прогін: golden ──────────────────────────────────────────────────────────
GOLDEN_N=0
say "── golden (очікування: PASS) ──"
for f in "$EVALS_DIR"/golden/*.golden.md; do
  [ -f "$f" ] || continue
  t="$(basename "$f" .golden.md)"
  [ -z "$TYPE_FILTER" ] || [ "$t" = "$TYPE_FILTER" ] || continue
  GOLDEN_N=$((GOLDEN_N+1))
  B="$TMP/g.md"; body "$f" "$B"
  if level0 "$t" "$B"; then
    green "golden $t · рівень 0"; row golden "$t" golden 0 PASS PASS true ""
  else
    red "golden $t · рівень 0 мусив дати PASS: $(head -3 "$TMP/out" | tr '\n' ' ')"
    row golden "$t" golden 0 PASS FAIL false "$(cat "$TMP/out")"
  fi
  if [ "$OFFLINE" = "false" ]; then
    L="$(loop_of "$t")"; M="$(checker_model "$L")"
    if level1 "$t" "$B" "$M"; then
      V="$(verdict_of "$TMP/llm")"
      if [ "$V" = "PASS" ]; then
        green "golden $t · рівень 1 ($M)"; row golden "$t" golden 1 PASS PASS true "model=$M"
      else
        red "golden $t · рівень 1 ($M) дав '$V', а еталон мусить проходити"
        row golden "$t" golden 1 PASS "$V" false "model=$M · $(head -c 300 "$TMP/llm")"
      fi
    else
      red "golden $t · рівень 1: виклик чекера не вдався ($(head -c 200 "$TMP/err"))"
      row golden "$t" golden 1 PASS ERROR false "виклик не вдався"
    fi
  fi
done

# ── прогін: seeded ──────────────────────────────────────────────────────────
SEEDED_N=0
say "── seeded (очікування: зловлений дефект) ──"
for f in "$EVALS_DIR"/seeded/*/*.md; do
  [ -f "$f" ] || continue
  t="$(fm "$f" type)"; exp="$(fm "$f" expect)"; lvl="$(fm "$f" level)"
  def="$(fm "$f" defect)"; kws="$(fm "$f" defect_keywords | tr -d '[]')"
  name="$(basename "$f" .md)"
  [ -z "$TYPE_FILTER" ] || [ "$t" = "$TYPE_FILTER" ] || continue
  SEEDED_N=$((SEEDED_N+1))
  if [ -z "$t" ] || [ -z "$exp" ] || [ -z "$lvl" ] || [ -z "$def" ]; then
    red "seeded $name · frontmatter неповний (треба type/expect/level/defect)"
    row seeded "${t:-?}" "$name" "${lvl:-?}" "${exp:-?}" ERROR false "frontmatter неповний"
    continue
  fi
  B="$TMP/s.md"; body "$f" "$B"

  if [ "$lvl" = "0" ]; then
    level0 "$t" "$B"; rc=$?
    if [ "$rc" -eq 2 ]; then
      red "seeded $t/$name · валідатор не знає типу '$t'"
      row seeded "$t" "$name" 0 "$exp" ERROR false "unknown type"
    elif { [ "$exp" = "FAIL" ] && [ "$rc" -eq 1 ]; } || { [ "$exp" = "PASS" ] && [ "$rc" -eq 0 ]; }; then
      green "seeded $t/$name · рівень 0 дав $exp"
      row seeded "$t" "$name" 0 "$exp" "$exp" true "$def"
    else
      red "seeded $t/$name · рівень 0 мусив дати $exp (дефект: $def)"
      row seeded "$t" "$name" 0 "$exp" "$([ "$rc" -eq 0 ] && echo PASS || echo FAIL)" false "$def"
    fi
    continue
  fi

  # level: 1 — змістовий дефект. Рівень 0 його НЕ ловить, і це перевіряється
  # тут же: фікстура, що падає рівнем 0, позначена не тим рівнем, і онлайн-
  # прогін ніколи б не довів, що LLM-чекер її бачить.
  if level0 "$t" "$B"; then :; else
    red "seeded $t/$name · позначена level: 1, але падає вже на рівні 0 — рівень у frontmatter неправильний"
    row seeded "$t" "$name" 1 "$exp" MISLABELED false "$(head -2 "$TMP/out" | tr '\n' ' ')"
    continue
  fi
  if [ "$OFFLINE" = "true" ]; then
    SKIP=$((SKIP+1)); say "SKIP · seeded $t/$name · level 1 (офлайн)"
    row seeded "$t" "$name" 1 "$exp" SKIPPED true "$def"
    continue
  fi
  L="$(loop_of "$t")"; M="$(checker_model "$L")"
  if ! level1 "$t" "$B" "$M"; then
    red "seeded $t/$name · виклик чекера не вдався ($(head -c 200 "$TMP/err"))"
    row seeded "$t" "$name" 1 "$exp" ERROR false "виклик не вдався"
    continue
  fi
  V="$(verdict_of "$TMP/llm")"
  if [ "$V" != "$exp" ]; then
    red "seeded $t/$name · чекер ($M) дав '$V', очікувався '$exp' · дефект: $def"
    row seeded "$t" "$name" 1 "$exp" "$V" false "model=$M · $(head -c 300 "$TMP/llm")"
  elif [ "$exp" = "FAIL" ] && ! mentions_defect "$TMP/llm" "$kws"; then
    red "seeded $t/$name · чекер сказав FAIL, але не про цей дефект (жодного з ключів: $kws)"
    row seeded "$t" "$name" 1 "$exp" "FAIL-WRONG-REASON" false "model=$M · $(head -c 300 "$TMP/llm")"
  else
    green "seeded $t/$name · чекер ($M) зловив дефект"
    row seeded "$t" "$name" 1 "$exp" "$V" true "model=$M · $def"
  fi
done

# ── підсумок ────────────────────────────────────────────────────────────────
if [ "$GOLDEN_N" -eq 0 ] || [ "$SEEDED_N" -eq 0 ]; then
  say ""
  say "run.sh: набір порожній (golden: $GOLDEN_N, seeded: $SEEDED_N${TYPE_FILTER:+, тип $TYPE_FILTER})."
  say "  Нуль фікстур — це помилка, а не успіх: раннер без набору звітував би «0 падінь»."
  exit 2
fi

MODE="$([ "$OFFLINE" = "true" ] && echo offline || echo online)"
if [ "$WRITE_RESULTS" = "true" ]; then
  mkdir -p "$RESULTS_DIR"
  OUT="$RESULTS_DIR/$(date +%Y-%m-%d).json"
  {
    printf '{\n  "date": "%s",\n  "mode": "%s",\n  "type_filter": "%s",\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$MODE" "$TYPE_FILTER"
    printf '  "totals": {"golden": %d, "seeded": %d, "pass": %d, "fail": %d, "skipped": %d},\n' \
      "$GOLDEN_N" "$SEEDED_N" "$PASS" "$FAIL" "$SKIP"
    printf '  "cases": [\n'
    n=0; total="$(wc -l < "$ROWS" | tr -d ' ')"
    while IFS=$'\t' read -r kind type case lvl exp got ok detail; do
      n=$((n+1))
      printf '    {"kind": "%s", "type": "%s", "case": "%s", "level": %s, "expect": "%s", "got": "%s", "ok": %s, "detail": "%s"}%s\n' \
        "$kind" "$type" "$case" "$lvl" "$exp" "$got" "$ok" "$detail" "$([ "$n" -lt "$total" ] && echo ,)"
    done < "$ROWS"
    printf '  ]\n}\n'
  } > "$OUT"
  [ "$MODE" = "offline" ] && cp "$OUT" "$RESULTS_DIR/latest-offline.json"
  say ""
  say "Звіт: $OUT"
fi

say ""
say "Разом ($MODE): PASS=$PASS FAIL=$FAIL SKIP=$SKIP · golden $GOLDEN_N · seeded $SEEDED_N"
[ "$FAIL" -eq 0 ]
