#!/usr/bin/env bash
# run.test.sh — проби для evals-раннера. Запуск: bash scripts/evals/run.test.sh
#
# Правило docs/testing.md: кожен набір мусить мати і зелений, і червоний
# випадок. Зелений тут один (живий набір проходить), решта — мутації, які
# МУСЯТЬ почервоніти. Без них «зелено» означало б лише те, що раннер уміє
# друкувати PASS.
#
# bash 3.2 + BSD: без mapfile, без declare -A, без GNU sed -i (тут perl -pi).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$REPO/scripts/evals/run.sh"
PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

probe() { # probe <назва> <очікуваний rc> <команда…>
  local name="$1" want="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ]; then
    PASS=$((PASS+1)); printf 'PASS · %s (rc=%s)\n' "$name" "$rc"
  else
    FAIL=$((FAIL+1)); printf 'FAIL · %s: очікував rc=%s, отримав %s\n%s\n' "$name" "$want" "$rc" "$(printf '%s' "$out" | tail -6)"
  fi
}

fresh() { # fresh <ім'я> → друкує шлях до копії references/evals
  local d="$TMP/$1"
  mkdir -p "$d"
  cp -R "$REPO/references/evals/." "$d/"
  rm -rf "$d/results"
  printf '%s' "$d"
}

echo "── 1. Живий набір ──"
probe "живі golden + seeded, офлайн → зелено" 0 \
  bash "$RUN" --offline --no-results

probe "--type на живому типі → зелено" 0 \
  bash "$RUN" --offline --no-results --type portfolio-brief

echo "── 2. Мутація фікстури: зіпсований expect ──"
# Фікстура каже expect: PASS, хоча дефект у ній справжній і рівень 0 його ловить.
# Раннер мусить почервоніти, а не «повірити» frontmatter'у.
D="$(fresh mut-expect)"
perl -pi -e 's/^expect: FAIL$/expect: PASS/' "$D/seeded/prd/no-non-goals.md"
probe "seeded з підміненим expect → червоно" 1 \
  env STRW_EVALS_DIR="$D" bash "$RUN" --offline --no-results

echo "── 3. Порожній набір — помилка, не успіх ──"
D="$(fresh empty-seeded)"
rm -rf "$D/seeded"; mkdir -p "$D/seeded"
probe "порожня тека seeded → rc=2" 2 \
  env STRW_EVALS_DIR="$D" bash "$RUN" --offline --no-results

D="$(fresh empty-golden)"
rm -f "$D"/golden/*.golden.md
probe "порожня тека golden → rc=2" 2 \
  env STRW_EVALS_DIR="$D" bash "$RUN" --offline --no-results

probe "--type, якого в наборі немає → rc=2" 2 \
  bash "$RUN" --offline --no-results --type no-such-artifact

echo "── 4. Мутація валідатора: вимкнена перевірка обов'язкової секції ──"
# Це і є негативний контроль до всього набору. Якщо він не червоніє, значить
# раннер не міряє validate-artifact.sh, а лише читає власний frontmatter.
MUTV="$TMP/validate-artifact.mutated.sh"
cp "$REPO/scripts/validate-artifact.sh" "$MUTV"
perl -pi -e 's/\|\| MISSING\+=\("\$section"\)/|| true/' "$MUTV"
if grep -q 'MISSING+=("$section")' "$MUTV"; then
  FAIL=$((FAIL+1)); echo "FAIL · мутація валідатора НЕ наклалась — проба нижче нічого б не доводила"
else
  PASS=$((PASS+1)); echo "PASS · мутація валідатора наклалась (перевірка секцій вимкнена)"
fi
probe "валідатор без перевірки секцій → seeded level-0 проходять → червоно" 1 \
  env STRW_VALIDATE_ARTIFACT="$MUTV" bash "$RUN" --offline --no-results

echo "── 5. Неправильний рівень у frontmatter ловиться ──"
# level: 1 означає «рівень 0 цього не бачить». Фікстура, що падає рівнем 0 під
# міткою 1, зробила б онлайн-прогін вічнозеленим: LLM її б і не побачив.
D="$(fresh mislabeled)"
perl -pi -e 's/^level: 0$/level: 1/' "$D/seeded/prd/no-non-goals.md"
probe "level: 1 на фікстурі, що падає рівнем 0 → червоно" 1 \
  env STRW_EVALS_DIR="$D" bash "$RUN" --offline --no-results

echo "── 6. Звіт пишеться і є валідним JSON ──"
D="$(fresh results)"
R="$TMP/results-out"
STRW_EVALS_DIR="$D" STRW_EVALS_RESULTS_DIR="$R" bash "$RUN" --offline >/dev/null 2>&1
if [ -f "$R/latest-offline.json" ] && python3 -c "import io,json,sys; json.load(io.open(sys.argv[1]))" "$R/latest-offline.json" 2>/dev/null; then
  PASS=$((PASS+1)); echo "PASS · latest-offline.json написаний і парситься"
else
  FAIL=$((FAIL+1)); echo "FAIL · latest-offline.json відсутній або не JSON"
fi
if [ -f "$R/$(date +%Y-%m-%d).json" ]; then
  PASS=$((PASS+1)); echo "PASS · датований звіт написаний"
else
  FAIL=$((FAIL+1)); echo "FAIL · датованого звіту немає"
fi
# --no-results справді нічого не пише: гейт не має бруднити дерево, яке міряє.
R2="$TMP/results-none"
STRW_EVALS_DIR="$D" STRW_EVALS_RESULTS_DIR="$R2" bash "$RUN" --offline --no-results >/dev/null 2>&1
if [ -d "$R2" ]; then
  FAIL=$((FAIL+1)); echo "FAIL · --no-results усе одно створив теку звітів"
else
  PASS=$((PASS+1)); echo "PASS · --no-results не створює теки звітів"
fi

echo
echo "Разом: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
