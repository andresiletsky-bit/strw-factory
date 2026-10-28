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
Y
tool() { # tool <id> <probe-yaml-рядки> [measured-рядок]
    printf '  - id: %s\n    kind: cli\n    name: "%s"\n    tasks: [code-build]\n    roles: []\n    loops: []\n    contours: [M]\n    status: active\n    rank: 10\n    availability:\n      probe:\n%s\n' "$1" "$1" "$2"
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
        cmd: \"sleep 3; touch ${TMP}/survivor\""
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
        how: "mcp__x"' '{at: 2026-10-27T09:00Z, result: needs-auth, by: "local_x"}'
  tool sess-off '        kind: session
        how: "mcp__x"' '{at: 2026-10-27T09:00Z, result: unavailable}'
  tool sess-old '        kind: session
        how: "mcp__x"' '{at: 2026-10-01T09:00Z, result: available}'
  tool sess-future '        kind: session
        how: "mcp__x"' '{at: 2026-11-30T09:00Z, result: available}'
  tool sess-date '        kind: session
        how: "mcp__x"' '{at: 2026-10-27, result: available}'
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

# --- таймаут: убито всю групу, а не лише bash ------------------------------------------------
t0=$(date +%s); TO=1 expect "зависла проба → timeout, 3" 3 "hang · timeout · shell (cwd strw-ops): проба" hang; t1=$(date +%s)
if [ $((t1 - t0)) -le 3 ]; then ok "таймаут спрацював за ≤3 с"; else bad "таймаут не спрацював вчасно" "$((t1 - t0)) с"; fi
sleep 3
if [ ! -e "${TMP}/survivor" ]; then ok "нащадок проби вбитий разом із групою"; else bad "нащадок проби пережив таймаут" ""; fi

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
# зламаний ІНШИЙ запис теж зупиняє: реєстр або читається весь, або «не поміряти»
expect2 "зламаний сусідній запис → 2 (fail-closed)" "інструмент sess-auth" real-sh "${TMP}/b4"

# --- аргументи --------------------------------------------------------------------------------
out="$(bash "${TOOL}" "${E}" 2>&1)"; rc=$?
if [ "${rc}" -eq 2 ]; then ok "без tool-id → 2"; else bad "без tool-id мав би бути 2" "rc=${rc} ${out}"; fi

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
