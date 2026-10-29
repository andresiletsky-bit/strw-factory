#!/usr/bin/env bash
# tool-probe.test.sh — проба доступності запису реєстру інструментів (factory.tool-select).
# Фікстури — схема v1 (нотатка майстра 28.10, до мержу factory.tool-registry — єдине джерело).
# Позитивний контроль: свідомо наявний інструмент (сам bash) → available, код 0. Негативний:
# підроблена проба (неіснуючий виконуваний файл) → unavailable, код 3. Таймаут убиває всю групу
# процесів. Сесійна форма з shell НЕ виконується. Зламаний запис — код 2, не 0 і не 3.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="${HERE}/tool-probe.sh"
pass=0; fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
ok()  { pass=$((pass+1)); printf 'PASS · %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL · %s\n%s\n' "$1" "${2:-}"; }

R="${TMP}/root"; E="${R}/strw-state/engine"; mkdir -p "${E}" "${R}/strw-factory"
touch "${R}/strw-state/only-in-state"
cat > "${E}/lanes.yaml" <<'Y'
schema_version: 1
tools:
  bashv: {kind: tool, probe: "bash --version >/dev/null 2>&1"}
  ghost: {kind: tool, probe: "/nonexistent/ghost-tool --version"}
  empty: {kind: tool, probe: "  "}
Y
tool() { # tool <id> <probe-yaml-рядки> [measured-рядок] [status] — схема v1.1: active + needs-auth заборонено
    printf '  - id: %s\n    kind: cli\n    name: "%s"\n    tasks: [code-build]\n    roles: []\n    loops: []\n    contours: [M]\n    status: %s\n    rank: 10\n' "$1" "$1" "${4:-active}"
    [ "${4:-active}" = active ] || printf '    why: "фікстура"\n'
    printf '    availability:\n      probe:\n%s\n' "$2"
    [ -n "${3:-}" ] && printf '      measured: %s\n' "$3"
    printf '    constraints: {cost: free, user_data: none, enabled_by: preinstalled}\n    source: "фікстура"\n'
}
{
  printf 'schema_version: 1\nvocab:\n  kinds: [cli]\n  task_types: {code-build: "збірка"}\n  session_roles: [hub, master, child]\n  contours: [M, C, I]\ntools:\n'
  tool real-sh  '        kind: shell
        cmd: "bash --version >/dev/null"'
  tool fake-sh  '        kind: shell
        cmd: "/nonexistent/fake-tool --version"'
  tool exit7    '        kind: shell
        cmd: "exit 7"'
  tool in-state '        kind: shell
        cmd: "test -f only-in-state"
        cwd: strw-state'
  tool in-fact  '        kind: shell
        cmd: "test -f only-in-state"
        cwd: strw-factory'
  tool hang     "        kind: shell
        cmd: \"date +%s > ${TMP}/hang-start; sleep 30 & echo \$! > ${TMP}/hang-child.pid; wait\""
  tool lanes-ok '        kind: lanes-tool
        ref: bashv'
  tool lanes-ghost '        kind: lanes-tool
        ref: ghost'
  tool lanes-nokey '        kind: lanes-tool
        ref: no-such-key'
  tool sess-ok  "        kind: session
        how: \"Artifact action:list\"
        cmd: \"touch ${TMP}/session-ran\"" '{at: 2026-10-27T09:00Z, result: available, by: "local_x"}'
  tool sess-auth '        kind: session
        how: "mcp__x"' '{at: 2026-10-27T09:00Z, result: needs-auth, by: "local_x"}' candidate
  tool sess-off '        kind: session
        how: "mcp__x"' '{at: 2026-10-27T09:00Z, result: unavailable}'
  tool sess-old '        kind: session
        how: "mcp__x"' '{at: 2026-10-01T09:00Z, result: available}'
  tool sess-future '        kind: session
        how: "mcp__x"' '{at: 2026-11-30T09:00Z, result: available}'
  tool sess-date '        kind: session
        how: "mcp__x"' '{at: 2026-10-27, result: available}'
  tool sess-naive '        kind: session
        how: "mcp__x"' '{at: 2026-10-27 09:00:00, result: available}'
  tool sess-14d '        kind: session
        how: "mcp__x"' '{at: 2026-10-14T12:00Z, result: available}'
  tool sess-14d1m '        kind: session
        how: "mcp__x"' '{at: 2026-10-14T11:59Z, result: available}'
  tool sess-soon '        kind: session
        how: "mcp__x"' '{at: 2026-10-28T12:30Z, result: available}'
  tool sess-1h '        kind: session
        how: "mcp__x"' '{at: 2026-10-28T13:00Z, result: available}'
  tool sess-1h1m '        kind: session
        how: "mcp__x"' '{at: 2026-10-28T13:01Z, result: available}'
  tool sess-2h '        kind: session
        how: "mcp__x"' '{at: 2026-10-28T14:00Z, result: available}'
  tool sess-tomorrow '        kind: session
        how: "mcp__x"' '{at: 2026-10-29T12:00Z, result: available}'
  tool multi '        kind: shell
        cmd: |
          true

          bash --version >/dev/null'
  tool lanes-empty '        kind: lanes-tool
        ref: empty'
} > "${E}/tools.yaml"

run() { STRW_ROOT="${R}" STRW_TOOLS_NOW=2026-10-28T12:00Z TOOL_PROBE_TIMEOUT="${TO:-5}" bash "${TOOL}" "$@" 2>"${TMP}/err"; }
expect() { # expect <назва> <код> <підрядок stdout> <tool-id> [engine]
    local out rc
    out="$(run "${5:-${E}}" "$4")"; rc=$?
    if [ "${rc}" -eq "$2" ] && printf '%s' "${out}" | grep -qF -- "$3" && [ "$(printf '%s\n' "${out}" | wc -l | tr -d ' ')" -eq 1 ]; then ok "$1"
    else bad "$1" "rc=${rc} (очікувано $2) stdout=[${out}] stderr=[$(cat "${TMP}/err")]"; fi
}
expect2() { # expect2 <назва> <підрядок stderr> <tool-id> [engine] — код 2, stdout порожній
    local out rc
    out="$(run "${4:-${E}}" "$3")"; rc=$?
    if [ "${rc}" -eq 2 ] && [ -z "${out}" ] && grep -qF -- "$2" "${TMP}/err"; then ok "$1"
    else bad "$1" "rc=${rc} stdout=[${out}] stderr=[$(cat "${TMP}/err")]"; fi
}

# --- позитивний і негативний контроль -------------------------------------------------------
expect "позитивний контроль: bash є → available, 0"           0 "real-sh · available · shell (cwd strw-ops)" real-sh
expect "негативний контроль: підроблена проба → unavailable, 3" 3 "fake-sh · unavailable" fake-sh
expect "ненульовий код проби названо"                          3 "→ код 7" exit7
# cwd справді той, що в записі: файл є лише в strw-state
expect "cwd strw-state: файл поруч → available"                 0 "in-state · available · shell (cwd strw-state)" in-state
expect "cwd strw-factory: того файла немає → unavailable"       3 "in-fact · unavailable" in-fact
# теки репо немає (контур без strw-factory) → недоступний, не 2
mkdir -p "${TMP}/bare/strw-state"; cp -R "${E}" "${TMP}/bare/strw-state/"
out="$(STRW_ROOT="${TMP}/bare" STRW_TOOLS_NOW=2026-10-28T12:00Z bash "${TOOL}" "${TMP}/bare/strw-state/engine" in-fact 2>&1)"; rc=$?
if [ "${rc}" -eq 3 ] && printf '%s' "${out}" | grep -qF "немає теки strw-factory"; then ok "немає теки cwd → unavailable з причиною"; else bad "немає теки cwd" "rc=${rc} ${out}"; fi

# --- таймаут: убито всю групу, а не лише bash. Проба живе 30 с, таймаут 1 с. Час — від СТАРТУ САМОЇ проби
# (вона пише свій `date +%s`) до повернення tool-probe.sh: старт bash і python поза виміром, тож межа 5 с не
# залежить від навантаження (стара «≤3 с від виклику» лишала 2 с на старт — чекер р.3 strw-factory #37 мав
# 4 хибні червоні при ~12 паралельних наборах), а таймаут, що ігнорує TOOL_PROBE_TIMEOUT (типові 10 с),
# множить його чи взагалі не вбиває, — червоно; «за 1 с» у виводі — що скрипт узяв саме TOOL_PROBE_TIMEOUT.
# Свідок групи — PID фонового нащадка bash: p.kill() убив би лише bash, а сирота жив би ще 30 с (мутант M5
# 6a-проби); живість — за PID, не за файлом, що з'являється за таймером, тож навантаження не робить свідка сліпим
TO=1 expect "зависла проба → timeout, 3, «за 1 с»" 3 "hang · timeout · shell (cwd strw-ops): проба \`date +%s > ${TMP}/hang-start; sleep 30 & echo \$! > ${TMP}/hang-child.pid; wait\` не завершилась за 1 с" hang; t1=$(date +%s)
t0="$(cat "${TMP}/hang-start" 2>/dev/null)"
if [ -n "${t0}" ] && [ $((t1 - t0)) -le 5 ]; then ok "таймаут обірвав 30-секундну пробу (≤5 с від її старту)"; else bad "таймаут не обірвав пробу вчасно" "старт [${t0}], повернення ${t1}"; fi
child="$(cat "${TMP}/hang-child.pid" 2>/dev/null)"; alive=1
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -n "${child}" ] && ! kill -0 "${child}" 2>/dev/null && { alive=0; break; }; sleep 1
done
if [ -n "${child}" ] && [ "${alive}" -eq 0 ]; then ok "нащадок проби вбитий разом із групою"
else bad "нащадок проби пережив таймаут" "pid=[${child}]"; [ -n "${child}" ] && kill "${child}" 2>/dev/null; fi

# --- lanes-tool -------------------------------------------------------------------------------
expect "lanes-tool: проба з lanes.yaml, bash є → available"     0 "lanes-ok · available · lanes-tool bashv" lanes-ok
expect "lanes-tool: підроблена проба в lanes.yaml → unavailable" 3 "lanes-ghost · unavailable · lanes-tool ghost" lanes-ghost
expect2 "lanes-tool на неіснуючий ключ → 2"                    "lanes-tool 'no-such-key' — немає в lanes.yaml tools" lanes-nokey

# --- session: читається measured, з shell нічого не виконується ------------------------------
expect "session: свіжий вимір available → 0"                    0 "sess-ok · available · сесійний вимір 2026-10-27T09:00Z: available · by local_x" sess-ok
if [ ! -e "${TMP}/session-ran" ]; then ok "session: cmd у записі НЕ виконано"; else bad "session-проба виконала shell" ""; fi
expect "session: needs-auth → 3"                                 3 "sess-auth · needs-auth" sess-auth
expect "session: unavailable → 3"                                3 "sess-off · unavailable" sess-off
expect "session: вимір 27 днів тому → stale, 3"                  3 "sess-old · stale · сесійний вимір 2026-10-01T09:00Z: available — старший за 14 дн." sess-old
expect "session: дата з майбутнього → stale, 3"                  3 "sess-future · stale" sess-future
expect "session: at датою без часу (YAML date) читається"        0 "sess-date · available" sess-date
expect "session: наївний YAML datetime читається як UTC"         0 "sess-naive · available" sess-naive
expect "межа давності: рівно 14 дн. — ще чинний"                 0 "sess-14d · available" sess-14d
expect "межа давності: 14 дн. і хвилина — stale"                3 "sess-14d1m · stale" sess-14d1m
expect "майбутнє в межах години (годинники) — чинний"           0 "sess-soon · available" sess-soon
expect "межа майбутнього: рівно +1 год — ще чинний"              0 "sess-1h · available" sess-1h
expect "межа майбутнього: +1 год і хвилина — stale"              3 "sess-1h1m · stale · сесійний вимір 2026-10-28T13:01Z: available — дата з майбутнього" sess-1h1m
expect "майбутнє +2 год — уже stale (поблажка лише година)"      3 "sess-2h · stale" sess-2h
expect "майбутнє +1 доба (одруківка дати) — stale"              3 "sess-tomorrow · stale · сесійний вимір 2026-10-29T12:00Z: available — дата з майбутнього" sess-tomorrow
expect "багаторядковий cmd: stdout — один рядок, переноси як ⏎" 0 "multi · available · shell (cwd strw-ops): проба \`true ⏎ bash --version >/dev/null\` → код 0" multi
expect2 "lanes-tool з порожньою пробою → 2 (bash -c '' дав би 0)" "lanes-tool 'empty' — немає в lanes.yaml tools або проба порожня" lanes-empty
out="$(STRW_ROOT="${R}" STRW_TOOLS_NOW=2026-10-28T12:00Z TOOL_MEASURED_MAX_AGE_DAYS=30 bash "${TOOL}" "${E}" sess-old 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then ok "межа давності — з TOOL_MEASURED_MAX_AGE_DAYS"; else bad "TOOL_MEASURED_MAX_AGE_DAYS не діє" "rc=${rc} ${out}"; fi

# --- «не поміряти» → 2 ------------------------------------------------------------------------
expect2 "невідомий id → 2"                    "інструмента 'nope' немає" nope
mkdir -p "${TMP}/empty"
expect2 "немає tools.yaml → 2"                "немає ${TMP}/empty/tools.yaml" real-sh "${TMP}/empty"
broken() { # broken <тека> <sed-вираз> — копія фікстури з однією зміною
    mkdir -p "$1"; cp "${E}/lanes.yaml" "$1/"; sed "$2" "${E}/tools.yaml" > "$1/tools.yaml"
}
broken "${TMP}/b1" 's/^schema_version: 1/schema_version: 2/';             expect2 "schema_version 2 → 2" "schema_version не 1" real-sh "${TMP}/b1"
broken "${TMP}/b2" '1,/status: active/s/status: active/status: enabled/';               expect2 "status поза словником → 2" "status 'enabled'" real-sh "${TMP}/b2"
broken "${TMP}/b3" 's/^  - id: fake-sh$/  - id: real-sh/';                expect2 "дубль id → 2" "дубль id real-sh" real-sh "${TMP}/b3"
broken "${TMP}/b4" 's/{at: 2026-10-27T09:00Z, result: needs-auth, by: "local_x"}/{result: needs-auth}/'; expect2 "session без measured.at → 2" "інструмент sess-auth: проба session без measured.at" sess-auth "${TMP}/b4"
broken "${TMP}/b5" 's/{at: 2026-10-27T09:00Z, result: unavailable}/{at: yesterday, result: unavailable}/'; expect2 "measured.at не дата → 2" "measured.at 'yesterday'" sess-off "${TMP}/b5"
broken "${TMP}/b6" '1,/rank: 10/s/rank: 10/rank: high/';                          expect2 "rank не число → 2" "rank 'high'" real-sh "${TMP}/b6"
broken "${TMP}/b7" '1,/cwd: strw-state/s/cwd: strw-state/cwd: pact-ios/';                expect2 "cwd поза словником → 2" "cwd 'pact-ios'" in-state "${TMP}/b7"
broken "${TMP}/b8" '1,/        kind: shell/s/        kind: shell/        kind: http/';        expect2 "kind проби поза словником → 2" "availability.probe.kind поза" real-sh "${TMP}/b8"
broken "${TMP}/b9" 's/^x$/x/'; printf 'schema_version: 1\n' >> "${TMP}/b9/tools.yaml"; expect2 "дубль ключа YAML → 2" "дубльований ключ" real-sh "${TMP}/b9"
broken "${TMP}/b10" '1,/cmd: "bash --version >\/dev\/null"/s/cmd: "bash --version >\/dev\/null"/cmd: "  "/'; expect2 "shell із порожнім cmd → 2 (не «доступний»)" "інструмент real-sh: проба shell без \`cmd\`" real-sh "${TMP}/b10"
broken "${TMP}/b11" '1,/rank: 10/s/rank: 10/rank: true/';                 expect2 "rank: true (bool) → 2" "rank True" real-sh "${TMP}/b11"
broken "${TMP}/b12" '1,/tasks: \[code-build\]/s/tasks: \[code-build\]/tasks: []/'; expect2 "tasks: [] → 2 (запис недосяжний)" "\`tasks\` — непорожній" real-sh "${TMP}/b12"
broken "${TMP}/b13" '1,/contours: \[M\]/s/contours: \[M\]/contours: []/';   expect2 "contours: [] → 2 (запис недосяжний)" "\`contours\` — непорожній" real-sh "${TMP}/b13"
broken "${TMP}/b14" 's/result: unavailable}/result: unavaliable}/';     expect2 "measured.result поза словником → 2" "інструмент sess-off: проба session без measured.at/result" sess-off "${TMP}/b14"
broken "${TMP}/b15" 's/^vocab:$/vocabulary:/';                           expect2 "немає vocab → 2" "немає \`vocab:\`" real-sh "${TMP}/b15"
broken "${TMP}/b16" '/^  kinds:/d';                                      expect2 "немає vocab.kinds → 2" "vocab.kinds" real-sh "${TMP}/b16"
broken "${TMP}/b17" 's/task_types: {code-build: "збірка"}/task_types: code-build/'; expect2 "vocab.task_types рядком → 2 (не словник із літер)" "vocab.task_types — мапа або список рядків" real-sh "${TMP}/b17"
broken "${TMP}/b18" 's/ref: bashv/ref: ""/';                             expect2 "lanes-tool без ref → 2" "проба lanes-tool без \`ref\`" lanes-ok "${TMP}/b18"
broken "${TMP}/b19" '1,/    kind: cli/s/    kind: cli/    kindx: cli/';  expect2 "запис без kind → 2" "немає \`kind\`" real-sh "${TMP}/b19"
broken "${TMP}/b20" 's/contours: \[M, C, I\]/contours: M/';            expect2 "vocab.contours рядком → 2" "vocab.contours — список рядків" real-sh "${TMP}/b20"
broken "${TMP}/b21" 's/session_roles: \[hub, master, child\]/session_roles: hub/'; expect2 "vocab.session_roles рядком → 2" "vocab.session_roles — список рядків" real-sh "${TMP}/b21"
broken "${TMP}/b22" 's/^  - id: exit7$/  - id: ""/';                    expect2 "порожній id → 2" "немає \`id\`" real-sh "${TMP}/b22"
broken "${TMP}/b23" 's/contours: \[M, C, I\]/contours: {M: x, C: y}/';   expect2 "vocab.contours мапою → 2 (мапа лише для task_types)" "vocab.contours — список рядків" real-sh "${TMP}/b23"
broken "${TMP}/b24" 's/session_roles: \[hub, master, child\]/session_roles: [1, 2]/'; expect2 "vocab.session_roles не рядками → 2" "vocab.session_roles — список рядків" real-sh "${TMP}/b24"
broken "${TMP}/b25" '1,/    kind: cli/s/    kind: cli/    kind: CLI/';   expect2 "kind запису поза vocab.kinds → 2 (не тихе випадання з --kind)" "kind 'CLI' поза vocab.kinds" real-sh "${TMP}/b25"
# зламаний ІНШИЙ запис теж зупиняє: реєстр або читається весь, або «не поміряти»
expect2 "зламаний сусідній запис → 2 (fail-closed)" "інструмент sess-auth" real-sh "${TMP}/b4"
expect2 "зламана дата сусіда → 2 ще при читанні, не при пробі" "measured.at 'yesterday'" real-sh "${TMP}/b5"

# --- аргументи --------------------------------------------------------------------------------
out="$(bash "${TOOL}" "${E}" 2>&1)"; rc=$?
if [ "${rc}" -eq 2 ]; then ok "без tool-id → 2"; else bad "без tool-id мав би бути 2" "rc=${rc} ${out}"; fi

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
