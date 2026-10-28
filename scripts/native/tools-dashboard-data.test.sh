#!/usr/bin/env bash
# tools-dashboard-data.test.sh — генератор даних приватного Dashboard реєстру інструментів
# (factory.native-outputs). Golden на фікстурі v1.1: точні числа, порядок за rank і id, межа 14 днів,
# явний перелік полів експорту. Червоні: кожна відмова fail-closed (rc 2, причина, вихідна тека порожня),
# немає читача YAML, дубль ключа. Живий реєстр strw-state — коли він є (інакше SKIP з названою передумовою).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="${HERE}/tools-dashboard-data.py"
FIX="${HERE}/fixtures/tools.v1.yaml"
NOW="2026-10-28T09:00Z"
pass=0; fail=0; NCASE=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tdd-test.XXXXXX")"; trap 'rm -rf "${TMP}"' EXIT
ok()  { pass=$((pass+1)); printf 'PASS · %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL · %s\n%s\n' "$1" "${2:-}"; }

# jq-подібна вибірка без jq: python3 читає JSON і друкує вираз. eval тут свідомо: вирази —
# літерали цього файлу, не дані; JSON читається json.load, не eval.
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

run() { # run <out> <registry> [extra args...] → rc у RC, вивід у OUT
    local out=$1 reg=$2; shift 2
    mkdir -p "${out}"
    OUT="$(python3 "${GEN}" --registry "${reg}" --out "${out}" --now "${NOW}" "$@" 2>&1)"; RC=$?
}

# --- 1. golden на фікстурі ---------------------------------------------------------------------
G="${TMP}/golden"; run "${G}" "${FIX}"
if [ "${RC}" -eq 0 ] && [ -f "${G}/tools.json" ] && [ -f "${G}/tasks.json" ] && [ -f "${G}/summary.json" ]; then
    ok "фікстура → rc 0, три файли"
else bad "фікстура мала дати rc 0 і три файли" "rc=${RC} ${OUT}"; fi

if [ "${RC}" -eq 0 ]; then
    s="$(jget "${G}/summary.json" '"%(tools)s %(active)s %(candidate)s %(forbidden)s %(available)s %(needs_auth)s %(unavailable)s %(unmeasured)s %(stale)s %(task_types)s %(task_types_without_active)s %(schema_version)s" % d[0]')"
    [ "${s}" = "10 7 2 1 7 1 0 2 1 44 37 1" ] && ok "summary: точні числа фікстури" || bad "summary розійшовся" "got: ${s}"
    [ "$(jget "${G}/summary.json" 'len(d)')" = "1" ] && ok "summary — рівно один рядок" || bad "summary не один рядок"
    [ "$(jget "${G}/summary.json" 'd[0]["generated_at"]')" = "${NOW}" ] && ok "generated_at = --now" || bad "generated_at не --now"
    want_sha="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "${FIX}")"
    [ "$(jget "${G}/summary.json" 'd[0]["registry_sha256"]')" = "${want_sha}" ] && ok "registry_sha256 = sha256 вхідного файлу" || bad "registry_sha256 не того файлу"
    [ "$(jget "${G}/tools.json" 'len(d)')" = "10" ] && ok "tools.json: рядків = інструментів (10)" || bad "tools.json загубив рядки"
    [ "$(jget "${G}/tools.json" '",".join(r["id"] for r in d)')" = "codex-cli,claude-cli,pptx-skill,artifact-slides,artifact-dashboard,artifact-docs,figma-mcp,metricool-mcp,simulator,strw-code-reviewer" ] \
        && ok "tools.json — порядок реєстру" || bad "tools.json переставив рядки"
    [ "$(jget "${G}/tasks.json" 'len(d)')" = "44" ] && ok "tasks.json: рядок на кожен task_type (44)" || bad "tasks.json не 44"
    [ "$(jget "${G}/tasks.json" 'd[0]["task"]+"|"+d[-1]["task"]')" = "code-build|automation" ] && ok "tasks.json — порядок словника" || bad "tasks.json не в порядку словника"
    r="$(jget "${G}/tasks.json" '[x for x in d if x["task"]=="code-review-6a"][0]["active_by_rank"]')"
    [ "${r}" = "strw-code-reviewer, claude-cli, codex-cli" ] && ok "active_by_rank: за rank 5·10·20 — не за файлом і не за id" || bad "порядок за rank зламано" "got: ${r}"
    r="$(jget "${G}/tasks.json" '[x for x in d if x["task"]=="deck"][0]["active_by_rank"]')"
    [ "${r}" = "artifact-slides, pptx-skill" ] && ok "рівний rank — за id (у файлі навпаки)" || bad "рівний rank не за id" "got: ${r}"
    r="$(jget "${G}/tasks.json" '"%(active)s %(candidate)s %(forbidden)s" % [x for x in d if x["task"]=="design-system"][0]')"
    [ "${r}" = "0 1 0" ] && ok "design-system: 0 active, 1 candidate (candidate не в active_by_rank)" || bad "лічильник статусів задачі" "got: ${r}"
    r="$(jget "${G}/tasks.json" '[x for x in d if x["task"]=="growth-queue"][0]["active_by_rank"]')"
    [ "${r}" = "" ] && ok "forbidden не потрапляє в active_by_rank" || bad "forbidden у active_by_rank" "got: ${r}"
    r="$(jget "${G}/tools.json" '"%(measured_age_days)s %(stale)s" % [x for x in d if x["id"]=="pptx-skill"][0]')"
    [ "${r}" = "14 False" ] && ok "рівно 14 днів — свіжий" || bad "межа 14 днів" "got: ${r}"
    r="$(jget "${G}/tools.json" '"%(measured_age_days)s %(stale)s" % [x for x in d if x["id"]=="figma-mcp"][0]')"
    [ "${r}" = "15 True" ] && ok "15 днів — застарілий" || bad "15 днів не застарілий" "got: ${r}"
    r="$(jget "${G}/tools.json" '"%(measured_at)s|%(measured_result)s|%(measured_age_days)s|%(stale)s" % [x for x in d if x["id"]=="claude-cli"][0]')"
    [ "${r}" = "|unmeasured|None|False" ] && ok "без measured — «unmeasured», вік порожній" || bad "без measured" "got: ${r}"
    r="$(jget "${G}/tools.json" '[x for x in d if x["id"]=="artifact-docs"][0]["measured_at"]')"
    [ "${r}" = "2026-10-28T00:00Z" ] && ok "дата без часу (YAML date) → північ UTC" || bad "YAML date" "got: ${r}"
    cols="$(jget "${G}/tools.json" '",".join(d[0].keys())')"
    [ "${cols}" = "id,name,kind,status,rank,tasks,roles,loops,contours,provides,probe_kind,measured_at,measured_result,measured_age_days,stale,cost,user_data,enabled_by,why" ] \
        && ok "колонки tools.json — рівно явний перелік" || bad "колонки tools.json" "got: ${cols}"
    if /usr/bin/grep -q NOEXPORT "${G}"/*.json; then bad "cmd/how/by/source просочились у вихід" "$(/usr/bin/grep -o 'NOEXPORT[a-z-]*' "${G}"/*.json | sort -u)"
    else ok "probe.cmd/how, measured.by, source не експортуються"; fi
    # повні рядки: кожна колонка експорту — значенням, не лише назвою (рев'ю #38: user_data/enabled_by обнулювались непомітно)
    r="$(jget "${G}/tools.json" 'json.dumps([x for x in d if x["id"]=="metricool-mcp"][0], ensure_ascii=False, sort_keys=True)')"
    [ "${r}" = '{"contours": "M", "cost": "paid", "enabled_by": "ceo", "id": "metricool-mcp", "kind": "mcp", "loops": "L4-growth", "measured_age_days": 9, "measured_at": "2026-10-19T09:00Z", "measured_result": "available", "name": "Metricool", "probe_kind": "session", "provides": "", "rank": 50, "roles": "strw-growth", "stale": false, "status": "forbidden", "tasks": "growth-queue", "user_data": "reads", "why": "прямий розклад заборонено, лише ForReview"}' ] \
        && ok "рядок metricool-mcp — кожне значення" || bad "рядок metricool-mcp" "got: ${r}"
    r="$(jget "${G}/tools.json" 'json.dumps([x for x in d if x["id"]=="claude-cli"][0], ensure_ascii=False, sort_keys=True)')"
    [ "${r}" = '{"contours": "M, C", "cost": "subscription", "enabled_by": "preinstalled", "id": "claude-cli", "kind": "cli", "loops": "", "measured_age_days": null, "measured_at": "", "measured_result": "unmeasured", "name": "Claude CLI", "probe_kind": "lanes-tool", "provides": "", "rank": 10, "roles": "", "stale": false, "status": "active", "tasks": "code-review-6a, code-build", "user_data": "none", "why": ""}' ] \
        && ok "рядок claude-cli — кожне значення" || bad "рядок claude-cli" "got: ${r}"
    r="$(jget "${G}/tasks.json" 'json.dumps([x for x in d if x["task"]=="code-review-6a"][0], ensure_ascii=False, sort_keys=True)')"
    [ "${r}" = '{"active": 3, "active_by_rank": "strw-code-reviewer, claude-cli, codex-cli", "candidate": 0, "description": "незалежне рев'"'"'ю PR за правилом 6/6a", "forbidden": 0, "task": "code-review-6a"}' ] \
        && ok "рядок задачі code-review-6a — кожне значення" || bad "рядок задачі code-review-6a" "got: ${r}"
    [ "$(jget "${G}/summary.json" 'd[0]["source"]')" = "${FIX}" ] && ok "summary.source без --label — шлях реєстру" || bad "summary.source без --label"
    r="$(jget "${G}/tools.json" '[x for x in d if x["id"]=="figma-mcp"][0]["provides"]')"
    [ "${r}" = "use_figma, get_screenshot" ] && ok "provides — рядком через кому" || bad "provides" "got: ${r}"
fi

# --- 2. детермінізм ----------------------------------------------------------------------------
G2="${TMP}/golden2"; run "${G2}" "${FIX}"
if [ "${RC}" -eq 0 ] && cmp -s "${G}/tools.json" "${G2}/tools.json" && cmp -s "${G}/tasks.json" "${G2}/tasks.json" && cmp -s "${G}/summary.json" "${G2}/summary.json"; then
    ok "два прогони — побайтно рівні"
else bad "вихід недетермінований" "rc=${RC}"; fi

# --- 3. червоні: fail-closed -------------------------------------------------------------------
# mutate <назва> <python-вираз над рядками фікстури як текстом> — підставляє заміну одного рядка
red() { # red <назва> <очікуваний фрагмент причини> <файл реєстру> [extra args]
    local name=$1 want=$2 reg=$3; shift 3
    NCASE=$((NCASE+1)); local out="${TMP}/red-${NCASE}"
    run "${out}" "${reg}" "$@"
    if [ "${RC}" -eq 2 ] && printf '%s' "${OUT}" | /usr/bin/grep -q -- "${want}" && [ -z "$(ls -A "${out}")" ] && ! printf '%s' "${OUT}" | /usr/bin/grep -q Traceback; then
        ok "червоний: ${name} → rc 2, «${want}», тека порожня"
    else bad "червоний: ${name} мав дати rc 2 з «${want}» і порожню теку" "rc=${RC} files=$(ls -A "${out}" | tr '\n' ' ') ${OUT}"; fi
}
sub() { # sub <файл-виходу> <старе> <нове> — заміна ПЕРШОГО входження, доказ, що заміна відбулась
    python3 - "${FIX}" "$1" "$2" "$3" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src, encoding="utf-8").read()
assert old in t, "мутація не накладена: немає " + old
open(dst, "w", encoding="utf-8").write(t.replace(old, new, 1))
PY
}
M="${TMP}/m"; mkdir -p "${M}"
sub "${M}/schema.yaml" "schema_version: 1" "schema_version: 2";                     red "schema_version 2" "schema_version" "${M}/schema.yaml"
sub "${M}/notools.yaml" "tools:" "tools_off:";                                       red "немає tools" "tools" "${M}/notools.yaml"
sub "${M}/novocab.yaml" "vocab:" "vocab_off:";                                       red "немає vocab" "vocab" "${M}/novocab.yaml"
sub "${M}/dupkey.yaml" "    rank: 20
    availability:
      probe: {kind: shell" "    rank: 20
    rank: 5
    availability:
      probe: {kind: shell";                                                                  red "дубль ключа YAML" "дубльований ключ" "${M}/dupkey.yaml"
sub "${M}/dupid.yaml" "  - id: claude-cli" "  - id: codex-cli";                          red "дубль id" "codex-cli" "${M}/dupid.yaml"
sub "${M}/noid.yaml" "  - id: claude-cli" "  - nid: claude-cli";                          red "інструмент без id" "id" "${M}/noid.yaml"
sub "${M}/status.yaml" "    status: forbidden" "    status: banned";                     red "невідомий status" "banned" "${M}/status.yaml"
sub "${M}/nostatus.yaml" "    status: forbidden" "    state: forbidden";                 red "без status" "status" "${M}/nostatus.yaml"
sub "${M}/kind.yaml" "    kind: resource
    name" "    kind: gizmo
    name";                                                                                   red "kind поза vocab.kinds" "gizmo" "${M}/kind.yaml"
sub "${M}/task.yaml" "    tasks: [growth-queue]" "    tasks: [growth-blast]";             red "task поза vocab.task_types" "growth-blast" "${M}/task.yaml"
sub "${M}/notasks.yaml" "    tasks: [growth-queue]" "    tasks: []";                     red "порожній tasks" "tasks" "${M}/notasks.yaml"
sub "${M}/strtasks.yaml" "    tasks: [growth-queue]" "    tasks: growth-queue";          red "tasks рядком, не списком" "tasks" "${M}/strtasks.yaml"
sub "${M}/rank.yaml" "    rank: 50" "    rank: high";                                    red "rank не ціле" "rank" "${M}/rank.yaml"
sub "${M}/rankb.yaml" "    rank: 50" "    rank: true";                                   red "rank bool" "rank" "${M}/rankb.yaml"
sub "${M}/result.yaml" "result: needs-auth" "result: maybe";                             red "measured.result поза словником" "maybe" "${M}/result.yaml"
sub "${M}/at.yaml" "at: 2026-10-13T09:00Z" "at: вчора";                                  red "measured.at не дата" "вчора" "${M}/at.yaml"
sub "${M}/future.yaml" "at: 2026-10-13T09:00Z" "at: 2026-10-29T09:00Z";                  red "measured.at у майбутньому" "майбутньому" "${M}/future.yaml"
red "--now без Z" "--now" "${FIX}" --now "2026-10-28T09:00"
red "--now не дата" "--now" "${FIX}" --now "сьогодні"
red "реєстру немає" "не читається" "${TMP}/nope.yaml"
sub "${M}/idnum.yaml" "  - id: simulator" "  - id: 5";                                    red "id не рядок" "немає id" "${M}/idnum.yaml"
sub "${M}/ttempty.yaml" "  task_types:
" "  task_types: {}
  task_types_off:
";                                                                                          red "порожній vocab.task_types (записи на нього посилаються)" "поза vocab.task_types" "${M}/ttempty.yaml"
sub "${M}/duptask.yaml" "    tasks: [growth-queue]" "    tasks: [growth-queue, growth-queue]"; red "дубль задачі в tasks" "дубль задачі" "${M}/duptask.yaml"
printf -- '- a\n- b\n' > "${M}/toplist.yaml";                                             red "верхній рівень — список" "не мапа" "${M}/toplist.yaml"
sub "${M}/ttlist.yaml" "  task_types:
" "  task_types: [code-build]
  task_types_off:
";                                                                          red "task_types списком" "vocab.task_types" "${M}/ttlist.yaml"
# без записів, що посилаються на словник: відмова саме перевірки словника (рев'ю #38 р.2 — інакше трейсбек)
printf 'schema_version: 1\nvocab: {kinds: [cli], task_types: [code-build]}\ntools: []\n' > "${M}/ttlist0.yaml"; red "task_types списком, tools порожній" "vocab.task_types: немає або не мапа" "${M}/ttlist0.yaml"
sub "${M}/idempty.yaml" "  - id: simulator" "  - id: \"\""; red "порожній id" "немає id" "${M}/idempty.yaml"
printf '  - just-a-string\n' | cat "${FIX}" - > "${M}/toolstr.yaml";                      red "запис tools не мапа" "не мапа" "${M}/toolstr.yaml"
sub "${M}/probe.yaml" "probe: {kind: lanes-tool, ref: simulator}" "probe: {ref: simulator}"; red "без probe.kind" "probe.kind" "${M}/probe.yaml"
sub "${M}/constr.yaml" "constraints: {cost: free, user_data: none, enabled_by: preinstalled}" "constraints: free"; red "constraints не мапа" "constraints" "${M}/constr.yaml"
sub "${M}/meas.yaml" 'measured: {at: 2026-10-19T09:00Z, result: available, by: "fixture"}' "measured: yes"; red "measured не мапа" "measured" "${M}/meas.yaml"
python3 -c 'import sys; open(sys.argv[2],"wb").write(open(sys.argv[1],"rb").read().replace(b"Metricool", b"Metr\xffcool", 1))' "${FIX}" "${M}/badbyte.yaml"; red "нечитний байт (не UTF-8)" "не читається" "${M}/badbyte.yaml"
printf 'schema_version: 1\nvocab: [\n' > "${M}/broken.yaml";                             red "зламаний YAML" "не читається" "${M}/broken.yaml"
# рев'ю codex #38: менша версія схеми, порожній measured, неіснуюча YAML-дата (конструктор кидає ValueError, не YAMLError)
sub "${M}/schema0.yaml" "schema_version: 1" "schema_version: 0";                     red "schema_version 0" "schema_version" "${M}/schema0.yaml"
sub "${M}/measempty.yaml" 'measured: {at: 2026-10-19T09:00Z, result: available, by: "fixture"}' "measured: {}"; red "measured — порожня мапа" "measured.result" "${M}/measempty.yaml"
sub "${M}/feb30.yaml" "at: 2026-10-13T09:00Z" "at: 2026-02-30";                         red "YAML-дата 30 лютого" "не читається" "${M}/feb30.yaml"
sub "${M}/h25.yaml" "at: 2026-10-13T09:00Z" "at: 2026-10-13T25:00:00Z";                 red "YAML-час 25:00" "не читається" "${M}/h25.yaml"

# --- 3b. форми часу measured.at і --now: усі дають той самий вік -------------------------------------
age_of() { # age_of <назва> <заміна рядка at figma-mcp> [очікуваний measured_at] — вік 8, не застарілий
    NCASE=$((NCASE+1)); local out="${TMP}/age-${NCASE}"; mkdir -p "${out}"
    sub "${out}.yaml" "at: 2026-10-13T09:00Z" "at: $2"
    run "${out}" "${out}.yaml"
    local r=""; [ "${RC}" -eq 0 ] && r="$(jget "${out}/tools.json" '"%(measured_age_days)s %(stale)s %(measured_at)s" % [x for x in d if x["id"]=="figma-mcp"][0]')"
    [ "${r}" = "8 False ${3:-2026-10-20T09:00Z}" ] && ok "measured.at $1 → вік 8" || bad "measured.at $1" "rc=${RC} got: ${r} ${OUT}"
}
age_of "YAML-час із секундами і Z (aware)" "2026-10-20T09:00:00Z"
age_of "рядок із секундами" "\"2026-10-20T09:00:00Z\""
age_of "YAML-час без поясу (UTC)" "2026-10-20 09:00:00"
age_of "YAML-час зі зсувом +03:00 (→ UTC)" "2026-10-20T12:00:00+03:00"
age_of "рядок-дата (північ UTC)" "\"2026-10-20\"" "2026-10-20T00:00Z"
age_of "8 діб 23 год — неповна доба відкидається, не округлюється" "2026-10-19T10:00Z" "2026-10-19T10:00Z"
# --label → summary.source; name відсутній → id; задача-підрядок іншої не рахується; unavailable рахується
NCASE=$((NCASE+1)); X="${TMP}/x-${NCASE}"; run "${X}" "${FIX}" --label "strw-state engine/tools.yaml @ abc1234"
[ "${RC}" -eq 0 ] && [ "$(jget "${X}/summary.json" 'd[0]["source"]')" = "strw-state engine/tools.yaml @ abc1234" ] && ok "--label → summary.source" || bad "--label" "rc=${RC} ${OUT}"
NCASE=$((NCASE+1)); X="${TMP}/x-${NCASE}"; mkdir -p "${X}"; sub "${X}.yaml" '    name: "iOS Simulator"
' ""; run "${X}" "${X}.yaml"
[ "${RC}" -eq 0 ] && [ "$(jget "${X}/tools.json" '[x for x in d if x["id"]=="simulator"][0]["name"]')" = "simulator" ] && ok "без name → name = id" || bad "без name" "rc=${RC} ${OUT}"
NCASE=$((NCASE+1)); X="${TMP}/x-${NCASE}"; mkdir -p "${X}"; sub "${X}.yaml" '    code-build: "збірка коду в L3"' '    code-build: "збірка коду в L3"
    code: "підрядок code-build"'; run "${X}" "${X}.yaml"
r=""; [ "${RC}" -eq 0 ] && r="$(jget "${X}/tasks.json" '"%(active)s %(active_by_rank)s" % [x for x in d if x["task"]=="code"][0]')"
[ "${r}" = "0 " ] && ok "задача «code» не збігається з «code-build» підрядком" || bad "підрядок задачі" "rc=${RC} got: ${r}"
# задача з candidate І forbidden: лічильники не плутаються (рев'ю #38: «!= active» рахував заборонених кандидатами)
NCASE=$((NCASE+1)); X="${TMP}/x-${NCASE}"; mkdir -p "${X}"; sub "${X}.yaml" "    tasks: [design-mockup, design-system]" "    tasks: [design-mockup, design-system, growth-queue]"; run "${X}" "${X}.yaml"
r=""; [ "${RC}" -eq 0 ] && r="$(jget "${X}/tasks.json" '"%(active)s %(candidate)s %(forbidden)s" % [x for x in d if x["task"]=="growth-queue"][0]')"
[ "${r}" = "0 1 1" ] && ok "growth-queue: 1 candidate і 1 forbidden — окремо" || bad "candidate проти forbidden" "rc=${RC} got: ${r}"
# межа застарілості в секундах: 14 діб і 1 год — застарілий; застарілий forbidden теж рахується
NCASE=$((NCASE+1)); X="${TMP}/x-${NCASE}"; mkdir -p "${X}"; sub "${X}.yaml" "at: 2026-10-13T09:00Z" "at: 2026-10-14T08:00Z"; run "${X}" "${X}.yaml"
r=""; [ "${RC}" -eq 0 ] && r="$(jget "${X}/tools.json" '"%(measured_age_days)s %(stale)s" % [x for x in d if x["id"]=="figma-mcp"][0]')"
[ "${r}" = "14 True" ] && ok "14 діб і 1 год — застарілий" || bad "межа в секундах" "rc=${RC} got: ${r}"
NCASE=$((NCASE+1)); X="${TMP}/x-${NCASE}"; mkdir -p "${X}"; sub "${X}.yaml" "at: 2026-10-19T09:00Z" "at: 2026-10-01T09:00Z"; run "${X}" "${X}.yaml"
r=""; [ "${RC}" -eq 0 ] && r="$(jget "${X}/summary.json" 'd[0]["stale"]')"
[ "${r}" = "2" ] && ok "застарілий forbidden рахується в summary.stale" || bad "stale forbidden" "rc=${RC} got: ${r}"
# без constraints → порожні значення, не вигадане «none»
NCASE=$((NCASE+1)); X="${TMP}/x-${NCASE}"; mkdir -p "${X}"; sub "${X}.yaml" "    constraints: {cost: free, user_data: none, enabled_by: preinstalled}
" ""; run "${X}" "${X}.yaml"
r=""; [ "${RC}" -eq 0 ] && r="$(jget "${X}/tools.json" '"[%(cost)s|%(user_data)s|%(enabled_by)s]" % [x for x in d if x["id"]=="simulator"][0]')"
[ "${r}" = "[||]" ] && ok "без constraints — порожні, не «none»" || bad "без constraints" "rc=${RC} got: ${r}"
NCASE=$((NCASE+1)); X="${TMP}/x-${NCASE}"; mkdir -p "${X}"; sub "${X}.yaml" "result: needs-auth" "result: unavailable"; run "${X}" "${X}.yaml"
r=""; [ "${RC}" -eq 0 ] && r="$(jget "${X}/summary.json" '"%(unavailable)s %(needs_auth)s %(available)s" % d[0]')"
[ "${r}" = "1 0 7" ] && ok "unavailable рахується окремо від needs-auth" || bad "лічильник unavailable" "rc=${RC} got: ${r}"
S="${TMP}/now-sec"; run "${S}" "${FIX}" --now "2026-10-28T09:00:00Z"
if [ "${RC}" -eq 0 ] && cmp -s "${G}/tools.json" "${S}/tools.json"; then ok "--now із секундами = без секунд"; else bad "--now із секундами" "rc=${RC} ${OUT}"; fi
: > "${TMP}/a-file"
OUT="$(python3 "${GEN}" --registry "${FIX}" --out "${TMP}/a-file" --now "${NOW}" 2>&1)"; RC=$?
if [ "${RC}" -eq 2 ] && printf '%s' "${OUT}" | /usr/bin/grep -q -- "не порожня тека" && ! printf '%s' "${OUT}" | /usr/bin/grep -q Traceback; then ok "червоний: --out — файл, не тека → rc 2 «не порожня тека»"
else bad "червоний: --out не тека" "rc=${RC} ${OUT}"; fi
# тека з попереднього прогону: відмова не лишає старих файлів, які можна прийняти за нові
NCASE=$((NCASE+1)); X="${TMP}/x-${NCASE}"; mkdir -p "${X}"; printf '[]\n' > "${X}/summary.json"
OUT="$(python3 "${GEN}" --registry "${FIX}" --out "${X}" --now "${NOW}" 2>&1)"; RC=$?
if [ "${RC}" -eq 2 ] && printf '%s' "${OUT}" | /usr/bin/grep -q -- "не порожня тека" && [ "$(cat "${X}/summary.json")" = "[]" ]; then ok "червоний: --out не порожня → rc 2, чужих файлів не чіпає"
else bad "червоний: --out не порожня" "rc=${RC} ${OUT}"; fi

# --- 4. немає читача YAML без дублікатів → rc 2 з назвою, без трейсбека --------------------------
NL="${TMP}/nolib/scripts/native"; mkdir -p "${NL}" "${TMP}/nolib-out"
cp "${GEN}" "${NL}/"
out="$(cd "${TMP}" && env -u STRW_ENGINE_LIB STRW_ROOT=/nonexistent python3 "${NL}/tools-dashboard-data.py" --registry "${FIX}" --out "${TMP}/nolib-out" --now "${NOW}" 2>&1)"; rc=$?
if [ "${rc}" -eq 2 ] && printf '%s' "${out}" | /usr/bin/grep -q yaml_nodup.py && ! printf '%s' "${out}" | /usr/bin/grep -q Traceback; then
    ok "без lib/yaml_nodup.py → rc 2, називає читача"
else bad "без читача мав бути rc 2 з назвою" "rc=${rc} ${out}"; fi
# контроль: та сама копія з STRW_ENGINE_LIB → читач знайдено
out="$(cd "${TMP}" && STRW_ENGINE_LIB="${HERE}/../engine/lib" STRW_ROOT=/nonexistent python3 "${NL}/tools-dashboard-data.py" --registry "${FIX}" --out "${TMP}/nolib-out" --now "${NOW}" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "контроль: STRW_ENGINE_LIB → читач знайдено, rc 0" || bad "STRW_ENGINE_LIB не знайшов читача" "rc=${rc} ${out}"
# підроблений yaml_nodup.py у cwd не імпортується
mkdir -p "${TMP}/evil"; printf 'raise SystemExit("EVIL-IMPORT")\n' > "${TMP}/evil/yaml_nodup.py"
out="$(cd "${TMP}/evil" && env -u STRW_ENGINE_LIB STRW_ROOT=/nonexistent python3 "${NL}/tools-dashboard-data.py" --registry "${FIX}" --out "${TMP}/nolib-out" --now "${NOW}" 2>&1)"; rc=$?
if printf '%s' "${out}" | /usr/bin/grep -q EVIL-IMPORT; then bad "yaml_nodup.py з cwd імпортовано" "${out}"; else ok "yaml_nodup.py з cwd не імпортується"; fi

# --- 5. живий реєстр strw-state ----------------------------------------------------------------
LIVE="${STRW_ROOT:-${HOME}/Developer/STRW}/strw-state/engine/tools.yaml"
if [ -f "${LIVE}" ]; then
    L="${TMP}/live"; mkdir -p "${L}"
    out="$(python3 "${GEN}" --registry "${LIVE}" --out "${L}" --now "$(date -u +%Y-%m-%dT%H:%MZ)" 2>&1)"; rc=$?
    if [ "${rc}" -eq 0 ]; then
        n_in="$(python3 -c 'import yaml,sys; print(len(yaml.safe_load(open(sys.argv[1]))["tools"]))' "${LIVE}")"
        [ "$(jget "${L}/tools.json" 'len(d)')" = "${n_in}" ] && ok "живий tools.yaml → rc 0, рядків = записів (${n_in})" || bad "живий: рядків не стільки, скільки записів"
    else bad "живий tools.yaml мав читатися генератором" "rc=${rc} ${out}"; fi
else
    printf 'SKIP · живий реєстр: немає %s (factory.tool-registry не злито або пісочниця без strw-state)\n' "${LIVE}"
fi

printf '\n%d PASS · %d FAIL\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
