#!/usr/bin/env bash
# autonomy-route.test.sh — режим A/B елемента (autonomy-route.sh) і форма нових полів (validate-items.sh).
# Запуск: bash scripts/engine/autonomy-route.test.sh   (валідаторна частина потребує клону strw-factory
# у парасольці STRW; без нього — SKIP саме тієї частини, маршрут міряється на власних фікстурах).
#
# Спека: strw-ops reports/2026-10-20-hybrid-autonomy-spec.md §2 (правило вибору) і §3 (готовність до A).
# На КОЖНУ умову — червоний випадок І близнюк: найближчий варіант, що мусить пройти. Без близнюка
# червоне не відрізняє «умова працює» від «скрипт каже with-ceo на все» (evidence-the-lookalike).
# Кожен вихід маршруту звіряється з контрактом: рівно один рядок і код, що відповідає префіксу.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTE="${HERE}/autonomy-route.sh"
V="${HERE}/validate-items.sh"
if [ -z "${STRW_ROOT:-}" ]; then
    STRW_ROOT="$(cd "${HERE}/../../.." && pwd)"
    while [ ! -d "${STRW_ROOT}/strw-factory/.git" ] && [ "${STRW_ROOT}" != "/" ]; do STRW_ROOT="$(dirname "${STRW_ROOT}")"; done
fi
PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
ok()  { PASS=$((PASS+1)); printf 'PASS · %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL · %s\n%s\n' "$1" "${2:-}"; }

# ---------- фікстура стану: продукти, журнал рішень, тріаж ----------
S="${TMP}/strw-state"
mk_state() {
    rm -rf "${S}"; mkdir -p "${S}/engine/items" "${S}/decisions/2026" "${S}/triage/open" "${S}/triage/resolved" \
        "${S}/products/pact-x" "${S}/products/pact-big" "${S}/products/tea-x" "${S}/products/nostage-x"
    printf '1\n' > "${S}/engine/schema_version"
    printf -- '---\nid: pact-x\nstage: 5-build\n---\n# журнал\n' > "${S}/products/pact-x/state.md"
    printf -- '---\nid: pact-big\nstage: 5-Build\n---\n' > "${S}/products/pact-big/state.md"
    printf -- '---\nid: tea-x\nstage: 3-definition\n---\n' > "${S}/products/tea-x/state.md"
    printf -- '---\nid: nostage-x\nstatus: active\n---\n' > "${S}/products/nostage-x/state.md"
    printf -- '---\naffects: [factory]\n---\n## 2026-10-01 · dec-001 · фікстура\n' > "${S}/decisions/2026/dec-001-a.md"
    cat > "${S}/engine/lanes.yaml" <<'YAML'
schema_version: 1
shared: []
tools: {}
lanes:
  - id: zz-lane
    repo: strw-factory
    owns: ["loops/**"]
    resources: []
YAML
}

# gen <id> [python-правка над `it`] — базовий елемент, що ПРОХОДИТЬ усе (unattended), і одна правка.
# plan_review.sha рахується з БАЗОВОГО плану до правки; правка, що міняє план і лишає рев'ю чинним,
# кличе resha() — інакше це і є випадок «план змінено після рев'ю».
gen() {
    STRW_ENGINE_LIB="${HERE}/lib" python3 - "${S}/engine/items" "$1" "${2:-pass}" <<'PY'
import os, sys, yaml
d, iid, patch = sys.argv[1:4]
sys.path.insert(0, os.environ["STRW_ENGINE_LIB"])
from item_fields import plan_sha
it = {
  "schema_version": 1, "id": iid, "product": "factory", "loop": "L3-build", "lane": "zz-lane",
  "state": "ready", "repo": "strw-factory", "branch": "cycle/" + iid, "size": "S",
  "lease": {"run_id": None, "epoch": 0, "heartbeat": None},
  "evidence": {"run_id": None, "commit_sha": None, "cwd": "/tmp"}, "attempts": 0,
  "acceptance": "- властивість X правдива\n", "not_in_scope": "- не робимо Y\n",
  "acceptance_basis": {"verified_against_decisions_log_at": "2026-10-20", "decisions_log_entries": 1,
                       "sources": ["dec-001"]},
  "autonomy": "unattended", "touches": [],
  "plan": {"files": ["docs/x.md", "scripts/y.sh"], "order": ["тест", "код"], "risks": [],
           "risks_none_because": "фікстура", "proof": "тест зелений"},
  "tests_spec": [{"name": "x_is_true", "cmd": "bash tests/x.test.sh", "red_when": "X хибне",
                  "negative_control": "X=const"}],
  "plan_review": {"verdict": "PASS", "by": "opus", "at": "2026-10-20", "sha": None},
  "budget": {"max_cycles": 2, "max_hours": 3},
}
it["plan_review"]["sha"] = plan_sha(it)
def resha(): it["plan_review"]["sha"] = plan_sha(it)
exec(patch)
with open(os.path.join(d, iid + ".yaml"), "w", encoding="utf-8") as f:
    yaml.safe_dump(it, f, allow_unicode=True, sort_keys=False)
PY
}

# route <назва> <id> <очікуваний rc> <фрагмент рядка> — перевіряє контракт виходу ПОВНІСТЮ.
route() {
    local name="$1" iid="$2" want_rc="$3" want="$4" out rc n prefix
    out="$(bash "${ROUTE}" "${S}/engine/items/${iid}.yaml" 2>/dev/null)"; rc=$?
    n="$(printf '%s\n' "${out}" | /usr/bin/grep -c .)"
    case "${want_rc}" in 0) prefix="unattended" ;; 1) prefix="with-ceo: " ;; *) prefix="не поміряно: " ;; esac
    if [ "${rc}" = "${want_rc}" ] && [ "${n}" = 1 ] && [ "${out#"${prefix}"}" != "${out}" ] \
       && printf '%s' "${out}" | /usr/bin/grep -qF -- "${want}"; then ok "${name} → rc ${rc}: ${out}"
    else bad "${name}: очікував rc ${want_rc} і «${want}»" "rc=${rc} рядків=${n} вихід=${out}"; fi
}

mk_state
# 0. контроль: базовий елемент — unattended (інакше всі червоні нижче міряли б не умову)
gen f.base;                                                   route "контроль: базовий елемент"        f.base 0 "unattended"

# §1 autonomy — поле, а не сесія; за відсутності — B
gen f.no-autonomy 'del it["autonomy"]';                        route "autonomy немає"                   f.no-autonomy 1 "не позначено autonomy"
gen f.manual-b 'it["autonomy"]="with-ceo"';                    route "autonomy: with-ceo вручну"        f.manual-b 1 "вручну"
gen f.typo-autonomy 'it["autonomy"]="unatended"';              route "autonomy з одруком"               f.typo-autonomy 1 "невідоме значення"

# §2.1 стадія продукту — 5-Build; factory.* без стадії (базовий — factory)
gen f.stage-def 'it["product"]="tea-x"';                       route "стадія 3-definition"              f.stage-def 1 "стадія продукту 3-definition"
gen f.stage-build 'it["product"]="pact-x"';                    route "близнюк: стадія 5-build"          f.stage-build 0 "unattended"
gen f.stage-Build 'it["product"]="pact-big"';                  route "близнюк: стадія 5-Build (регістр)" f.stage-Build 0 "unattended"
gen f.no-state 'it["product"]="ghost-x"';                      route "немає state.md продукту"          f.no-state 2 "стадія продукту невідома"
gen f.no-stage 'it["product"]="nostage-x"';                    route "state.md без stage"               f.no-stage 2 "немає поля stage"
mkdir -p "${S}/products/open-fm"; printf -- '---\nstage: 5-build\nбез закриття\n' > "${S}/products/open-fm/state.md"
gen f.open-fm 'it["product"]="open-fm"';                        route "frontmatter без закриття"         f.open-fm 2 "немає закритого frontmatter"

# §2.2 розмір S|M
gen f.size-l 'it["size"]="L"';                                 route "розмір L"                         f.size-l 1 "розмір L"
gen f.size-none 'del it["size"]';                              route "розміру немає"                    f.size-none 1 "режим A лише для S або M"
gen f.size-m 'it["size"]="M"';                                 route "близнюк: розмір M"                f.size-m 0 "unattended"

# §2.4 touches — кожне значення принципу 5 робить B; порожній — ні
for v in money release prod data-deletion third-party-data privacy-behavior milestone-scope; do
    gen "f.touch-${v}" "it[\"touches\"]=[\"${v}\"]";          route "touches: ${v}"                    "f.touch-${v}" 1 "вирішує CEO: ${v}"
done
gen f.touch-typo 'it["touches"]=["mony"]';                     route "touches з невідомим значенням"    f.touch-typo 1 "touches має невідомі значення"
gen f.touch-absent 'del it["touches"]';                        route "близнюк: touches немає"           f.touch-absent 0 "unattended"

# §2.5 відкрите питання: blocked_by, ceo:*, картка тріажу, протухла підстава
gen f.ceo 'it["blocked_by"]=["ceo:budget-ok"]; it["state"]="blocked"';  route "blocked_by ceo:*"     f.ceo 1 "чекає рішення CEO (ceo:budget-ok)"
gen f.blocked 'it["blocked_by"]=["item:f.base"]; it["state"]="blocked"'; route "blocked_by item:*"   f.blocked 1 "заблоковано іншим"
gen f.blocked-empty 'it["blocked_by"]=[]';                     route "близнюк: blocked_by порожній"     f.blocked-empty 0 "unattended"

gen f.triaged; gen f.triaged-two
printf -- '---\nstatus: open\n---\nпро f.triaged-two і f.triaged.\n' > "${S}/triage/open/tri-900.md"
route "відкрита картка тріажу називає елемент" f.triaged 1 "картка тріажу tri-900.md"
printf -- '---\nstatus: open\n---\nпро fxtriaged — крапка в id не є «будь-який символ».\n' > "${S}/triage/open/tri-900.md"
route "близнюк: картка називає fxtriaged (крапка в id екранована)" f.triaged 0 "unattended"
printf -- '---\nstatus: open\n---\nлише про f.triaged-two.\n' > "${S}/triage/open/tri-900.md"
route "близнюк: картка називає f.triaged-two (довший id)" f.triaged 0 "unattended"
rm -f "${S}/triage/open/tri-900.md"; printf -- 'про f.triaged\n' > "${S}/triage/resolved/tri-901.md"
route "близнюк: картка про елемент закрита (resolved/)"  f.triaged 0 "unattended"
mv "${S}/triage/open" "${S}/triage/open.off"
route "немає triage/open — не поміряно, не «вільно»"       f.triaged 2 "відкриті картки тріажу не перевірити"
mv "${S}/triage/open.off" "${S}/triage/open"

gen f.fresh
printf -- '---\naffects: [product:other]\n---\n## 2026-10-19 · dec-002 · не про фабрику\n' > "${S}/decisions/2026/dec-002-b.md"
route "близнюк: дописане рішення не торкається елемента" f.fresh 0 "unattended"
printf -- '---\naffects: [factory]\n---\n## 2026-10-19 · dec-002 · про фабрику\n' > "${S}/decisions/2026/dec-002-b.md"
route "дописане рішення торкається елемента → STALE"     f.fresh 1 "підстава застаріла"
printf -- '---\nid: dec-002\n---\n## 2026-10-19 · dec-002 · без affects\n' > "${S}/decisions/2026/dec-002-b.md"
route "вузол без affects торкається всього (стара семантика) → STALE" f.fresh 1 "підстава застаріла"
rm -f "${S}/decisions/2026/dec-002-b.md"
gen f.date-stale 'del it["acceptance_basis"]["decisions_log_entries"]; it["acceptance_basis"]["verified_against_decisions_log_at"]="2026-09-01"'
route "без лічильника: новіше рішення за датою → STALE" f.date-stale 1 "у журналі є новіші рішення"
gen f.date-fresh 'del it["acceptance_basis"]["decisions_log_entries"]'
route "близнюк: без лічильника, звірено після останнього рішення" f.date-fresh 0 "unattended"
gen f.vanished 'it["acceptance_basis"]["decisions_log_entries"]=5'; route "лічильник більший за журнал"  f.vanished 1 "лічильник звірки"
gen f.boolcnt 'it["acceptance_basis"]["decisions_log_entries"]=True'; route "лічильник true — не число" f.boolcnt 1 "лічильник звірки"
printf -- '---\naffects: [facotry]\n---\n## 2026-10-19 · dec-002 · одрук\n' > "${S}/decisions/2026/dec-002-b.md"
gen f.fresh2 'it["acceptance_basis"]["decisions_log_entries"]=2'
route "вузол журналу з одруком в affects → свіжість не доведено" f.fresh2 1 "журнал рішень має помилку"
rm -f "${S}/decisions/2026/dec-002-b.md"
gen f.no-basis-date 'del it["acceptance_basis"]["verified_against_decisions_log_at"]'
route "acceptance_basis без дати звірки"                  f.no-basis-date 1 "не звірено з журналом"
mv "${S}/decisions" "${S}/decisions.off"
route "немає журналу рішень — не поміряно"                f.fresh 2 "decisions"
mv "${S}/decisions.off" "${S}/decisions"

# §3 готовність до A — кожне поле, і для S теж (базовий — S)
gen f.r-acc 'del it["acceptance"]';                            route "§3 немає acceptance"              f.r-acc 1 "немає acceptance"
gen f.r-nis 'del it["not_in_scope"]';                          route "§3 немає not_in_scope"            f.r-nis 1 "немає not_in_scope"
gen f.r-plan 'del it["plan"]';                                 route "§3 немає plan"                    f.r-plan 1 "немає plan"
gen f.r-ts 'del it["tests_spec"]';                             route "§3 немає tests_spec"              f.r-ts 1 "немає tests_spec"
gen f.r-ts-bad 'del it["tests_spec"][0]["negative_control"]';              route "§3 tests_spec без негативного контролю" f.r-ts-bad 1 "negative_control"
gen f.r-pr 'del it["plan_review"]';                            route "§3 немає plan_review"             f.r-pr 1 "немає plan_review"
gen f.r-pwn 'it["plan_review"]["verdict"]="PASS-WITH-NOTES"';  route "§3 план без PASS"                 f.r-pwn 1 "не має PASS"
gen f.r-sha 'it["plan"]["files"].append("docs/z.md")';         route "§3 план змінено після рев'ю"      f.r-sha 1 "план змінено після рев'ю"
gen f.r-resha 'it["plan"]["files"].append("docs/z.md"); resha()'; route "близнюк: план змінено і перерецензовано" f.r-resha 0 "unattended"
gen f.r-acc-chg 'it["acceptance"]+="- ще одна властивість\n"'; route "§3 критерій змінено після рев'ю" f.r-acc-chg 1 "план змінено після рев'ю"
gen f.r-ts-chg 'it["tests_spec"][0]["cmd"]="true"';           route "§3 команду тесту змінено після рев'ю" f.r-ts-chg 1 "план змінено після рев'ю"
gen f.r-pfx12 'it["plan_review"]["sha"]=it["plan_review"]["sha"][:12]'; route "близнюк: префікс sha з 12 знаків" f.r-pfx12 0 "unattended"
gen f.r-pfx11 'it["plan_review"]["sha"]=it["plan_review"]["sha"][:11]'; route "префікс sha з 11 знаків — замало" f.r-pfx11 1 "plan_review.sha"
gen f.r-cmd 'del it["tests_spec"][0]["cmd"]; resha()';         route "§3 tests_spec без cmd"            f.r-cmd 1 "tests_spec[0].cmd"
gen f.r-extra 'it["tests_spec"][0]["criterion"]="AC-1"; resha()'; route "близнюк: вільний ключ criterion у tests_spec" f.r-extra 0 "unattended"
gen f.r-budget 'del it["budget"]';                             route "§3 немає budget"                  f.r-budget 1 "немає budget"
gen f.r-inf 'it["budget"]["max_hours"]=float("inf")';           route "budget.max_hours = .inf"          f.r-inf 1 "budget.max_hours"
gen f.r-date 'it["plan_review"]["at"]="2026-99-99"';            route "plan_review.at — неіснуюча дата"   f.r-date 1 "plan_review.at"
gen f.r-null 'it["acceptance"]=[None]; resha()';               route "acceptance: [null]"               f.r-null 1 "немає acceptance"
gen f.r-bfalse 'it["blocked_by"]=False';                        route "blocked_by: false — не «порожньо»" f.r-bfalse 1 "blocked_by має бути списком"
gen f.r-nosrc 'it["acceptance_basis"]["sources"]=[]';           route "реєстр: acceptance_basis.sources порожній" f.r-nosrc 1 "реєстр не приймає елемент"
gen f.r-noid 'del it["id"]';                                    route "немає id"                         f.r-noid 1 "немає id"

# §2.3 «великий» за 6a — за plan.files
big() { gen "f.big-$1" "it['plan']['files']=['docs/x.md', '$2']; resha()"; route "6a: $3 ($2)" "f.big-$1" 1 "$4"; }
big contract   "contract/api.yaml"                          "контракт"            "контракт"
big migration  "backend/supabase/migrations/20261020_x.sql" "міграція"            "міграцію"
big crypto     "App/Sources/Crypto/Provider.swift"          "крипто"              "крипто або ключі"
big keys       "App/Sources/Spaces/SpaceKeys.swift"         "ключі простору"      "крипто або ключі"
big check      "scripts/event-coverage-check.sh"            "*-check.sh"          "вимірювальний інструмент"
big gates      "gates.json"                                 "gates*.json"         "вимірювальний інструмент"
big hooks      ".claude/hooks/registry.sh"                  ".claude/hooks/**"    "вимірювальний інструмент"
big englib     "scripts/engine/lib/new.py"                  "lib рушія"           "вимірювальний інструмент"
big ci         ".github/workflows/ci.yml"                   "CI"                  "вимірювальний інструмент"
big dotdot     "docs/../.github/workflows/build.yml"        "обхід через .."      "вимірювальний інструмент"
big ghdir      ".github"                                    "тека-предок CI"      "теку вимірювального інструмента"
big outside    "../pact-ios/App/x.swift"                    "поза репо"           "поза репо"
big absolute   "/etc/hosts.txt"                             "абсолютний шлях"     "поза репо"
big route      "scripts/engine/autonomy-route.sh"           "сам маршрутизатор"   "вимірювальний інструмент"
gen f.big-twin "it['plan']['files']=['docs/contracting.md', 'App/Sources/Keypad.swift']; resha()"
route "близнюк: contracting.md і Keypad.swift — не контракт і не ключі" f.big-twin 0 "unattended"
gen f.big-16 "it['plan']['files']=['docs/f%02d.md' % i for i in range(16)]; resha()"; route "6a: 16 файлів"  f.big-16 1 "16 файлів"
gen f.big-15 "it['plan']['files']=['docs/f%02d.md' % i for i in range(15)]; resha()"; route "близнюк: 15 файлів" f.big-15 0 "unattended"
gen f.dotslash "it['plan']['files']=['./docs/x.md', '.gitignore']; resha()"; route "близнюк: ./docs/x.md і .gitignore" f.dotslash 0 "unattended"
gen f.nonstr "it['plan']['files']=['docs/x.md', 7]; resha()";  route "plan.files з не-рядком"          f.nonstr 1 "списком непорожніх рядків"
gen f.keyorder "it['plan']=dict(reversed(list(it['plan'].items())))"; route "близнюк: порядок ключів плану не міняє версію" f.keyorder 0 "unattended"
gen f.mask "it['plan']['files']=['scripts/*.sh']; resha()";    route "план із маскою"                   f.mask 1 "маску або теку"
gen f.dir "it['plan']['files']=['docs']; resha()";             route "план із текою без слеша"          f.dir 1 "маску або теку"
gen f.dir2 "it['plan']['files']=['scripts']; resha()";         route "тека-предок lib рушія (scripts)"  f.dir2 1 "теку вимірювального інструмента"

# rc 2 — інструмент сліпий: файл, читач, YAML
out="$(bash "${ROUTE}" "${S}/engine/items/nope.yaml")"; rc=$?
if [ "${rc}" = 2 ] && [ "${out#не поміряно: }" != "${out}" ]; then ok "немає файла елемента → rc 2"; else bad "немає файла мав би дати rc 2" "rc=${rc} ${out}"; fi
printf 'id: a\nid: b\n' > "${S}/engine/items/f.dup.yaml"; route "дубль ключа YAML → не читається" f.dup 2 "дубльований ключ"
NOLIB="${TMP}/nolib"; mkdir -p "${NOLIB}"; cp "${ROUTE}" "${NOLIB}/"
out="$(env -u STRW_ENGINE_LIB STRW_ROOT=/nonexistent bash "${NOLIB}/autonomy-route.sh" "${S}/engine/items/f.base.yaml")"; rc=$?
if [ "${rc}" = 2 ] && printf '%s' "${out}" | /usr/bin/grep -q 'yaml_nodup.py'; then ok "без lib/ → rc 2 з назвою читача"; else bad "без lib/ мав би дати rc 2" "rc=${rc} ${out}"; fi
HALF="${TMP}/halflib"; mkdir -p "${HALF}/lib"; cp "${ROUTE}" "${HALF}/"; cp "${HERE}/lib/yaml_nodup.py" "${HALF}/lib/"
out="$(env -u STRW_ENGINE_LIB STRW_ROOT=/nonexistent bash "${HALF}/autonomy-route.sh" "${S}/engine/items/f.base.yaml")"; rc=$?
if [ "${rc}" = 2 ] && printf '%s' "${out}" | /usr/bin/grep -q 'item_fields.py'; then ok "стара lib/ (лише yaml_nodup.py) → rc 2, не трейсбек"; else bad "неповна lib/ мала б дати rc 2" "rc=${rc} ${out}"; fi

# читач падає посеред виміру (трейсбек) → rc 2 «упав», не rc 1 і не кілька рядків
FAKE="${TMP}/fakelib"; mkdir -p "${FAKE}"; cp "${HERE}/lib/"*.py "${FAKE}/"
printf '\ndef form_errors(it):\n    raise RuntimeError("проба")\n' >> "${FAKE}/item_fields.py"
out="$(STRW_ENGINE_LIB="${FAKE}" bash "${ROUTE}" "${S}/engine/items/f.base.yaml")"; rc=$?
n="$(printf '%s\n' "${out}" | /usr/bin/grep -c .)"
if [ "${rc}" = 2 ] && [ "${n}" = 1 ] && printf '%s' "${out}" | /usr/bin/grep -q 'маршрутизатор упав'; then ok "трейсбек читача → rc 2, один рядок"; else bad "трейсбек мав би дати rc 2 одним рядком" "rc=${rc} рядків=${n} ${out}"; fi

# обгортка: рядок не відповідає коду, або код поза 0/1/2 — rc 2, а не прохід
shape() { # shape <назва> <python-тіло form_errors>
    local FK="${TMP}/shape-$1"; mkdir -p "${FK}"; cp "${HERE}/lib/"*.py "${FK}/"
    printf '\ndef form_errors(it):\n    %s\n' "$2" >> "${FK}/item_fields.py"
    local o r; o="$(STRW_ENGINE_LIB="${FK}" bash "${ROUTE}" "${S}/engine/items/f.base.yaml")"; r=$?
    if [ "${r}" = 2 ] && printf '%s' "${o}" | /usr/bin/grep -q 'маршрутизатор упав'; then ok "обгортка: $1 → rc 2"; else bad "обгортка: $1 мала б дати rc 2" "rc=${r} ${o}"; fi
}
shape "«unattended» з кодом 3"     'import sys; print("unattended"); sys.exit(3)'
shape "«unattended» з кодом 1"     'import sys; print("unattended"); sys.exit(1)'
shape "«with-ceo» з кодом 0"       'import sys; print("with-ceo: x"); sys.exit(0)'
shape "два рядки з кодом 1"        'print("зайвий рядок"); return ["x"]'
# причина з переносом рядка (значення з YAML) — усе одно ОДИН рядок і rc 1, не «упав»
gen f.nl-reason 'it["blocked_by"]=["ceo:перший\nдругий"]; it["state"]="blocked"'
route "перенос рядка в значенні поля → причина одним рядком" f.nl-reason 1 "чекає рішення CEO (ceo:перший другий)"
# валідатор поруч не доміряв (rc 2 або без підсумку) — rc 2, а не «претензій немає»
for stub in 'exit 2' 'echo OK; exit 0'; do
    SD="${TMP}/stubv-$(printf '%s' "${stub}" | tr -cd 'a-z0-9')"; mkdir -p "${SD}"; cp -R "${HERE}/lib" "${SD}/lib"; cp "${ROUTE}" "${SD}/"
    printf '#!/usr/bin/env bash\n%s\n' "${stub}" > "${SD}/validate-items.sh"
    out="$(bash "${SD}/autonomy-route.sh" "${S}/engine/items/f.base.yaml")"; rc=$?
    if [ "${rc}" = 2 ] && printf '%s' "${out}" | /usr/bin/grep -q 'validate-items.sh не доміряв'; then ok "валідатор «${stub}» → rc 2"; else bad "валідатор «${stub}» мав би дати rc 2" "rc=${rc} ${out}"; fi
done
out="$(bash "${ROUTE}" "$(printf 'a\nb.yaml')")"; rc=$?; n="$(printf '%s\n' "${out}" | /usr/bin/grep -c .)"
if [ "${rc}" = 2 ] && [ "${n}" = 1 ]; then ok "аргумент із переносом рядка → rc 2 одним рядком"; else bad "перенос рядка в аргументі зламав контракт" "rc=${rc} рядків=${n} ${out}"; fi
OUTSIDE="${TMP}/outside"; mkdir -p "${OUTSIDE}"; cp "${S}/engine/items/f.base.yaml" "${OUTSIDE}/"
out="$(bash "${ROUTE}" "${OUTSIDE}/f.base.yaml" --engine-dir "${S}/engine")"; rc=$?
if [ "${rc}" = 2 ] && printf '%s' "${out}" | /usr/bin/grep -q 'не лежить у реєстрі'; then ok "елемент поза <engine-dir>/items → rc 2"; else bad "елемент поза реєстром мав би дати rc 2" "rc=${rc} ${out}"; fi

# --plan-sha: той самий хеш, що в plan_review базового; зміна плану — інший хеш
want="$(python3 -c 'import yaml,sys; print(yaml.safe_load(open(sys.argv[1]))["plan_review"]["sha"])' "${S}/engine/items/f.base.yaml")"
got="$(bash "${ROUTE}" --plan-sha "${S}/engine/items/f.base.yaml")"; got2="$(bash "${ROUTE}" --plan-sha "${S}/engine/items/f.r-sha.yaml")"
if [ "${got}" = "${want}" ] && [ "${got2}" != "${want}" ]; then ok "--plan-sha = plan_review.sha базового; змінений план — інший хеш"; else bad "--plan-sha розійшовся" "want=${want} got=${got} got2=${got2}"; fi

# ---------- validate-items.sh: форма нових полів і готовність unattended → ERROR ----------
if [ ! -d "${STRW_ROOT}/strw-factory/.git" ]; then
    echo "SKIP · немає клону ${STRW_ROOT}/strw-factory — валідаторна частина не міряється"
else
    vcase() { # vcase <назва> <id> <правка> <очікую: clean|фрагмент ERROR>
        rm -f "${S}/engine/items/"*.yaml; gen "$2" "$3"
        local out rc; out="$(STRW_ROOT="${STRW_ROOT}" bash "${V}" "${S}/engine" 2>&1)"; rc=$?
        if [ "$4" = clean ]; then
            if [ "${rc}" = 0 ] && ! printf '%s' "${out}" | /usr/bin/grep -q '^ERROR'; then ok "validate-items: $1 → чисто"
            else bad "validate-items: $1 мав би бути чистим" "rc=${rc} $(printf '%s' "${out}" | /usr/bin/grep -E '^(ERROR|STALE)' | head -3)"; fi
        elif [ "${rc}" != 0 ] && printf '%s' "${out}" | /usr/bin/grep -E "^ERROR: $2\.yaml: " | /usr/bin/grep -qF -- "$4"; then ok "validate-items: $1 → ERROR «$4»"
        else bad "validate-items: $1 мав би дати ERROR «$4»" "rc=${rc} $(printf '%s' "${out}" | /usr/bin/grep -E '^(ERROR|STALE)' | head -3)"; fi
    }
    vcase "контроль: базовий unattended"                 v.base   'pass'                                  clean
    vcase "touches з невідомим значенням"                v.touch  'it["touches"]=["mony"]'                "touches має невідомі значення"
    vcase "autonomy з одруком"                           v.auto   'it["autonomy"]="unatended"'            "autonomy = 'unatended'"
    vcase "unattended без tests_spec"                    v.ts     'del it["tests_spec"]'                  "готовність до A неповна — немає tests_spec"
    vcase "близнюк: без tests_spec, але й без autonomy"  v.ts-b   'del it["tests_spec"]; del it["autonomy"]' clean
    vcase "unattended без not_in_scope"                  v.nis    'del it["not_in_scope"]'                "немає not_in_scope"
    vcase "unattended без plan"                          v.plan   'del it["plan"]'                        "немає plan"
    vcase "unattended без plan_review"                   v.pr     'del it["plan_review"]'                 "немає plan_review"
    vcase "unattended: план змінено після рев'ю"         v.sha    'it["plan"]["order"].append("ще")'      "plan_review.sha не дорівнює"
    vcase "близнюк: план змінено і перерецензовано"      v.sha-b  'it["plan"]["order"].append("ще"); resha()' clean
    vcase "unattended без budget"                        v.bud    'del it["budget"]'                      "немає budget"
    vcase "budget.max_cycles = 0"                        v.bud0   'it["budget"]["max_cycles"]=0'          "budget.max_cycles"
    vcase "tests_spec без cmd"                           v.tsk    'del it["tests_spec"][0]["cmd"]; resha()' "tests_spec[0].cmd"
    vcase "unattended: критерій змінено після рев'ю"     v.acc    'it["acceptance"]+="- ще\n"'             "plan_review.sha не дорівнює"
    vcase "plan_review.sha не hex"                       v.shaf   'it["plan_review"]["sha"]="abc"'        "plan_review.sha = 'abc'"
fi

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
