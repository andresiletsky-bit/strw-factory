#!/usr/bin/env bash
# tool-select.test.sh — підбір інструмента під (тип задачі, роль, контур) і його ПРОВОДКА
# (factory.tool-select, слова CEO 28.10). Фікстури — схема v1 (нотатка майстра 28.10).
#
# Логіка: ранжування (доступні → active → rank → id), недоступний не обирається навіть із
# найменшим rank, forbidden ніколи в stdout і навіть не пробується, candidate видно, але не
# обрано, невідомий тип задачі/роль/контур → 2 зі ПОРОЖНІМ stdout, задачі без запису → 4.
#
# Проводка — пін на ДОСЯЖНІСТЬ, не на слово: з кожного місця, де фабрика обирає інструмент
# (WIRED нижче), береться рядок виклику ДОСЛІВНО, підставляються лише ${CLAUDE_PLUGIN_ROOT},
# strw-state/engine і <контур>, і він ВИКОНУЄТЬСЯ на фікстурі — код 0/3/4, не 2 і не 127.
# Прибрати виклик, зламати аргументи, вписати тип задачі поза словником → червоно. Зворотне
# покриття: файл skills/ loops/ agents/, що кличе tool-select.sh, а в WIRED його немає, — червоно.
# Свідомо НЕ проведено (вибору немає): L4 — канал Metricool фіксований рішенням CEO, а
# підключення міряє живий `claude mcp get metricool` (п. 5); L7/L8 — інструменти названі
# поіменно (скіл strw-design-sync, bin/regression-phase1.sh).
# Живий прогін: коли strw-state/engine/tools.yaml є (після мержу factory.tool-registry), кожен
# виклик проводки ганяється й на ньому — тип задачі й роль мусять бути в живому словнику;
# немає файла — SKIP із названою передумовою.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORY="$(cd "${HERE}/../.." && pwd)"
TOOL="${HERE}/tool-select.sh"
pass=0; fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
ok()  { pass=$((pass+1)); printf 'PASS · %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL · %s\n%s\n' "$1" "${2:-}"; }

R="${TMP}/root"; E="${R}/strw-state/engine"; mkdir -p "${E}" "${R}/strw-factory"
printf 'schema_version: 1\ntools: {}\n' > "${E}/lanes.yaml"
A="${TMP}/agents"; mkdir -p "${A}/validators"
printf -- '---\nname: strw-code-reviewer\nmodel: sonnet\n---\nтіло\n' > "${A}/validators/code-reviewer.md"
printf -- '---\nname: "strw-engineer"\n---\n' > "${A}/engineer.md"
printf 'нотатка\nname: strw-not-frontmatter\n' > "${A}/notes.md"
tool() { # tool <id> <status> <rank> <tasks> <roles> <loops> <contours> <probe-рядки> [measured]
    printf '  - id: %s\n    kind: cli\n    name: "%s"\n    tasks: [%s]\n    roles: [%s]\n    loops: [%s]\n    contours: [%s]\n    status: %s\n    rank: %s\n' "$1" "$1" "$4" "$5" "$6" "$7" "$2" "$3"
    [ "$2" = active ] || printf '    why: "фікстура: %s"\n' "$2"
    printf '    availability:\n      probe:\n%s\n' "$8"
    [ -n "${9:-}" ] && printf '      measured: %s\n' "$9"
    printf '    constraints: {cost: free, user_data: none, enabled_by: preinstalled}\n    source: "фікстура"\n'
}
sh_on() { printf '        kind: shell\n        cmd: "test -f on-%s"' "$1"; }
sh_touch() { printf '        kind: shell\n        cmd: "touch %s/%s-probed"' "${TMP}" "$1"; }
{
  printf 'schema_version: 1\nvocab:\n  kinds: [cli]\n  task_types:\n'
  printf '    code-review-6a: "рев'"'"'ю 6a"\n    code-rescue: "другий погляд"\n    growth-queue: "черга"\n    deck: "колода"\n    tie-task: "рівні"\n'
  printf '  session_roles: [hub, master, child]\n  contours: [M, C, I]\ntools:\n'
  tool codex       active    20 "code-review-6a, code-rescue" "strw-code-reviewer, strw-engineer" "L3-build" "M"    "$(sh_on codex)"
  tool claude-p    active    30 "code-review-6a" "" "" "M, C"                                                         "$(sh_on claude)"
  tool broken      active    10 "code-review-6a" "" "" "M"                                                            '        kind: shell
        cmd: "exit 1"'
  tool forbidden-x forbidden  1 "code-review-6a" "" "" "M, C, I"                                                      "$(sh_touch forbidden)"
  tool cand        candidate  5 "code-review-6a" "" "" "M"                                                            '        kind: shell
        cmd: "true"'
  tool mcp-auth    active    15 "code-review-6a" "" "" "M"                                                            '        kind: session
        how: "mcp__x"' '{at: 2026-10-27T09:00Z, result: needs-auth}'
  tool mcp-old     active    16 "code-review-6a" "" "" "M"                                                            '        kind: session
        how: "mcp__y"' '{at: 2026-10-01T09:00Z, result: available}'
  tool i-only      active     2 "code-review-6a" "" "" "I"                                                            "$(sh_touch ionly)"
  tool other       active     1 "growth-queue" "" "" "M"                                                              "$(sh_touch other)"
  tool tie-b       active    50 "tie-task" "" "" "M"                                                                  '        kind: shell
        cmd: "true"'
  tool tie-a       active    50 "tie-task" "" "" "M"                                                                  '        kind: shell
        cmd: "true"'
} > "${E}/tools.yaml"
touch "${R}/on-codex" "${R}/on-claude"

run() { STRW_ROOT="${R}" STRW_AGENTS_DIR="${AG:-${A}}" STRW_TOOLS_NOW=2026-10-28T12:00Z TOOL_PROBE_TIMEOUT=5 bash "${TOOL}" "$@" >"${TMP}/out" 2>"${TMP}/err"; }
ids() { sed -n '2,$p' "${TMP}/out" | sed 's/^[0-9]*\. \([^ ]*\) .*/\1/' | tr '\n' ' '; }
show() { printf 'rc=%s\nstdout:\n%s\nstderr:\n%s' "$1" "$(cat "${TMP}/out")" "$(cat "${TMP}/err")"; }

# --- 1. повний набір: недоступний із меншим rank не обрано, forbidden не видно ----------------
run "${E}" code-review-6a strw-code-reviewer M --loop L3-build; rc=$?
if [ "${rc}" -eq 0 ] && head -1 "${TMP}/out" | grep -qF "обрано: codex (codex) · задача code-review-6a · роль strw-code-reviewer · контур M · петля L3-build · rank 20 · shell (cwd strw-ops): проба \`test -f on-codex\` → код 0"; then ok "обрано: доступний active з найменшим rank серед доступних"; else bad "вердикт обрано" "$(show ${rc})"; fi
if [ "$(ids)" = "codex claude-p cand broken mcp-auth mcp-old " ]; then ok "порядок: доступні → active → rank (недоступні внизу)"; else bad "порядок" "[$(ids)]"; fi
if grep -q '^4\. broken · НЕДОСТУПНИЙ (unavailable) · active · rank 10' "${TMP}/out"; then ok "broken (rank 10) — НЕДОСТУПНИЙ, не обрано"; else bad "broken мав бути НЕДОСТУПНИЙ" "$(show ${rc})"; fi
if grep -q '^5\. mcp-auth · НЕДОСТУПНИЙ (needs-auth)' "${TMP}/out" && grep -q '^6\. mcp-old · НЕДОСТУПНИЙ (stale)' "${TMP}/out"; then ok "сесійні needs-auth і протухлий — НЕДОСТУПНІ"; else bad "сесійні виміри" "$(show ${rc})"; fi
if grep -q '^2\. claude-p · резерв · active' "${TMP}/out" && grep -q '^3\. cand · кандидат, не ввімкнено — фікстура: candidate · candidate · rank 5' "${TMP}/out"; then ok "резерв і кандидат позначені (кандидат не обрано попри rank 5)"; else bad "резерв/кандидат" "$(show ${rc})"; fi
if grep -q 'cost free · user_data none$' "${TMP}/out"; then ok "обмеження cost/user_data у рядку"; else bad "обмеження" "$(show ${rc})"; fi
if ! grep -q 'forbidden-x' "${TMP}/out" && grep -qF 'відкинуто forbidden-x: forbidden — фікстура: forbidden' "${TMP}/err"; then ok "forbidden: не в stdout, відкинуто в stderr з why"; else bad "forbidden" "$(show ${rc})"; fi
if [ ! -e "${TMP}/forbidden-probed" ] && [ ! -e "${TMP}/ionly-probed" ] && [ ! -e "${TMP}/other-probed" ]; then ok "forbidden, чужий контур і чужа задача навіть не пробуються"; else bad "пробувались зайві" "$(ls "${TMP}")"; fi
if grep -qF 'відкинуто i-only: контур M поза [I]' "${TMP}/err"; then ok "чужий контур відкинуто з причиною"; else bad "контур" "$(show ${rc})"; fi

# --- 2. петля, роль, контур звужують --------------------------------------------------------
run "${E}" code-review-6a strw-code-reviewer M; rc=$?
if [ "${rc}" -eq 0 ] && head -1 "${TMP}/out" | grep -q '^обрано: claude-p ' && grep -qF 'відкинуто codex: петля — поза [L3-build]' "${TMP}/err"; then ok "без --loop запис із петлями не пропонується"; else bad "без --loop" "$(show ${rc})"; fi
run "${E}" code-review-6a hub M --loop L3-build; rc=$?
if [ "${rc}" -eq 0 ] && head -1 "${TMP}/out" | grep -q '^обрано: claude-p ' && grep -qF 'відкинуто codex: роль hub поза [strw-code-reviewer, strw-engineer]' "${TMP}/err"; then ok "роль сесії hub: запис із ролями-агентами відкинуто"; else bad "роль hub" "$(show ${rc})"; fi
run "${E}" code-review-6a strw-code-reviewer C --loop L3-build; rc=$?
if [ "${rc}" -eq 0 ] && head -1 "${TMP}/out" | grep -q '^обрано: claude-p ' && [ "$(ids)" = "claude-p " ]; then ok "контур C: лише записи з C"; else bad "контур C" "$(show ${rc})"; fi

# --- 3. доступність перемикає вибір --------------------------------------------------------
rm -f "${R}/on-codex"
run "${E}" code-review-6a strw-code-reviewer M --loop L3-build; rc=$?
if [ "${rc}" -eq 0 ] && head -1 "${TMP}/out" | grep -q '^обрано: claude-p ' && grep -q '^[0-9]\. codex · НЕДОСТУПНИЙ (unavailable)' "${TMP}/out"; then ok "codex зник → обрано claude-p, codex НЕДОСТУПНИЙ"; else bad "codex зник" "$(show ${rc})"; fi
rm -f "${R}/on-claude"
run "${E}" code-review-6a strw-code-reviewer M --loop L3-build; rc=$?
if [ "${rc}" -eq 3 ] && head -1 "${TMP}/out" | grep -qF 'немає доступного: 6 кандидат(ів) · задача code-review-6a' && head -1 "${TMP}/out" | grep -qF 'cand — candidate, не ввімкнено' && ! grep -q 'обрано' "${TMP}/out"; then ok "жоден active не доступний → 3, кандидат не обрано"; else bad "немає доступного" "$(show ${rc})"; fi
touch "${R}/on-codex" "${R}/on-claude"

# --- 4. порожньо, невідомо, рівні -----------------------------------------------------------
run "${E}" deck child M; rc=$?
if [ "${rc}" -eq 4 ] && [ "$(cat "${TMP}/out")" = "немає інструмента в реєстрі: задача deck · роль child · контур M" ]; then ok "задача без записів → 4"; else bad "задача без записів" "$(show ${rc})"; fi
for c in "code-reveiw strw-code-reviewer M:невідомий тип задачі 'code-reveiw'" "code-review-6a strw-nobody M:невідома роль 'strw-nobody'" "code-review-6a hub X:невідомий контур 'X'"; do
    set -- ${c%%:*}; run "${E}" "$@"; rc=$?
    if [ "${rc}" -eq 2 ] && [ ! -s "${TMP}/out" ] && grep -qF "${c#*:}" "${TMP}/err"; then ok "${c#*:} → 2, stdout порожній"; else bad "${c#*:}" "$(show ${rc})"; fi
done
AG="${TMP}/no-agents" run "${E}" code-review-6a strw-code-reviewer M --loop L3-build; rc=$?
if [ "${rc}" -eq 2 ] && grep -qF 'agents/ плагіна не знайдено' "${TMP}/err"; then ok "без agents/ роль-агент невідома → 2 з підказкою"; else bad "без agents/" "$(show ${rc})"; fi
run "${E}" code-review-6a strw-nobody M; rc=$?
if [ "${rc}" -eq 2 ] && grep -qF "strw-code-reviewer, strw-engineer" "${TMP}/err" && ! grep -qF "strw-not-frontmatter" "${TMP}/err"; then ok "словник ролей: агенти з frontmatter, name: поза ним — не роль"; else bad "name: поза frontmatter не має ставати роллю" "$(show ${rc})"; fi
out="$(STRW_ROOT="${R}" STRW_TOOLS_NOW=2026-10-28T12:00Z env -u STRW_AGENTS_DIR bash "${TOOL}" "${E}" code-review-6a strw-code-reviewer M --loop L3-build 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then ok "типово agents/ — цього плагіна (strw-code-reviewer відомий)"; else bad "типова тека agents/" "rc=${rc} ${out}"; fi
run "${E}" tie-task child M; rc=$?
if [ "${rc}" -eq 0 ] && [ "$(ids)" = "tie-a tie-b " ]; then ok "рівний rank → за id"; else bad "рівний rank" "$(show ${rc})"; fi
for a in "${E} deck child" "${E} deck child M --lop L3" "${E} deck child M --loop"; do
    run ${a}; rc=$?
    if [ "${rc}" -eq 2 ] && [ ! -s "${TMP}/out" ]; then ok "аргументи «${a#${E} }» → 2"; else bad "аргументи «${a#${E} }»" "$(show ${rc})"; fi
done

# --- 5. проводка: виклик із паспорта ВИКОНУЄТЬСЯ ----------------------------------------------
# файл | тип задачі | роль | петля | контури, якими підставляється <контур>
WIRED="loops/L3-build.md|code-review-6a|strw-code-reviewer|L3-build|M
agents/engineer.md|code-rescue|strw-engineer|L3-build|M C"
# Живий двійник фікстури: та сама проводка мусить проходити й на живому реєстрі.
LIVE="${STRW_ROOT:-$HOME/Developer/STRW}/strw-state/engine"
WIRE_OUT="$(STRW_ROOT="${R}" STRW_TOOLS_NOW=2026-10-28T12:00Z WIRED="${WIRED}" LIVE="${LIVE}" FIXTURE="${E}" FACTORY="${FACTORY}" python3 - <<'PY'
import os, re, shlex, subprocess, glob
F, wired = os.environ["FACTORY"], [l.split("|") for l in os.environ["WIRED"].splitlines() if l.strip()]
CALL = re.compile(r'`(bash "\$\{CLAUDE_PLUGIN_ROOT\}/scripts/engine/tool-select\.sh"[^`]*)`')
def say(ok, msg, det=""):
    print(("PASS · " if ok else "FAIL · ") + msg + ("" if ok else "\n" + det))
def run(cmd, engine, contour, env_extra):
    cmd = cmd.replace("${CLAUDE_PLUGIN_ROOT}", F).replace("<контур>", contour)
    argv = shlex.split(cmd)
    argv = [engine if a == "strw-state/engine" else a for a in argv]
    env = dict(os.environ, **env_extra)
    p = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env, timeout=120)
    return p.returncode, p.stdout, p.stderr
# зворотне покриття: хто кличе tool-select.sh — той у WIRED (SKILL — окремий контракт нижче)
callers = set()
for p in glob.glob(os.path.join(F, "loops", "*.md")) + glob.glob(os.path.join(F, "agents", "**", "*.md"), recursive=True) \
        + glob.glob(os.path.join(F, "skills", "*", "SKILL.md")):
    if "scripts/engine/tool-select.sh" in open(p, encoding="utf-8").read():
        callers.add(os.path.relpath(p, F))
listed = {w[0] for w in wired} | {"skills/strw-loop-run/SKILL.md"}
say(callers == listed, f"зворотне покриття: виклики tool-select.sh = WIRED ∪ SKILL ({len(callers)})",
    f"кличуть: {sorted(callers)}; у WIRED: {sorted(listed)}")
for path, task, role, loop, contours in wired:
    txt = open(os.path.join(F, path), encoding="utf-8").read()
    calls = CALL.findall(txt)
    if len(calls) != 1:
        say(False, f"{path}: рівно один виклик tool-select.sh", f"знайдено {len(calls)}"); continue
    argv = shlex.split(calls[0])
    want = ["strw-state/engine", task, role]
    say(argv[2:5] == want and argv[-2:] == ["--loop", loop], f"{path}: виклик — {task} · {role} · --loop {loop}", f"{argv}")
    if path.startswith("loops/"):
        m = re.search(r"^id:\s*(\S+)", txt, re.M)
        say(bool(m) and m.group(1) == loop, f"{path}: --loop = id паспорта", f"id {m and m.group(1)}")
    for c in contours.split():
        rc, out, err = run(calls[0], os.environ["FIXTURE"], c, {"STRW_AGENTS_DIR": os.path.join(F, "agents")})
        say(rc in (0, 3, 4) and out.strip(), f"{path} (контур {c}): виклик дослівно виконується на фікстурі → {rc}", f"rc={rc}\n{out}\n{err}")
    live = os.environ["LIVE"]
    if os.path.isfile(os.path.join(live, "tools.yaml")):
        for c in contours.split():
            rc, out, err = run(calls[0], live, c, {"STRW_ROOT": os.path.dirname(os.path.dirname(live)), "STRW_TOOLS_NOW": ""})
            say(rc in (0, 3, 4), f"{path} (контур {c}): живий реєстр знає тип задачі й роль → {rc}", f"rc={rc}\n{out}\n{err}")
    else:
        print(f"SKIP · {path}: немає {live}/tools.yaml — живий прогін після мержу factory.tool-registry")
# SKILL Step 3a: шаблон виклику з ${CLAUDE_PLUGIN_ROOT} і чотири коди — словами, якими їх друкує скрипт
sk = [l for l in open(os.path.join(F, "skills/strw-loop-run/SKILL.md"), encoding="utf-8").read().split("\n")
      if "scripts/engine/tool-select.sh" in l]
say(len(sk) == 1 and '`bash "${CLAUDE_PLUGIN_ROOT}/scripts/engine/tool-select.sh" strw-state/engine <тип-задачі> <роль> <контур> --loop <петля>`' in sk[0],
    "SKILL Step 3a: шаблон виклику від ${CLAUDE_PLUGIN_ROOT}", f"{sk}")
for code, words in (("0", "обрано"), ("3", "немає доступного"), ("4", "немає інструмента в реєстрі"), ("2", "не поміряти")):
    say(bool(sk) and f"{code} «{words}»" in sk[0], f"SKILL Step 3a називає код {code} «{words}»")
PY
)"
printf '%s\n' "${WIRE_OUT}"
pass=$((pass + $(printf '%s\n' "${WIRE_OUT}" | grep -c '^PASS'))); fail=$((fail + $(printf '%s\n' "${WIRE_OUT}" | grep -c '^FAIL')))
# слова кодів SKILL — це справді початки вердиктів скрипта (виміряно прогонами вище)
for w in "обрано: " "немає доступного: " "немає інструмента в реєстрі: "; do
    case "${w}" in "обрано: ") run "${E}" code-review-6a strw-code-reviewer M --loop L3-build ;; "немає інструмента в реєстрі: ") run "${E}" deck child M ;;
        *) rm -f "${R}/on-codex" "${R}/on-claude"; run "${E}" code-review-6a strw-code-reviewer M --loop L3-build; touch "${R}/on-codex" "${R}/on-claude" ;; esac
    if head -1 "${TMP}/out" | grep -q "^${w}"; then ok "вердикт скрипта починається «${w% }»"; else bad "вердикт «${w% }»" "$(cat "${TMP}/out")"; fi
done

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
