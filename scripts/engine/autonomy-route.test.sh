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
  "tests_spec": [{"name": "x_is_true", "red_when": "X хибне", "negative_control": "X=const"}],
  "plan_review": {"verdict": "PASS", "by": "opus", "at": "2026-10-20", "sha": None},
  "budget": {"max_cycles": 2, "max_hours": 3},
}
it["plan_review"]["sha"] = plan_sha(it["plan"])
def resha(): it["plan_review"]["sha"] = plan_sha(it["plan"])
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
printf -- '---\nstatus: open\n---\nлише про f.triaged-two.\n' > "${S}/triage/open/tri-900.md"
route "близнюк: картка називає f.triaged-two (довший id)" f.triaged 0 "unattended"
rm -f "${S}/triage/open/tri-900.md"; printf -- 'про f.triaged\n' > "${S}/triage/resolved/tri-901.md"
route "близнюк: картка про елемент закрита (resolved/)"  f.triaged 0 "unattended"
mv "${S}/triage/open" "${S}/triage/open.off"
route "немає triage/open — не поміряно, не «вільно»"       f.triaged 2 "triage/open"
mv "${S}/triage/open.off" "${S}/triage/open"

gen f.fresh
printf -- '---\naffects: [product:other]\n---\n## 2026-10-19 · dec-002 · не про фабрику\n' > "${S}/decisions/2026/dec-002-b.md"
route "близнюк: дописане рішення не торкається елемента" f.fresh 0 "unattended"
printf -- '---\naffects: [factory]\n---\n## 2026-10-19 · dec-002 · про фабрику\n' > "${S}/decisions/2026/dec-002-b.md"
route "дописане рішення торкається елемента → STALE"     f.fresh 1 "підстава застаріла"
printf -- '---\nid: dec-002\n---\n## 2026-10-19 · dec-002 · без affects\n' > "${S}/decisions/2026/dec-002-b.md"
route "вузол без affects торкається всього (стара семантика) → STALE" f.fresh 1 "підстава застаріла"
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
gen f.r-ts-bad 'it["tests_spec"]=[{"name":"t"}]';              route "§3 tests_spec без негативного контролю" f.r-ts-bad 1 "negative_control"
gen f.r-pr 'del it["plan_review"]';                            route "§3 немає plan_review"             f.r-pr 1 "немає plan_review"
gen f.r-pwn 'it["plan_review"]["verdict"]="PASS-WITH-NOTES"';  route "§3 план без PASS"                 f.r-pwn 1 "не має PASS"
gen f.r-sha 'it["plan"]["files"].append("docs/z.md")';         route "§3 план змінено після рев'ю"      f.r-sha 1 "план змінено після рев'ю"
gen f.r-resha 'it["plan"]["files"].append("docs/z.md"); resha()'; route "близнюк: план змінено і перерецензовано" f.r-resha 0 "unattended"
gen f.r-budget 'del it["budget"]';                             route "§3 немає budget"                  f.r-budget 1 "немає budget"

# §2.3 «великий» за 6a — за plan.files
big() { gen "f.big-$1" "it['plan']['files']=['docs/x.md', '$2']; resha()"; route "6a: $3 ($2)" "f.big-$1" 1 "$4"; }
big contract   "contract/api.yaml"                          "контракт"            "контракт"
big migration  "backend/supabase/migrations/20261020_x.sql" "міграція"            "міграцію"
big crypto     "App/Sources/Crypto/Provider.swift"          "крипто"              "крипто або ключі"
big keys       "App/Sources/Spaces/SpaceKeys.swift"         "ключі простору"      "крипто або ключі"
big check      "scripts/event-coverage-check.sh"            "*-check.sh"          "вимірювальний інструмент"
big gates      "gates.json"                                 "gates*.json"         "вимірювальний інструмент"
big hooks      ".claude/hooks/release-guard.sh"             ".claude/hooks/**"    "вимірювальний інструмент"
big route      "scripts/engine/autonomy-route.sh"           "сам маршрутизатор"   "вимірювальний інструмент"
gen f.big-twin "it['plan']['files']=['docs/contracting.md', 'App/Sources/Keypad.swift']; resha()"
route "близнюк: contracting.md і Keypad.swift — не контракт і не ключі" f.big-twin 0 "unattended"
gen f.big-16 "it['plan']['files']=['docs/f%02d.md' % i for i in range(16)]; resha()"; route "6a: 16 файлів"  f.big-16 1 "16 файлів"
gen f.big-15 "it['plan']['files']=['docs/f%02d.md' % i for i in range(15)]; resha()"; route "близнюк: 15 файлів" f.big-15 0 "unattended"
gen f.mask "it['plan']['files']=['scripts/*.sh']; resha()";    route "план із маскою"                   f.mask 1 "маску або теку"
gen f.dir "it['plan']['files']=['scripts']; resha()";          route "план із текою без слеша"          f.dir 1 "маску або теку"

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
    vcase "tests_spec із чужим ключем"                   v.tsk    'it["tests_spec"][0]["why"]="x"'        "непізнані ключі ['why']"
    vcase "plan_review.sha не sha256"                    v.shaf   'it["plan_review"]["sha"]="abc"'        "plan_review.sha = 'abc'"
fi

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
