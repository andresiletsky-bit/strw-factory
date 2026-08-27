#!/usr/bin/env bash
# Вивід генератора фасадів НЕ МОЖЕ залежати від рантайму. Запуск на Mac:
#   bash scripts/brain/split-monoliths.test.sh
#
# Чому саме ця проба. Пре-коміт `strw-state/.githooks/pre-commit` кличе
# `--check-facade` через **deno**; скіли, README і текст самої помилки кажуть
# просто «split-monoliths.mjs --regen», що на цій машині — **node**. Поки
# впорядкування спиралось на порядок перерахунку теки (`sort` за неунікальним
# `seq` → стабільний JS-sort зберігає порядок ВХОДУ, а вхід дає
# `fs.readdirSync`), ці двоє давали різні файли. Оператор, який чесно
# перегенерував за інструкцією, отримував відмову «фасад правили рукою» —
# гейт звинувачував у дії, якої не було, і радив ту, що відтворює збій
# (`tri-027`, вимір 2026-08-27: node `39ab5054…`, deno `d988d9c4…`, стабільно
# через прогін).
#
# Проба міряє САМЕ це: два рантайми, одна фікстура, побайтова рівність.
# Фікстура — копія реального корпусу `strw-state`, бо колізії `seq` там
# справжні (`2026-08-19-003-finding` і `-003-question` обидва дають 3), а
# вигадана пара довела б лише те, що я вмію вигадати пару.
set -uo pipefail

STATE_SRC="${STRW_STATE:-$HOME/Developer/STRW/strw-state}"
GEN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/split-monoliths.mjs"
PASS=0; FAIL=0

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

for bin in node deno; do
  command -v "$bin" >/dev/null 2>&1 || { echo "SKIP: немає $bin — проба міряє саме розбіжність двох, без обох вона порожня"; exit 0; }
done
[ -d "$STATE_SRC/triage" ] || { echo "FAIL: немає корпусу $STATE_SRC/triage"; exit 1; }

fixture() { # $1 → тека
  mkdir -p "$1"
  for p in triage triage-inbox.md decisions decisions-log.md budget budget.md; do
    [ -e "$STATE_SRC/$p" ] && cp -R "$STATE_SRC/$p" "$1/"
  done
}

# Кожен прогін мусить ДОВОДИТИ, що відбувся. Впав генератор — скопійований
# фасад лишається на місці недоторканим, і дві незмінені копії порівнюються як
# рівні: контроль тихо міряє порожнечу. Саме так ця проба і збрехала при
# першому написанні (мутант не бачив `lib.mjs` поруч і падав
# `ERR_MODULE_NOT_FOUND`, а перевірка звітувала «same»).
#
# Доказ — не рядок у виводі: генератор мовчить, коли переписувати нічого, і
# мутант під deno саме такий (порядок теки в deno вже збігається з тотальним,
# через що розходився лише node). Тому `fixture` навмисне ПСУЄ фасад, а
# `regen` вимагає, щоб псування зникло: файл без нього міг народитись лише
# з-під живого генератора.
CANARY="ЦЕЙ-РЯДОК-МУСИТЬ-ЗНИКНУТИ-ПІСЛЯ-REGEN"

regen() { # $1 рантайм · $2 тека · $3 генератор (типово GEN)
  local gen="${3:-$GEN}" out rc f="$2/triage-inbox.md"
  printf '\n%s\n' "$CANARY" >> "$f"
  if [ "$1" = node ]; then
    out="$(node "$gen" --regen --state "$2" 2>&1)"; rc=$?
  else
    out="$(deno run -q --allow-read --allow-write --allow-env "$gen" --regen --state "$2" 2>&1)"; rc=$?
  fi
  if [ "$rc" -ne 0 ] || grep -q "$CANARY" "$f"; then
    printf 'FAIL · %s не перегенерував %s (rc=%s, канарка на місці):\n%s\n' "$1" "$2" "$rc" "$out"
    return 1
  fi
}

check() { # $1 назва · $2 очікування(same|differ) · $3 sha_a · $4 sha_b
  local got; [ "$3" = "$4" ] && got=same || got=differ
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf 'PASS · %s (%s)\n' "$1" "$got"
  else FAIL=$((FAIL+1)); printf 'FAIL · %s: очікував %s, отримав %s\n  %s\n  %s\n' "$1" "$2" "$got" "$3" "$4"; fi
}

sha() { shasum -a256 "$1" | cut -d' ' -f1; }

# ── 1. Той самий рантайм двічі — детермінізм у межах одного (контроль) ──
# Без нього рівність нижче могла б означати «генератор пише сталу заглушку».
A="$TMP/a"; fixture "$A"
regen node "$A" || FAIL=$((FAIL+1)); N1="$(sha "$A/triage-inbox.md")"
regen node "$A" || FAIL=$((FAIL+1)); N2="$(sha "$A/triage-inbox.md")"
check "node двічі поспіль" same "$N1" "$N2"

B="$TMP/b"; fixture "$B"
regen deno "$B" || FAIL=$((FAIL+1)); D1="$(sha "$B/triage-inbox.md")"
regen deno "$B" || FAIL=$((FAIL+1)); D2="$(sha "$B/triage-inbox.md")"
check "deno двічі поспіль" same "$D1" "$D2"

# ── 2. Головне твердження: рантайм не впливає на вивід ──
check "node проти deno — той самий байт" same "$N1" "$D1"

# ── 3. Той самий вимір для decisions-log і budget: сортувань три, ──
#      і полагодити одне, лишивши два, було б рівно тією самою дірою.
#
# Названий залишок: ці два рядки самі по собі СЛІПІ до мертвого генератора —
# він їх не переписує, дві копії лишаються рівними, і вони звітують PASS
# (виміряно підміною генератора на `throw`: 3 хибні PASS, серед них ці два).
# Набір при цьому червоний, бо канарка в `regen` рахує FAIL за кожен прогін,
# тож вердикт правильний; але поодинці цим рядкам вірити не можна.
for f in decisions-log.md budget.md; do
  [ -f "$A/$f" ] && [ -f "$B/$f" ] || continue
  check "node проти deno — $f" same "$(sha "$A/$f")" "$(sha "$B/$f")"
done

# ── 4. Негативний контроль: проба вміє червоніти. ──
# Копія генератора з компаратором, поверненим до неунікального ключа —
# якщо ЦЕ дасть «same», проба міряє не те, що заявляє.
# Мутант живе поруч зі своїм `lib.mjs` — інакше він падає на імпорті, фасад
# лишається скопійованим, і «розійшлось?» відповідає «ні» на питання, якого
# ніхто не поставив.
MUTDIR="$TMP/mut"; mkdir -p "$MUTDIR"
cp "$(dirname "$GEN")/lib.mjs" "$MUTDIR/" 2>/dev/null
MUT="$MUTDIR/mutant.mjs"
sed 's/|| a\.rel\.localeCompare(b\.rel)//g' "$GEN" > "$MUT"
if cmp -s "$GEN" "$MUT"; then
  FAIL=$((FAIL+1)); printf 'FAIL · негативний контроль: мутація не наклалась — тотального компаратора в генераторі немає\n'
else
  C="$TMP/c"; fixture "$C"; D="$TMP/d"; fixture "$D"
  if regen node "$C" "$MUT" && regen deno "$D" "$MUT"; then
    check "мутант (ключ знову неунікальний) мусить РОЗІЙТИСЬ" differ \
      "$(sha "$C/triage-inbox.md")" "$(sha "$D/triage-inbox.md")"
  else
    FAIL=$((FAIL+1)); printf 'FAIL · негативний контроль не виконався — він нічого не виміряв\n'
  fi
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
