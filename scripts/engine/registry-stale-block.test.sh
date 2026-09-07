#!/usr/bin/env bash
# registry-stale-block.test.sh — проби на дзеркало `registry.knows-open-prs`:
# реєстр не каже «зайнято» про роботу, чиї блокери ВЖЕ `done`.
#
# ЧОМУ ОКРЕМИЙ ФАЙЛ, А НЕ РЯДКИ У validate-items.test.sh. Той набір вимагає
# парасольки STRW з УСІМА п'ятьма клонами і без них каже `SKIP` з кодом 0 —
# у контурі C (хмара, чотири клони, без кореня strw-ops) він не виконує жодної
# перевірки. Проба, дописана туди, була б зеленою рівно там, де її предмет
# знайдено вперше: клас `green-because-subject-missing`. Тутешня фікстура
# самодостатня — одна смуга на `strw-factory`, два-три елементи, власний
# decisions-log — тож набір реально ЙДЕ в обох контурах.
#
# ЩО САМЕ ДОВОДИТЬСЯ (виміряно 2026-09-07 ДО фікса на цій самій фікстурі):
# елемент `state: blocked`, чий єдиний блокер `state: done`, давав
# «OK: реєстр валідний (0 warn)» і rc 0. У живому реєстрі таких було ЧОТИРИ —
# робота, невидима для черги, і відповідь петлі «немає роботи / немає інструмента»
# була правдою про вимір і неправдою про реєстр.
#
# ТОЧНА ПРИЧИНА НЕВИДИМОСТІ (виправлено 07.09 за зовнішнім рев'ю 6a): елемент
# випадає з черги через свій СТАН — `toolchain-filter.sh:72` починається з
# `state != "ready"`, і для `blocked` цей диз'юнкт істинний завжди. Перша редакція
# цього заголовка приписувала причину полю `blocked_by`; це було хибно, хоча сам
# дефект від того не менший.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="$HERE/validate-items.sh"

# Парасолька потрібна лише щоб резолвити `repo:` фікстурної смуги в клон. Береться
# ОДНЕ репо — `strw-factory`, тобто те, у якому лежить сам валідатор, — тож набір
# не залежить від наявності сусідів.
if [ -z "${STRW_ROOT:-}" ]; then
    STRW_ROOT="$(cd "$HERE/../../.." && pwd)"
    while [ ! -d "$STRW_ROOT/strw-factory/.git" ] && [ "$STRW_ROOT" != "/" ]; do
        STRW_ROOT="$(dirname "$STRW_ROOT")"
    done
fi
# FAIL-CLOSED, і це куплено знахідкою зовнішнього рев'юера 6a (Important, 07.09):
# «SKIP з кодом 0» НЕ ВІДРІЗНИТИ від «PASS» тому, хто читає лише код виходу — а probe
# у `enforcement.yaml` читає саме його і глушить вивід (`>/dev/null 2>&1`). Тобто набір,
# який не виконав ЖОДНОЇ перевірки, давав би 🟢 «примус на місці» — рівно той
# `green-because-subject-missing`, яким шапка цього файла обґрунтовує власне існування.
# Асиметрію назвав рев'юер: `validate-items.sh` на тій самій підставі дає ERROR
# (fail-closed), а тут була зелень (fail-open).
# Код 3, а не 0: він відрізняється і від успіху (0), і від провалу проб (1).
# `.git` перевіряємо git-ом, а не `test -d`: у worktree і в підмодулі `.git` — ФАЙЛ
# (`gitdir: …`), і `-d` там хибний. Це той самий клас, що вже коштував заходу 07.09
# у `mount-can-unlink.sh`.
git -C "$STRW_ROOT/strw-factory" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "SKIP · $STRW_ROOT/strw-factory не є git-клоном — фікстурній смузі нема що резолвити (код 3: НЕ читати як PASS)"
    exit 3; }

PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ok()  { PASS=$((PASS+1)); printf 'PASS · %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL · %s\n%s\n' "$1" "${2:-}"; }

FX="$TMP/state"
fixture_reset() {
    rm -rf "$FX"; mkdir -p "$FX/engine/items"
    printf '1' > "$FX/engine/schema_version"
    cat > "$FX/engine/lanes.yaml" <<'EOF'
schema_version: 1
lanes:
  - id: probe-lane
    repo: strw-factory
    owns: ["scripts/engine/**"]
    resources: []
    codex_maker: allowed
EOF
    printf '# decisions\n\n## 2026-01-01 · dec-001 · TEST\nфікстура\n' > "$FX/decisions-log.md"
}

mk() { # mk <id> <state> <blocked_by-inline>
    cat > "$FX/engine/items/$1.yaml" <<EOF
schema_version: 1
id: $1
product: factory
loop: L3-build
lane: probe-lane
state: $2
repo: strw-factory
branch: cycle/$1
acceptance: |
  - фікстура
acceptance_basis:
  verified_against_decisions_log_at: 2026-01-01T00:00Z
  decisions_log_entries: 1
  sources:
    - "фікстура"
lease: {run_id: null, epoch: 0, heartbeat: null}
evidence: {run_id: null, commit_sha: null, cwd: /tmp}
attempts: 0
blocked_by: $3
EOF
}

run_v() { STRW_ROOT="$STRW_ROOT" bash "$V" "$FX/engine" 2>&1; }

# 0. КОНТРОЛЬ: здорова фікстура валідна. Без цього рядка червоне нижче нічого не
#    доводить — воно могло б бути червоним із будь-якої іншої причини.
fixture_reset
mk probe.blocker  running '[]'
mk probe.dependent blocked '[item:probe.blocker]'
out="$(run_v)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q "STALE"; then
    ok "контроль: блокер ще не done → реєстр валідний, STALE немає"
else bad "здорова фікстура мала б бути валідною без STALE" "rc=$rc
$out"; fi

# 1. ПРЕДМЕТ: єдиний блокер `done`, а елемент досі `blocked` → STALE і rc != 0,
#    з обома id у тексті (без них читач не знає, ЩО розблоковувати).
fixture_reset
mk probe.blocker  done    '[]'
mk probe.dependent blocked '[item:probe.blocker]'
out="$(run_v)"; rc=$?
if [ "$rc" -ne 0 ] \
   && printf '%s' "$out" | grep -q "^STALE: probe.dependent.yaml:" \
   && printf '%s' "$out" | grep -q "probe.blocker"; then
    ok "усі блокери done, а state=blocked → STALE із назвами елемента і блокера"
else bad "задоволений blocked_by мав би дати STALE і rc != 0" "rc=$rc
$out"; fi

# 2. НЕГАТИВНИЙ КОНТРОЛЬ: два блокери, один done, другий ні → НЕ STALE.
#    Перевірка мусить вимагати ВСІХ, інакше вона червонітиме на здоровому реєстрі.
fixture_reset
mk probe.blocker   done    '[]'
mk probe.blocker2  ready   '[]'
mk probe.dependent blocked '[item:probe.blocker, item:probe.blocker2]'
out="$(run_v)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q "STALE"; then
    ok "негативний контроль: один блокер done, другий ні → STALE немає"
else bad "частково задоволений blocked_by не мав би червоніти" "rc=$rc
$out"; fi

# 3. НЕГАТИВНИЙ КОНТРОЛЬ: `ceo:` поруч із задоволеним `item:` → НЕ STALE.
#    Дія CEO — не елемент реєстру; її стану звідси не видно, тож мовчати тут
#    правильно, а не зручно.
fixture_reset
mk probe.blocker   done    '[]'
mk probe.dependent blocked '[item:probe.blocker, ceo:щось-від-CEO]'
out="$(run_v)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q "STALE"; then
    ok "негативний контроль: ceo:-блокер поруч із done → STALE немає"
else bad "ceo:-блокер мав би тримати елемент заблокованим" "rc=$rc
$out"; fi

# 4. НЕГАТИВНИЙ КОНТРОЛЬ: сам лише `ceo:` → НЕ STALE (і не «всі item: задоволені»
#    на порожньому переліку item-блокерів).
fixture_reset
mk probe.dependent blocked '[ceo:щось-від-CEO]'
out="$(run_v)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q "STALE"; then
    ok "негативний контроль: тільки ceo:-блокер → STALE немає"
else bad "елемент лише з ceo:-блокером не мав би червоніти" "rc=$rc
$out"; fi

# 5. `merge-pending` — НЕ `done`. Робота блокера ще не в main, тож розблоковувати
#    рано; окрема проба, бо спокуса «майже done» тут структурна.
fixture_reset
mk probe.blocker   merge-pending '[]'
mk probe.dependent blocked       '[item:probe.blocker]'
out="$(run_v)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q "STALE"; then
    ok "негативний контроль: блокер merge-pending ≠ done → STALE немає"
else bad "merge-pending не мав би рахуватись задоволеним" "rc=$rc
$out"; fi

# 6. ПОРОЖНІЙ `blocked_by` при state=blocked — ЧУЖИЙ предмет: це вже ERROR
#    («state=blocked, але немає `blocked_by`»), і нова перевірка не має додавати
#    сюди свій STALE. Проба заведена не для симетрії: без неї мутація «зняти гард
#    непорожніх deps» ВИЖИВАЛА (виміряно 07.09, четверта мутація з п'яти) —
#    порожній перелік читався як «усі блокери задоволені».
fixture_reset
mk probe.dependent blocked '[]'
out="$(run_v)"; rc=$?
if [ "$rc" -ne 0 ] \
   && printf '%s' "$out" | grep -q "state=blocked, але немає" \
   && ! printf '%s' "$out" | grep -q "STALE"; then
    ok "порожній blocked_by → чужий ERROR, а STALE нової перевірки немає"
else bad "порожній blocked_by мав лишитись ERROR без STALE" "rc=$rc
$out"; fi

# 7. НЕРОЗВ'ЯЗНЕ посилання поруч із задоволеним: `blocked_by` містить id, якого в
#    реєстрі немає (одрук — реєстр вживає коротку форму `m3.*` у прозі, тоді як id
#    є `pact-001.m3.*`). Такий блокер кладе ERROR і НЕ потрапляє в `deps`, тож
#    перевірка бачила б лише розв'язану підмножину і твердила «ВСІ блокери done»,
#    а припис «почисти blocked_by» стер би разом з одруком РЕАЛЬНУ залежність.
#    Знахідка зовнішнього рев'юера 6a (Important), 07.09.
fixture_reset
mk probe.blocker   done    '[]'
mk probe.dependent blocked '[item:немає-такого, item:probe.blocker]'
out="$(run_v)"; rc=$?
if [ "$rc" -ne 0 ] \
   && printf '%s' "$out" | grep -q "неіснуючий елемент" \
   && ! printf '%s' "$out" | grep -q "STALE"; then
    ok "нерозв'язний блокер поруч із done → ERROR, і STALE НЕ твердиться"
else bad "нерозв'язне посилання не мало б читатись як «усі блокери done»" "rc=$rc
$out"; fi

# 8. ПЕРЕВІРКА ПРИПИСАНА ДО СТАНУ `blocked`: done-елемент зі старим непорожнім
#    `blocked_by` (усі блокери done) — чужий ERROR рядка «є blocked_by, але state ≠
#    blocked», і STALE 6a тут НЕ твердиться. Без цієї проби мутація «зняти гард
#    state == blocked» виживала (6a р.2 #21): рядок 351 і так дає rc≠0, тож жодна
#    проба не бачила, що 6a стала б звинувачувати done-елемент.
fixture_reset
mk probe.blocker   done '[]'
mk probe.dependent done '[item:probe.blocker]'
out="$(run_v)"; rc=$?
if [ "$rc" -ne 0 ] \
   && ! printf '%s' "$out" | grep -q "STALE"; then
    ok "done-елемент зі старим blocked_by → чужий ERROR, STALE 6a не твердиться (гард state=blocked)"
else bad "6a не сміє звинувачувати done-елемент" "rc=$rc
$out"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
# `$PASS -gt 0` — не педантизм: набір, який не виконав жодної проби, інакше вийшов би
# нулем і читався б як успіх (знахідка 6a).
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
