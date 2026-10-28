#!/usr/bin/env bash
# hub-dashboard-data.test.sh — генератор даних приватного Dashboard хаба (factory.hub-dashboard) і обгортка
# оновлення. Golden на фікстурі fixtures/hub: точні числа summary, порядок і повні рядки таблиць, межі
# (24 год простою, 7 днів без оновлення PR, строк картки сьогодні). Детермінізм: два прогони побайтно рівні,
# --gh і --prs-dir з того самого знімка — теж. Досяжність: кожне з чотирьох джерел прибрано або підмінено
# окремо — відмова або зміна виходу; gh кличеться для кожного з п'яти репо. Червоні: кожна відмова fail-closed
# (rc 2, причина, hub.json немає). Обгортка: знімок origin/main, не робоче дерево спільної копії.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="${HERE}/hub-dashboard-data.py"
REFRESH="${HERE}/hub-dashboard-refresh.sh"
FX="${HERE}/fixtures/hub"
NOW="2026-10-28T09:00Z"
REPOS="strw-ops strw-factory strw-state pact-ios pact-backend"
pass=0; fail=0; NCASE=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hdd-test.XXXXXX")"; trap 'rm -rf "${TMP}"' EXIT
ok()  { pass=$((pass+1)); printf 'PASS · %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL · %s\n%s\n' "$1" "${2:-}"; }

# jq-подібна вибірка: eval лише літералів цього файлу; JSON читає json.load. T(name) — рядки таблиці.
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); T=lambda n: [r for r in d if r["table"]==n]; print(eval(sys.argv[2]))' "$1" "$2"; }

# копія фікстури, яку червоні випадки псують, не чіпаючи оригінал
fx_copy() { rm -rf "$1"; cp -R "${FX}" "$1"; }

run() { # run <out> <fixture-root> [extra args...] → RC, OUT; без --gh у extra береться <root>/prs
    local out=$1 root=$2; shift 2
    mkdir -p "${out}"
    local src=(--prs-dir "${root}/prs")
    case " $* " in *" --gh "*) src=();; esac
    OUT="$(python3 "${GEN}" --state "${root}/state" --sessions "${root}/sessions.json" "${src[@]+"${src[@]}"}" \
        --out "${out}" --now "${NOW}" "$@" 2>&1 < /dev/null)"; RC=$?
}

# --- 1. golden на фікстурі ---------------------------------------------------------------------
G="${TMP}/golden"; run "${G}" "${FX}"
if [ "${RC}" -eq 0 ] && [ -f "${G}/hub.json" ] && [ "$(ls -A "${G}")" = "hub.json" ]; then ok "фікстура → rc 0, рівно hub.json"
else bad "фікстура мала дати rc 0 і hub.json" "rc=${RC} files=$(ls -A "${G}" | tr '\n' ' ') ${OUT}"; fi

if [ "${RC}" -eq 0 ]; then
    s="$(jget "${G}/hub.json" '" ".join(str(T("summary")[0][k]) for k in ("sessions","sessions_running","sessions_idle_24h","sessions_pr_open","sessions_archived_skipped","prs_open","prs_draft","prs_checks_fail","prs_checks_pending","prs_stale_7d","triage_open","triage_overdue","triage_question","triage_finding","triage_error","triage_other","items","items_ready","items_running","items_blocked","items_done","items_parked","items_other","items_on_ceo","lanes"))')"
    [ "${s}" = "4 2 2 1 1 6 1 2 1 1 3 1 1 1 1 0 6 1 1 2 1 0 1 1 2" ] && ok "summary: точні числа фікстури" || bad "summary розійшовся" "got: ${s}"
    [ "$(jget "${G}/hub.json" 'len(T("summary"))')" = "1" ] && ok "summary — рівно один рядок" || bad "summary не один"
    [ "$(jget "${G}/hub.json" 'd[0]["table"]')" = "summary" ] && ok "summary — перший рядок" || bad "summary не перший"
    [ "$(jget "${G}/hub.json" '"|".join(sorted({r["table"] for r in d}))')" = "items|lanes|prs|repos|sessions|summary|triage" ] \
        && ok "рівно сім таблиць" || bad "набір таблиць" "$(jget "${G}/hub.json" 'sorted({r["table"] for r in d})')"
    [ "$(jget "${G}/hub.json" 'T("summary")[0]["generated_at"]')" = "${NOW}" ] && ok "generated_at = --now" || bad "generated_at"
    want="$(shasum -a 256 "${FX}/sessions.json" | cut -d' ' -f1)"
    [ "$(jget "${G}/hub.json" 'T("summary")[0]["sessions_sha256"]')" = "${want}" ] && ok "sessions_sha256 = sha256 файла сесій" || bad "sessions_sha256"
    [ "$(jget "${G}/hub.json" 'T("summary")[0]["state_source"]')" = "${FX}/state" ] && ok "state_source без --state-label — шлях" || bad "state_source"
    # сесії: порядок — свіжіші перші; архівна пропущена; межа 24 год входить у «простій»
    [ "$(jget "${G}/hub.json" '",".join(r["id"] for r in T("sessions"))')" = "local_eeee,local_aaaa,local_dddd,local_bbbb" ] \
        && ok "сесії: від свіжої до старої, архівної немає" || bad "порядок сесій" "$(jget "${G}/hub.json" '[r["id"] for r in T("sessions")]')"
    [ "$(jget "${G}/hub.json" '",".join("%(idle_hours)s:%(idle)s" % r for r in T("sessions"))')" = "0:False,0:False,24:True,25:True" ] && ok "idle_hours 0·0·24·25 (мілісекунди відкинуто); idle з 24 включно" || bad "idle_hours"
    [ "$(jget "${G}/hub.json" '"%(idle_limit_hours)s %(pr_stale_limit_days)s" % T("summary")[0]')" = "24 7" ] && ok "пороги в summary: 24 год, 7 днів" || bad "пороги в summary"
    r="$(jget "${G}/hub.json" 'json.dumps(T("sessions")[1], ensure_ascii=False, sort_keys=True)')"
    [ "${r}" = '{"group": "STRW", "id": "local_aaaa", "idle": false, "idle_hours": 0, "last_activity": "2026-10-28T08:30Z", "name": "alpha", "pr": 290, "pr_state": "OPEN", "running": true, "started_by": "local_hub", "table": "sessions", "title": "MARK-SESSION альфа: робота над PR"}' ] \
        && ok "рядок сесії — кожне значення, без cwd і link" || bad "рядок сесії" "got: ${r}"
    r="$(jget "${G}/hub.json" 'json.dumps(T("sessions")[0], ensure_ascii=False, sort_keys=True)')"
    [ "${r}" = '{"group": "", "id": "local_eeee", "idle": false, "idle_hours": 0, "last_activity": "2026-10-28T08:59Z", "name": "", "pr": null, "pr_state": "", "running": true, "started_by": "", "table": "sessions", "title": "епсилон: щойно"}' ] \
        && ok "сесія без group/name/pr — порожні, не вигадані" || bad "сесія без полів" "got: ${r}"
    if /usr/bin/grep -q -e secret-path -e 'claude://' "${G}/hub.json"; then bad "cwd або link просочились у вихід"; else ok "cwd і link сесій не експортуються"; fi
    # PR: порядок репо як REPOS, у репо — за номером; стан перевірок
    [ "$(jget "${G}/hub.json" '",".join(r["key"] for r in T("prs"))')" = "strw-ops#12,strw-ops#36,strw-factory#40,pact-ios#240,pact-backend#71,pact-backend#72" ] \
        && ok "PR: порядок репо і номерів" || bad "порядок PR" "$(jget "${G}/hub.json" '[r["key"] for r in T("prs")]')"
    [ "$(jget "${G}/hub.json" '",".join(r["checks"] for r in T("prs"))')" = "fail,pending,pass,fail,pass,none" ] \
        && ok "checks: FAILURE сильніше за IN_PROGRESS; StatusContext ERROR — fail; NEUTRAL+SKIPPED — pass; null — none" \
        || bad "checks" "$(jget "${G}/hub.json" '[r["checks"] for r in T("prs")]')"
    [ "$(jget "${G}/hub.json" '",".join("%(updated_days)s:%(stale)s" % r for r in T("prs"))')" = "7:True,0:False,0:False,1:False,6:False,0:False" ] && ok "updated_days: рівно 7 — stale, 6 діб 23 год — 6 і свіжий" || bad "updated_days"
    r="$(jget "${G}/hub.json" 'json.dumps(T("prs")[2], ensure_ascii=False, sort_keys=True)')"
    [ "${r}" = '{"age_days": 0, "author": "andresiletsky-bit", "branch": "hub-dashboard", "checks": "pass", "draft": false, "key": "strw-factory#40", "number": 40, "repo": "strw-factory", "review": "APPROVED", "stale": false, "table": "prs", "title": "MARK-FACTORY дашборд хаба", "updated_days": 0, "url": "https://github.com/andresiletsky-bit/strw-factory/pull/40"}' ] \
        && ok "рядок PR — кожне значення" || bad "рядок PR" "got: ${r}"
    [ "$(jget "${G}/hub.json" '"|".join("%(repo)s %(open)s %(draft)s %(checks_fail)s %(checks_pending)s" % r for r in T("repos"))')" = "strw-ops 2 1 1 1|strw-factory 1 0 0 0|strw-state 0 0 0 0|pact-ios 1 0 1 0|pact-backend 2 0 0 0" ] \
        && ok "repos: рядок на кожне з п'яти репо, порожнє теж" || bad "repos" "$(jget "${G}/hub.json" 'T("repos")')"
    # тріаж: строк учора — прострочено на 1; строк сьогодні — ні; без строку — порожньо; не-.md пропущено
    [ "$(jget "${G}/hub.json" '"|".join("%(id)s %(decide_by)s %(overdue_days)s" % r for r in T("triage"))')" = "tri-001 2026-10-27 1|tri-002 2026-10-28 0|tri-003  0" ] \
        && ok "тріаж: прострочення за decide_by, сьогодні — не прострочено" || bad "тріаж" "$(jget "${G}/hub.json" 'T("triage")')"
    r="$(jget "${G}/hub.json" 'json.dumps(T("triage")[0], ensure_ascii=False, sort_keys=True)')"
    [ "${r}" = '{"class": "some-class", "date": "2026-10-20", "decide_by": "2026-10-27", "id": "tri-001", "kind": "question", "overdue_days": 1, "product": "pact-001", "summary": "MARK-TRIAGE питання з простроченим строком", "table": "triage"}' ] \
        && ok "рядок картки — кожне значення" || bad "рядок картки" "got: ${r}"
    # реєстр
    [ "$(jget "${G}/hub.json" '",".join("%(id)s:%(state)s" % r for r in T("items"))')" = "a.one:ready,b.two:running,c.three:blocked,d.four:blocked,e.five:done,f.six:gated" ] \
        && ok "items: за id, стан як у файлі" || bad "items" "$(jget "${G}/hub.json" 'T("items")')"
    r="$(jget "${G}/hub.json" 'json.dumps([x for x in T("items") if x["id"]=="c.three"][0], ensure_ascii=False, sort_keys=True)')"
    [ "${r}" = '{"autonomy": "with-ceo", "blocked_by": "ceo:tri-001", "id": "c.three", "lane": "lane-two", "on_ceo": true, "pr": null, "product": "pact-001", "repo": "pact-ios", "size": "M", "state": "blocked", "table": "items"}' ] \
        && ok "рядок елемента — кожне значення" || bad "рядок елемента" "got: ${r}"
    [ "$(jget "${G}/hub.json" '[x for x in T("items") if x["id"]=="e.five"][0]["pr"]')" = "38" ] && ok "evidence.pr → pr" || bad "evidence.pr"
    [ "$(jget "${G}/hub.json" '"|".join("%(lane)s %(total)s %(ready)s %(running)s %(blocked)s %(done)s %(parked)s %(other)s" % r for r in T("lanes"))')" = "lane-one 3 1 1 0 1 0 0|lane-two 3 0 0 2 0 0 1" ] \
        && ok "lanes: лічильники станів, gated — «інші»" || bad "lanes" "$(jget "${G}/hub.json" 'T("lanes")')"
fi

# --- 2. детермінізм ----------------------------------------------------------------------------
G2="${TMP}/golden2"; run "${G2}" "${FX}"
[ "${RC}" -eq 0 ] && cmp -s "${G}/hub.json" "${G2}/hub.json" && ok "два прогони — побайтно рівні" || bad "вихід недетермінований" "rc=${RC}"
NCASE=$((NCASE+1)); X="${TMP}/x-${NCASE}"; run "${X}" "${FX}" --state-label "strw-state origin/main @ abc1234"
[ "${RC}" -eq 0 ] && [ "$(jget "${X}/hub.json" 'T("summary")[0]["state_source"]')" = "strw-state origin/main @ abc1234" ] && ok "--state-label → state_source" || bad "--state-label" "rc=${RC} ${OUT}"

# --- 3. досяжність: кожне джерело читається ----------------------------------------------------------
# 3a. gh: підставний gh на PATH пише виклики в журнал і віддає фікстуру репо з --repo
FAKE="${TMP}/fakebin"; mkdir -p "${FAKE}"
cat > "${FAKE}/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG}"
repo=""; prev=""
for a in "$@"; do [ "${prev}" = "--repo" ] && repo="${a#*/}"; prev="${a}"; done
[ -n "${GH_FAIL_REPO:-}" ] && [ "${repo}" = "${GH_FAIL_REPO}" ] && { echo "HTTP 502 від gh" >&2; exit 1; }
cat "${GH_FIXTURES}/${repo}.json"
SH
chmod +x "${FAKE}/gh"
GHD="${TMP}/gh-run"; mkdir -p "${GHD}"; : > "${TMP}/gh.log"
OUT="$(PATH="${FAKE}:${PATH}" GH_LOG="${TMP}/gh.log" GH_FIXTURES="${FX}/prs" python3 "${GEN}" --state "${FX}/state" --sessions "${FX}/sessions.json" --gh --out "${GHD}" --now "${NOW}" 2>&1 < /dev/null)"; RC=$?
calls="$(wc -l < "${TMP}/gh.log" | tr -d ' ')"
[ "${RC}" -eq 0 ] && [ "${calls}" = "5" ] && ok "--gh: gh викликано рівно 5 разів" || bad "--gh: виклики gh" "rc=${RC} calls=${calls} ${OUT}"
for repo in ${REPOS}; do
    if /usr/bin/grep -q -- "pr list --repo andresiletsky-bit/${repo} --state open --limit 200 --json " "${TMP}/gh.log"; then ok "--gh: gh pr list для ${repo}"
    else bad "--gh: немає виклику для ${repo}" "$(cat "${TMP}/gh.log")"; fi
done
[ "${RC}" -eq 0 ] && cmp -s "${G}/hub.json" "${GHD}/hub.json" && ok "--gh і --prs-dir з того самого знімка — побайтно рівні" || bad "--gh дав інший hub.json"
OUT2=""; X="${TMP}/gh-replay"; mkdir -p "${X}"
OUT2="$(python3 "${GEN}" --state "${FX}/state" --sessions "${FX}/sessions.json" --prs-dir "${GHD}/prs" --out "${X}" --now "${NOW}" 2>&1 < /dev/null)"
cmp -s "${GHD}/hub.json" "${X}/hub.json" && ok "сирий знімок <out>/prs відтворює hub.json" || bad "знімок prs не відтворює" "${OUT2}"
GHF="${TMP}/gh-fail"; mkdir -p "${GHF}"; : > "${TMP}/gh.log"
OUT="$(PATH="${FAKE}:${PATH}" GH_LOG="${TMP}/gh.log" GH_FIXTURES="${FX}/prs" GH_FAIL_REPO=pact-ios python3 "${GEN}" --state "${FX}/state" --sessions "${FX}/sessions.json" --gh --out "${GHF}" --now "${NOW}" 2>&1 < /dev/null)"; RC=$?
[ "${RC}" -eq 2 ] && printf '%s' "${OUT}" | /usr/bin/grep -q "pact-ios" && [ ! -e "${GHF}/hub.json" ] && ok "червоний: gh упав на pact-ios → rc 2, названо репо, hub.json немає" \
    || bad "червоний: gh упав" "rc=${RC} ${OUT}"
# 3b. знімок PR кожного репо — читається: без файла відмова з назвою; маркер у назві — у виході
for repo in ${REPOS}; do
    NCASE=$((NCASE+1)); R="${TMP}/fx-${NCASE}"; fx_copy "${R}"; rm "${R}/prs/${repo}.json"
    run "${R}/out" "${R}"
    [ "${RC}" -eq 2 ] && printf '%s' "${OUT}" | /usr/bin/grep -q "PR ${repo}: немає знімка" && [ ! -e "${R}/out/hub.json" ] \
        && ok "червоний: немає знімка PR ${repo} → rc 2" || bad "червоний: немає знімка ${repo}" "rc=${RC} ${OUT}"
done
for m in MARK-OPS MARK-FACTORY MARK-IOS MARK-BACKEND; do
    /usr/bin/grep -q "${m}" "${G}/hub.json" && ok "маркер ${m} з файла PR — у виході" || bad "маркер ${m} не дійшов"
done
NCASE=$((NCASE+1)); R="${TMP}/fx-${NCASE}"; fx_copy "${R}"
cp "${FX}/prs/strw-factory.json" "${R}/prs/strw-state.json"; run "${R}/out" "${R}"
[ "${RC}" -eq 0 ] && [ "$(jget "${R}/out/hub.json" '[r["open"] for r in T("repos") if r["repo"]=="strw-state"][0]')" = "1" ] \
    && ok "strw-state.json читається саме для strw-state (порожній → 1 PR)" || bad "strw-state.json" "rc=${RC} ${OUT}"
# 3c. сесії
NCASE=$((NCASE+1)); R="${TMP}/fx-${NCASE}"; fx_copy "${R}"; rm "${R}/sessions.json"; run "${R}/out" "${R}"
[ "${RC}" -eq 2 ] && printf '%s' "${OUT}" | /usr/bin/grep -q "сесії" && ok "червоний: немає файла сесій → rc 2" || bad "немає файла сесій" "rc=${RC} ${OUT}"
/usr/bin/grep -q "MARK-SESSION" "${G}/hub.json" && ok "маркер сесії — у виході" || bad "маркер сесії не дійшов"
# 3d. тріаж і реєстр: прибрати теку — відмова; додати запис — лічильник +1
for sub in triage/open engine/items; do
    NCASE=$((NCASE+1)); R="${TMP}/fx-${NCASE}"; fx_copy "${R}"; rm -rf "${R}/state/${sub}"; run "${R}/out" "${R}"
    [ "${RC}" -eq 2 ] && printf '%s' "${OUT}" | /usr/bin/grep -q "немає теки .*${sub}" && ok "червоний: немає ${sub} → rc 2" || bad "немає ${sub}" "rc=${RC} ${OUT}"
done
NCASE=$((NCASE+1)); R="${TMP}/fx-${NCASE}"; fx_copy "${R}"
sed 's/tri-003/tri-009/' "${R}/state/triage/open/2026-10-22-003-error.md" > "${R}/state/triage/open/2026-10-23-009-error.md"; run "${R}/out" "${R}"
[ "${RC}" -eq 0 ] && [ "$(jget "${R}/out/hub.json" 'T("summary")[0]["triage_error"]')" = "2" ] && ok "нова картка в triage/open → triage_error 2" || bad "нова картка" "rc=${RC} ${OUT}"
NCASE=$((NCASE+1)); R="${TMP}/fx-${NCASE}"; fx_copy "${R}"
sed 's/a.one/a.zero/' "${R}/state/engine/items/a.one.yaml" > "${R}/state/engine/items/a.zero.yaml"; run "${R}/out" "${R}"
[ "${RC}" -eq 0 ] && [ "$(jget "${R}/out/hub.json" 'T("summary")[0]["items_ready"]')" = "2" ] && ok "новий елемент → items_ready 2" || bad "новий елемент" "rc=${RC} ${OUT}"

# --- 4. червоні: fail-closed ---------------------------------------------------------------------
red() { # red <назва> <фрагмент причини> <корінь фікстури> [extra args]
    local name=$1 want=$2 root=$3; shift 3
    NCASE=$((NCASE+1)); local out="${TMP}/red-${NCASE}"
    run "${out}" "${root}" "$@"
    if [ "${RC}" -eq 2 ] && printf '%s' "${OUT}" | /usr/bin/grep -q -- "${want}" && [ ! -e "${out}/hub.json" ] && ! printf '%s' "${OUT}" | /usr/bin/grep -q Traceback; then
        ok "червоний: ${name} → rc 2, «${want}», hub.json немає"
    else bad "червоний: ${name} мав дати rc 2 з «${want}»" "rc=${RC} files=$(ls -A "${out}" | tr '\n' ' ') ${OUT}"; fi
}
mut() { # mut <корінь> <файл відносно кореня> <старе> <нове> — заміна першого входження з доказом
    python3 - "$1/$2" "$3" "$4" <<'PY'
import sys
p, old, new = sys.argv[1:4]
t = open(p, encoding="utf-8").read()
assert old in t, "мутація не накладена: немає " + old
open(p, "w", encoding="utf-8").write(t.replace(old, new, 1))
PY
}
m() { NCASE=$((NCASE+1)); M="${TMP}/m-${NCASE}"; fx_copy "${M}"; mut "${M}" "$@"; }
m sessions.json '"sessionId": "local_bbbb"' '"sessionId": "local_aaaa"';      red "дубль sessionId" "дубль sessionId" "${M}"
m sessions.json '"sessionId": "local_bbbb", ' '';                               red "сесія без sessionId" "немає sessionId" "${M}"
m sessions.json '"isRunning": false,' '"isRunning": "no",';                     red "isRunning не bool" "isRunning" "${M}"
m sessions.json '"lastActivityAt": "2026-10-27T08:00:00.000Z"' '"lastActivityAt": "вчора"'; red "lastActivityAt не час" "вчора" "${M}"
m sessions.json '"lastActivityAt": "2026-10-27T08:00:00.000Z"' '"lastActivityAt": "2026-10-27T08:00:00+03:00"'; red "lastActivityAt не UTC" "lastActivityAt" "${M}"
m sessions.json '"prNumber": 290' '"prNumber": "290"';                          red "prNumber рядком" "prNumber" "${M}"
NCASE=$((NCASE+1)); M="${TMP}/m-${NCASE}"; fx_copy "${M}"; printf '{"sessions": []}\n' > "${M}/sessions.json"; red "сесії не масив" "очікувався масив" "${M}"
m sessions.json '"sessionId": "local_bbbb"' '"sessionId": 7';                  red "sessionId не рядок" "немає sessionId" "${M}"
m sessions.json '"group": null}' '"group": null}, 5';                            red "запис сесії не об'єкт" "не об'єкт" "${M}"
m sessions.json '"title"' '"title\x"';                                         red "сесії не JSON" "не JSON" "${M}"
m prs/strw-ops.json '"number":12' '"number":36';                                red "дубль номера PR" "дубль номера" "${M}"
m prs/strw-ops.json '"number":12' '"number":"12"';                              red "номер PR рядком" "number" "${M}"
m prs/strw-ops.json '"isDraft":true' '"isDraft":"yes"';                         red "isDraft не bool" "isDraft" "${M}"
m prs/pact-ios.json '"createdAt":"2026-10-25T09:00:00Z"' '"createdAt":"25.10"'; red "createdAt не час" "createdAt" "${M}"
m prs/pact-ios.json '"title":"MARK-IOS екран",' '';                             red "PR без title" "немає title" "${M}"
m prs/pact-ios.json '"statusCheckRollup":[{"__typename":"StatusContext","context":"ext","state":"ERROR"}]' '"statusCheckRollup":"ERROR"'; red "statusCheckRollup не список" "statusCheckRollup не список" "${M}"
m prs/pact-ios.json '"context":"ext","state":"ERROR"}' '"context":"ext","state":"ERROR"}, 5'; red "запис statusCheckRollup не об'єкт" "не об'єкт" "${M}"
NCASE=$((NCASE+1)); M="${TMP}/m-${NCASE}"; fx_copy "${M}"; printf '{"rows": []}\n' > "${M}/prs/pact-ios.json"; red "PR не масив" "очікувався масив" "${M}"
m prs/pact-ios.json '"title":"MARK-IOS' '"title\x":"MARK-IOS';                 red "PR не JSON" "PR pact-ios: не JSON" "${M}"
NCASE=$((NCASE+1)); M="${TMP}/m-${NCASE}"; fx_copy "${M}"
python3 -c 'import json,sys; one=json.load(open(sys.argv[1]))[0]; json.dump([dict(one, number=i) for i in range(1,201)], open(sys.argv[1],"w"))' "${M}/prs/strw-factory.json"
red "200 PR = --limit (обрізано)" "обрізано" "${M}"
NCASE=$((NCASE+1)); M="${TMP}/m-${NCASE}"; fx_copy "${M}"
python3 -c 'import json,sys; one=json.load(open(sys.argv[1]))[0]; json.dump([dict(one, number=i) for i in range(1,200)], open(sys.argv[1],"w"))' "${M}/prs/strw-factory.json"
run "${M}/out" "${M}"; [ "${RC}" -eq 0 ] && ok "199 PR — не обрізано, rc 0" || bad "199 PR" "rc=${RC} ${OUT}"
m state/triage/open/2026-10-21-002-finding.md 'id: tri-002' 'id: tri-001';     red "дубль id картки" "дубль id tri-001" "${M}"
m state/triage/open/2026-10-21-002-finding.md 'id: tri-002' 'nid: tri-002';    red "картка без id" "немає id" "${M}"
m state/triage/open/2026-10-21-002-finding.md 'status: open' 'status: resolved'; red "закрита картка в open/" "resolved" "${M}"
m state/triage/open/2026-10-21-002-finding.md 'kind: "finding"' 'knd: "finding"'; red "картка без kind" "немає kind" "${M}"
m state/triage/open/2026-10-21-002-finding.md 'decide_by: 2026-10-28' 'decide_by: скоро'; red "decide_by не дата" "скоро" "${M}"
m state/triage/open/2026-10-21-002-finding.md 'date: 2026-10-21' 'date: 2026-02-30'; red "YAML-дата 30 лютого" "не читається" "${M}"
m state/triage/open/2026-10-21-002-finding.md 'date: 2026-10-21' 'date: 2026-10-21
date: 2026-10-22';                                                               red "дубль ключа в передмові" "дубльований ключ" "${M}"
m state/triage/open/2026-10-21-002-finding.md '---
id' 'id';                                                                       red "картка без передмови" "передмови" "${M}"
m state/triage/open/2026-10-22-003-error.md 'summary: "помилка без строку"
---' 'summary: "помилка без строку"';                                            red "передмова не закрита" "не закрита" "${M}"
m state/engine/items/b.two.yaml 'id: b.two' 'id: a.one';                       red "дубль id елемента" "дубль id a.one" "${M}"
m state/engine/items/b.two.yaml 'id: b.two' 'nid: b.two';                      red "елемент без id" "немає id" "${M}"
m state/engine/items/b.two.yaml 'state: running' 'state: sleeping';            red "невідомий state" "sleeping" "${M}"
m state/engine/items/b.two.yaml 'lane: lane-one' 'lne: lane-one';              red "елемент без lane" "немає lane" "${M}"
m state/engine/items/b.two.yaml 'blocked_by: []' 'blocked_by: ceo:tri-001';    red "blocked_by рядком" "blocked_by" "${M}"
m state/engine/items/b.two.yaml 'lane: lane-one' 'lane: lane-one
lane: lane-two';                                                                 red "дубль ключа YAML елемента" "дубльований ключ" "${M}"
NCASE=$((NCASE+1)); M="${TMP}/m-${NCASE}"; fx_copy "${M}"; printf -- '- a\n' > "${M}/state/engine/items/z.yaml"; red "елемент — список, не мапа" "не мапа" "${M}"
red "--now без Z" "--now" "${FX}" --now "2026-10-28T09:00"
red "--now не дата" "--now" "${FX}" --now "сьогодні"
# --state — спільна копія: відмова навіть коли там справжній strw-state
NCASE=$((NCASE+1)); SR="${TMP}/root-${NCASE}"; mkdir -p "${SR}"; cp -R "${FX}/state" "${SR}/strw-state"; X="${TMP}/shared-out"; mkdir -p "${X}"
OUT="$(STRW_ROOT="${SR}" python3 "${GEN}" --state "${SR}/strw-state/" --sessions "${FX}/sessions.json" --prs-dir "${FX}/prs" --out "${X}" --now "${NOW}" 2>&1 < /dev/null)"; RC=$?
[ "${RC}" -eq 2 ] && printf '%s' "${OUT}" | /usr/bin/grep -q "спільна копія" && [ ! -e "${X}/hub.json" ] && ok "червоний: --state = спільна копія (зі слешем) → rc 2" || bad "спільна копія" "rc=${RC} ${OUT}"
OUT="$(STRW_ROOT="${SR}" python3 "${GEN}" --state "${FX}/state" --sessions "${FX}/sessions.json" --prs-dir "${FX}/prs" --out "${X}" --now "${NOW}" 2>&1 < /dev/null)"; RC=$?
[ "${RC}" -eq 0 ] && ok "контроль: інша тека при тому самому STRW_ROOT → rc 0" || bad "контроль спільної копії" "rc=${RC} ${OUT}"
# --out
: > "${TMP}/a-file"
OUT="$(python3 "${GEN}" --state "${FX}/state" --sessions "${FX}/sessions.json" --prs-dir "${FX}/prs" --out "${TMP}/a-file" --now "${NOW}" 2>&1 < /dev/null)"; RC=$?
[ "${RC}" -eq 2 ] && printf '%s' "${OUT}" | /usr/bin/grep -q "не порожня тека" && ok "червоний: --out — файл → rc 2" || bad "--out файл" "rc=${RC} ${OUT}"
NCASE=$((NCASE+1)); X="${TMP}/x-${NCASE}"; mkdir -p "${X}"; printf '[]\n' > "${X}/hub.json"
OUT="$(python3 "${GEN}" --state "${FX}/state" --sessions "${FX}/sessions.json" --prs-dir "${FX}/prs" --out "${X}" --now "${NOW}" 2>&1 < /dev/null)"; RC=$?
[ "${RC}" -eq 2 ] && [ "$(cat "${X}/hub.json")" = "[]" ] && ok "червоний: --out не порожня → rc 2, старий hub.json не чіпає" || bad "--out не порожня" "rc=${RC} ${OUT}"
# рівно 20 сесій — попередження про обрізаний list_sessions; 21 — без нього
NCASE=$((NCASE+1)); M="${TMP}/m-${NCASE}"; fx_copy "${M}"
python3 -c 'import json,sys; one=json.load(open(sys.argv[1]))[1]; json.dump([dict(one, sessionId="local_%02d" % i) for i in range(20)], open(sys.argv[1],"w"))' "${M}/sessions.json"
run "${M}/out" "${M}"; [ "${RC}" -eq 0 ] && printf '%s' "${OUT}" | /usr/bin/grep -q "можливо, обрізано" && ok "20 сесій → попередження про limit" || bad "20 сесій без попередження" "rc=${RC} ${OUT}"
NCASE=$((NCASE+1)); M="${TMP}/m-${NCASE}"; fx_copy "${M}"
python3 -c 'import json,sys; one=json.load(open(sys.argv[1]))[1]; json.dump([dict(one, sessionId="local_%02d" % i) for i in range(21)], open(sys.argv[1],"w"))' "${M}/sessions.json"
run "${M}/out" "${M}"; [ "${RC}" -eq 0 ] && ! printf '%s' "${OUT}" | /usr/bin/grep -q "обрізано" && ok "21 сесія — без попередження" || bad "21 сесія" "rc=${RC} ${OUT}"

# --- 5. немає читача YAML → rc 2 з назвою -----------------------------------------------------------
NL="${TMP}/nolib/scripts/native"; mkdir -p "${NL}" "${TMP}/nolib-out"; cp "${GEN}" "${NL}/"
out="$(cd "${TMP}" && env -u STRW_ENGINE_LIB STRW_ROOT=/nonexistent python3 "${NL}/hub-dashboard-data.py" --state "${FX}/state" --sessions "${FX}/sessions.json" --prs-dir "${FX}/prs" --out "${TMP}/nolib-out" --now "${NOW}" 2>&1 < /dev/null)"; rc=$?
[ "${rc}" -eq 2 ] && printf '%s' "${out}" | /usr/bin/grep -q yaml_nodup.py && ok "без lib/yaml_nodup.py → rc 2, називає читача" || bad "без читача" "rc=${rc} ${out}"
out="$(cd "${TMP}" && STRW_ENGINE_LIB="${HERE}/../engine/lib" STRW_ROOT=/nonexistent python3 "${NL}/hub-dashboard-data.py" --state "${FX}/state" --sessions "${FX}/sessions.json" --prs-dir "${FX}/prs" --out "${TMP}/nolib-out" --now "${NOW}" 2>&1 < /dev/null)"; rc=$?
[ "${rc}" -eq 0 ] && ok "контроль: STRW_ENGINE_LIB → читач знайдено" || bad "STRW_ENGINE_LIB" "rc=${rc} ${out}"

# --- 6. обгортка: знімок origin/main, не робоче дерево спільної копії --------------------------------
WR="${TMP}/wrap"; mkdir -p "${WR}/root"
(
    set -e
    git init -q --bare "${WR}/origin.git"
    git -c init.defaultBranch=main init -q "${WR}/seed"
    cp -R "${FX}/state/." "${WR}/seed/"
    git -C "${WR}/seed" add -A
    git -C "${WR}/seed" -c user.name=t -c user.email=t@t commit -q -m seed
    git -C "${WR}/seed" push -q "${WR}/origin.git" HEAD:main
    git clone -q "${WR}/origin.git" "${WR}/root/strw-state"
    # спільна копія «заморожена»: незакомічений зайвий елемент і локальний коміт, яких немає в origin/main
    sed 's/a.one/z.local/' "${WR}/root/strw-state/engine/items/a.one.yaml" > "${WR}/root/strw-state/engine/items/z.local.yaml"
    git -C "${WR}/root/strw-state" add -A
    git -C "${WR}/root/strw-state" -c user.name=t -c user.email=t@t commit -q -m local
    sed 's/a.one/y.dirty/' "${WR}/root/strw-state/engine/items/a.one.yaml" > "${WR}/root/strw-state/engine/items/y.dirty.yaml"
    # а origin/main тим часом пішов уперед: новий елемент, якого в клоні ще немає
    sed 's/a.one/x.remote/' "${WR}/seed/engine/items/a.one.yaml" > "${WR}/seed/engine/items/x.remote.yaml"
    git -C "${WR}/seed" add -A
    git -C "${WR}/seed" -c user.name=t -c user.email=t@t commit -q -m remote
    git -C "${WR}/seed" push -q "${WR}/origin.git" HEAD:main
) < /dev/null >/dev/null 2>&1 || bad "обгортка: не зібрано фікстуру git"
REMOTE_SHA="$(git -C "${WR}/seed" rev-parse HEAD)"
: > "${TMP}/gh.log"
OUT="$(PATH="${FAKE}:${PATH}" GH_LOG="${TMP}/gh.log" GH_FIXTURES="${FX}/prs" STRW_ROOT="${WR}/root" STRW_ENGINE_LIB="${HERE}/../engine/lib" TMPDIR="${WR}" bash "${REFRESH}" "${FX}/sessions.json" 2>&1 < /dev/null)"; RC=$?
HJ="$(printf '%s\n' "${OUT}" | sed -n 's/^hub.json: //p')"
if [ "${RC}" -eq 0 ] && [ -f "${HJ}" ]; then
    ids="$(jget "${HJ}" '",".join(r["id"] for r in T("items"))')"
    [ "${ids}" = "a.one,b.two,c.three,d.four,e.five,f.six,x.remote" ] && ok "обгортка: елементи з origin/main після fetch (x.remote є; z.local і y.dirty — ні)" || bad "обгортка читала не origin/main" "got: ${ids}"
    [ "$(jget "${HJ}" 'T("summary")[0]["state_source"]')" = "strw-state origin/main @ ${REMOTE_SHA:0:7}" ] && ok "обгортка: state_source — sha origin/main" || bad "обгортка: state_source" "$(jget "${HJ}" 'T("summary")[0]["state_source"]')"
    [ "$(wc -l < "${TMP}/gh.log" | tr -d ' ')" = "5" ] && ok "обгортка: gh по п'яти репо" || bad "обгортка: gh" "$(cat "${TMP}/gh.log")"
    want="$(shasum -a 256 "${HJ}" | cut -d' ' -f1)"
    printf '%s' "${OUT}" | /usr/bin/grep -q "sha256: ${want}" && ok "обгортка: друкує sha256 hub.json" || bad "обгортка: sha256" "${OUT}"
    [ -z "$(git -C "${WR}/root/strw-state" status --porcelain --untracked-files=all | /usr/bin/grep -v y.dirty)" ] && ok "обгортка: робоче дерево спільної копії не змінено" || bad "обгортка змінила дерево" "$(git -C "${WR}/root/strw-state" status --porcelain)"
else bad "обгортка мала дати rc 0 і hub.json" "rc=${RC} ${OUT}"; fi
git -C "${WR}/root/strw-state" remote set-url origin "${WR}/nope.git"
OUT="$(PATH="${FAKE}:${PATH}" GH_LOG="${TMP}/gh.log" GH_FIXTURES="${FX}/prs" STRW_ROOT="${WR}/root" STRW_ENGINE_LIB="${HERE}/../engine/lib" TMPDIR="${WR}" bash "${REFRESH}" "${FX}/sessions.json" 2>&1 < /dev/null)"; RC=$?
[ "${RC}" -eq 2 ] && printf '%s' "${OUT}" | /usr/bin/grep -q "fetch origin main" && ! printf '%s' "${OUT}" | /usr/bin/grep -q "^hub.json:" && ok "червоний: fetch не вдався → обгортка rc 2" || bad "червоний: fetch" "rc=${RC} ${OUT}"
OUT="$(STRW_ROOT="${WR}/root" bash "${REFRESH}" 2>&1 < /dev/null)"; RC=$?
[ "${RC}" -eq 2 ] && printf '%s' "${OUT}" | /usr/bin/grep -q usage && ok "червоний: обгортка без файла сесій → rc 2, usage" || bad "обгортка без аргументу" "rc=${RC} ${OUT}"

printf '\n%d PASS · %d FAIL\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
