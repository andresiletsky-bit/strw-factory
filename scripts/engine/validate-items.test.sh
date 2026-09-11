#!/usr/bin/env bash
# validate-items.test.sh — проби на резолвлення `repo:` у теку (repo-dir.sh).
# Запуск: bash scripts/engine/validate-items.test.sh   (потрібна парасолька STRW з клонами)
#
# ЧОМУ. tri-070 / PR strw-state #70: валідатор шукав $STRW_ROOT/strw-ops, а
# strw-ops — це сам корінь парасольки. Жоден елемент про раннер (bin/strw-run.sh)
# не міг чесно назвати repo, а «реєстр валідний» цього не бачив. Тепер словник
# один — repo-dir.sh — і ці проби тримають його в обидва боки:
#   · смуга з repo: strw-ops і owns bin/** → глоби рахуються на HEAD кореня;
#   · той самий реєстр зі СТАРИМ правилом ($root/strw-ops) → ERROR
#     (негативний контроль: набір, який не вміє почервоніти, нічого не доводить);
#   · repo поза словником → ERROR, що називає словник.
#
# Фікстура — копія ЖИВОГО реєстру (engine/ + decisions/) у tmp, парасолька справжня:
# смуги реєстру посилаються на всі п'ять репо, і підробити п'ять клонів дорожче,
# ніж прочитати справжні. Це робить пробу залежною від наявності клонів — на Mac
# фабрики вони є завжди; без них тест каже SKIP, не PASS.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="$HERE/validate-items.sh"
# Парасолька: $STRW_ROOT, інакше ../../.. від скрипта; з worktree
# (strw-factory-worktrees/<гілка>/scripts/engine) це тека worktree-ів — тоді ще
# на рівень вище. Той самий клас, що й у самого валідатора (див. його шапку).
if [ -z "${STRW_ROOT:-}" ]; then
    STRW_ROOT="$(cd "$HERE/../../.." && pwd)"
    while [ ! -d "$STRW_ROOT/strw-state/engine" ] && [ "$STRW_ROOT" != "/" ]; do
        STRW_ROOT="$(dirname "$STRW_ROOT")"
    done
fi
PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ok()  { PASS=$((PASS+1)); printf 'PASS · %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL · %s\n%s\n' "$1" "${2:-}"; }

LIVE="$STRW_ROOT/strw-state"
# Клони мусять бути ВСІ, кого знає словник: фікстура — копія живого lanes.yaml, і
# відсутній pact-backend червонив би «не знайдено як git-клон» з чужої причини.
# Перелік тут ЛІТЕРАЛЬНИЙ, не через strw_repo_dir: сторож, що резолвить теки словником,
# який сам і перевіряє, читав би зламаний словник як «немає клону» → SKIP → rc 0
# (чекер PR #16, р.2, N1). Це другий, незалежний примірник оракула — навмисно.
for d in "$STRW_ROOT" "$STRW_ROOT/strw-state" "$STRW_ROOT/strw-factory" \
         "$STRW_ROOT/pact-ios" "$STRW_ROOT/pact-backend"; do
    [ -d "$d/.git" ] || { echo "SKIP · немає клону $d — проба потребує парасольки STRW з усіма клонами"; exit 0; }
done
[ -f "$LIVE/engine/lanes.yaml" ] || { echo "SKIP · немає $LIVE/engine/lanes.yaml"; exit 0; }

# Фікстурний strw-state: engine/ і decisions/ поруч, як у живому.
FX="$TMP/strw-state"; mkdir -p "$FX"
cp -R "$LIVE/engine" "$FX/engine"
cp -R "$LIVE/decisions" "$FX/decisions" 2>/dev/null || true
[ -f "$LIVE/decisions-log.md" ] && cp "$LIVE/decisions-log.md" "$FX/decisions-log.md"

# id смуги — zz-probe-lane, не ops-tooling: така смуга в живому lanes.yaml УЖЕ є (з 07.08),
# і проба 2 червоніла «дубль смуги» з чужої причини — набір не міг стати зеленим (6a #27, Major).
# owns docs/**, не bin/** tests/**: ці шляхи вже належать живій смузі ops-tooling, і проба
# червоніла «ділять 63 шляхи» з чужої причини.
add_lane() { # add_lane <repo> — смуга zz-probe-lane з owns docs/** перед `tools:`
    python3 - "$FX/engine/lanes.yaml" "$1" <<'PY'
import sys, io
p, repo = sys.argv[1], sys.argv[2]
t = io.open(p, encoding="utf-8").read()
lane = ("  - id: zz-probe-lane\n    repo: %s\n    owns: [\"docs/**\"]\n"
        "    resources: []\n    codex_maker: allowed\n    codex_evidence: \"проба\"\n") % repo
k = t.index("\ntools:")
io.open(p, "w", encoding="utf-8").write(t[:k] + "\n" + lane + t[k:])
PY
}

run_v() { STRW_ROOT="$STRW_ROOT" bash "$V" "$FX/engine" 2>&1; }

# 0. контроль: фікстура без змін валідна (інакше далі міряли б не те)
out="$(run_v)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "фікстура = живий реєстр: валідна (контроль)"; else bad "фікстура без змін мала б бути валідною" "$out"; fi

# 1. негативний контроль — СТАРЕ правило ($root/strw-ops) на тій самій смузі → ERROR.
# Без env-шва: копія валідатора поруч зі СТАРИМ словником (валідатор бере repo-dir.sh
# зі своєї теки) — так само, як він побачив би зламаний словник у релізі.
add_lane strw-ops
OLDDIR="$TMP/old"; mkdir -p "$OLDDIR"; cp "$V" "$OLDDIR/validate-items.sh"
cat > "$OLDDIR/repo-dir.sh" <<'SH'
STRW_REPOS="strw-ops strw-state strw-factory pact-ios pact-backend"
strw_repo_dir() { printf '%s/%s' "$1" "$2"; }
strw_repo_dirs() { local r; for r in $STRW_REPOS; do printf '%s=%s\n' "$r" "$(strw_repo_dir "$1" "$r")"; done; }
SH
out="$(STRW_ROOT="$STRW_ROOT" bash "$OLDDIR/validate-items.sh" "$FX/engine" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "репо 'strw-ops' не знайдено як git-клон у .*/strw-ops$"; then
    ok "негативний контроль: старе правило \$root/strw-ops → ERROR саме на strw-ops"
else bad "старе правило мало б червоніти саме на strw-ops" "$out"; fi

# 2. новий словник: та сама смуга → валідно, глоби bin/** tests/** матчать корінь
out="$(run_v)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q "ERROR.*zz-probe-lane"; then
    ok "repo: strw-ops → корінь парасольки; owns docs/** рахуються на HEAD кореня"
else bad "смуга zz-probe-lane з repo strw-ops мала б пройти" "$out"; fi

# 3. репо поза словником → ERROR, що називає словник
cp -R "$LIVE/engine" "$FX/engine.clean" && rm -rf "$FX/engine" && mv "$FX/engine.clean" "$FX/engine"
add_lane nope
out="$(run_v)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "невідоме словнику strw-factory/scripts/engine/repo-dir.sh"; then
    ok "repo: nope → ERROR із назвою словника"
else bad "вигадане репо мало б бути ERROR із назвою словника" "$out"; fi

# 4. сам словник: невідоме репо → rc 64 і назва словника (єдина проба цієї гілки —
# validate-items її не досягає, а strw-worktree.sh споживає саме її)
out="$(bash -c '. "$1"; strw_repo_dir /r nope' _ "$HERE/repo-dir.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 64 ] && printf '%s' "$out" | grep -q "repo-dir.sh"; then
    ok "strw_repo_dir /r nope → rc 64 з назвою словника"
else bad "невідоме репо у словнику мало б дати rc 64" "rc=$rc $out"; fi
out="$(bash -c '. "$1"; strw_repo_dirs /r' _ "$HERE/repo-dir.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | grep -c '=')" -eq 5 ] && printf '%s' "$out" | grep -q '^strw-ops=/r$'; then
    ok "strw_repo_dirs → 5 пар, strw-ops=/r (корінь)"
else bad "мапа словника" "rc=$rc $out"; fi

# 5. перелік і case розійшлися → strw_repo_dirs падає rc 64, без порожньої теки (шапка
# словника це обіцяє; без свідка обіцянка — проза)
out="$(bash -c '. "$1"; STRW_REPOS="strw-ops pact-web"; strw_repo_dirs /r' _ "$HERE/repo-dir.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 64 ] && ! printf '%s' "$out" | grep -q '^pact-web='; then
    ok "перелік ≠ case (pact-web) → strw_repo_dirs rc 64, пари pact-web= немає"
else bad "розходження переліку і case мало б дати rc 64" "rc=$rc $out"; fi
# 6. …і валідатор на такому словнику зупиняється ERROR-ом, не міряє далі
BAD="$TMP/bad"; mkdir -p "$BAD"; cp "$V" "$BAD/validate-items.sh"
sed 's/^STRW_REPOS=.*/STRW_REPOS="strw-ops strw-state strw-factory pact-ios pact-backend pact-web"/' "$HERE/repo-dir.sh" > "$BAD/repo-dir.sh"
out="$(STRW_ROOT="$STRW_ROOT" bash "$BAD/validate-items.sh" "$FX/engine" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "словник репо розійшовся сам із собою"; then
    ok "валідатор зі словником, що розійшовся сам із собою → ERROR і стоп"
else bad "валідатор мав би зупинитись на зламаному словнику" "rc=$rc $out"; fi

# 7. дубльований ключ у item → ERROR з іменем ключа і ОБОМА рядками (tri-094: safe_load
# брав останній мовчки — deck-content читався з attempts: 0). Фікстура — окремий чистий
# реєстр з одного елемента, щоб проба не залежала від стану живого (у ньому дублі теж
# бували — саме їх цей гейт і знайшов першим прогоном: subscribe-gate-handoff, ty-to-vy).
cp -R "$LIVE/engine" "$FX/engine.clean" && rm -rf "$FX/engine" && mv "$FX/engine.clean" "$FX/engine"
# Фікстури — з відомого рядка, не з мутації живого файла (`ls | head -1` давав різний
# файл, і регекс по evidence: ламав блокову мапу — 6a #27, Minor). Дубль зупиняє парсер
# раніше за схему, тож мінімального файла досить.
DUP="$FX/engine/items/zz.dup-probe.yaml"
printf 'schema_version: 1\nid: zz.dup-probe\nattempts: 7\nattempts: 8\n' > "$DUP"
out="$(run_v)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'zz.dup-probe.yaml: не парситься: дубльований ключ `attempts` (рядки 3 і 4)'; then   # точні номери: 1-based, обидва (6a р.2)
    ok "дубльований ключ attempts у item → ERROR з іменем ключа і двома рядками"
else bad "дубльований ключ у item мав би бути ERROR із назвою ключа" "$out"; fi
rm -f "$DUP"
# 7b. дубль у ВКЛАДЕНІЙ мапі (evidence.cwd) — саме така форма була в живому реєстрі
printf 'schema_version: 1\nid: zz.dup-probe\nevidence:\n  run_id: a\n  cwd: /x\n  cwd: /y\n' > "$DUP"
out="$(run_v)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'zz.dup-probe.yaml: не парситься: дубльований ключ `cwd` (рядки 5 і 6)'; then
    ok "дубльований ключ у вкладеній мапі (evidence.cwd) → ERROR"
else bad "дубль у вкладеній мапі мав би бути ERROR" "$out"; fi
rm -f "$DUP"
# 7c. lanes.yaml з дубльованим ключем → ERROR
python3 - "$FX/engine/lanes.yaml" <<'PY'
import sys, io
p = sys.argv[1]; t = io.open(p, encoding="utf-8").read()
io.open(p, "w", encoding="utf-8").write(t.rstrip("\n") + "\nschema_version: 1\n")
PY
out="$(run_v)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'дубльований ключ `schema_version`'; then
    ok "lanes.yaml з дубльованим schema_version → ERROR"
else bad "дубль у lanes.yaml мав би бути ERROR" "$out"; fi

# 7d. merge-ключ `<<` і ключі 1/true — ВАЛІДНИЙ YAML, не дубль (негативні контролі гейта:
# перша редакція червонила `<<` брехливим «не парситься» — 6a #27, Major)
python3 - "$FX/engine/lanes.yaml" <<'PY'
import sys, io
p = sys.argv[1]; t = io.open(p, encoding="utf-8").read()
t = t.replace("\nschema_version: 1\n", "\n", 1)   # прибрати дубль із 7c
io.open(p, "w", encoding="utf-8").write(t.rstrip("\n") + "\nzz_probe_base: &zzb {a: 1}\nzz_probe_merge:\n  <<: *zzb\n  b: 2\nzz_probe_keys: {1: x, true: y}\n")
PY
out="$(run_v)"; rc=$?
# рядок помилки валідатора — «lanes.yaml не парситься:» (без двокрапки після імені): перша
# редакція проби гребла «lanes.yaml: не парситься» і була сліпа — мутація «прибрати пропуск
# merge-ключа» лишала її зеленою (спіймано власною мутацією 11.09)
if ! printf '%s' "$out" | grep -q "lanes.yaml не парситься"; then
    ok "merge-ключ << і ключі 1/true у lanes.yaml — не «не парситься» (валідний YAML пропущено)"
else bad "валідний YAML з << / 1,true мав би парситись" "$out"; fi
# 7e. дубль у frontmatter вузла рішення (affects:) → ERROR — теж load_nodup (6a #27, Minor)
if [ -d "$FX/decisions" ]; then
    DN="$(find "$FX/decisions" -name '*.md' | head -1)"
    if [ -n "$DN" ]; then
        python3 - "$DN" <<'PY'
import sys, io
p = sys.argv[1]; t = io.open(p, encoding="utf-8").read()
assert t.startswith("---\n"); i = t.index("\n---\n", 4)
io.open(p, "w", encoding="utf-8").write(t[:i] + "\nzz_dup: 1\nzz_dup: 2" + t[i:])
PY
        out="$(run_v)"; rc=$?
        if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'дубльований ключ `zz_dup`'; then
            ok "дубль у frontmatter вузла рішення → ERROR"
        else bad "дубль у frontmatter вузла мав би бути ERROR" "$out"; fi
    else echo "SKIP · 7e: у фікстурі немає вузлів рішень (decisions/*.md) — проба не ганялась"; fi
else echo "SKIP · 7e: у фікстурі немає decisions/ — проба не ганялась"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
