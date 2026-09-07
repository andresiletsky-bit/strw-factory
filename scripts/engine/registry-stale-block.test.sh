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
# «OK: реєстр валідний (0 warn)» і rc 0. У живому реєстрі таких було ЧОТИРИ,
# і `toolchain-filter.sh` пропускає їх за непорожнім `blocked_by`, не дивлячись
# на стан блокерів, — тобто робота була невидима для черги, а відповідь петлі
# «немає роботи / немає інструмента» була неправдою про реєстр.
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
[ -d "$STRW_ROOT/strw-factory/.git" ] || {
    echo "SKIP · немає клону $STRW_ROOT/strw-factory — фікстурній смузі нема що резолвити"; exit 0; }

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
#    непорожніх deps» ВИЖИВАЛА (виміряно 07.09, четверта мутація з чотирьох) —
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
