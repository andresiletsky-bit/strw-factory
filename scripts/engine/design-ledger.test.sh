#!/usr/bin/env bash
# design-ledger.test.sh — реєстр версій макетів продукту (dec-115: «що в проді, що вже змінено —
# старий дизайн, що в роботі, що ще буде»). Кожен випадок міняє ОДНУ річ у зеленому реєстрі й
# звіряє ПРИЧИНУ; коди виходу — 0 · 1 правило · 2 форма · 3 джерело нечитане · 4 архів неповний.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
L="${HERE}/design-ledger.py"
pass=0; fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
ok()  { pass=$((pass+1)); printf 'PASS · %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL · %s\n%s\n' "$1" "${2:-}"; }

# --- світ: парасолька з репо продукту (git-історія + архів) і реєстром елементів -------------
R="${TMP}/root"; P="${R}/p-ios"; mkdir -p "${P}/design-reference" "${R}/strw-state/engine/items"
git -C "${P}" init -q && git -C "${P}" config user.email t@t && git -C "${P}" config user.name t
printf '<html>v1</html>\n' > "${P}/design-reference/Canvas.dc.html"
git -C "${P}" add -A && git -C "${P}" commit -qm v1
V1="$(git -C "${P}" rev-parse --short HEAD)"
printf '<html>v2</html>\n' > "${P}/design-reference/Canvas.dc.html"
git -C "${P}" commit -qam v2
V2="$(git -C "${P}" rev-parse --short HEAD)"
V2SHA="$(git -C "${P}" show "${V2}:design-reference/Canvas.dc.html" | python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
A="${P}/design-archive/p-001.review@2026-08-19"; mkdir -p "${A}"
printf '<html>review</html>\n' > "${A}/index.html"
printf 'ledger=p-001.review@2026-08-19\nsource=x\nsha256  00  index.html\n' > "${A}/MANIFEST"
printf 'schema_version: 1\nid: p-001.design.home-v3\n' > "${R}/strw-state/engine/items/p-001.design.home-v3.yaml"
mkdir -p "${P}/design-archive/p-001.bare@2026-01-01" "${P}/design-archive/p-001.misnamed@2026-01-01"
printf '<html>bare</html>\n' > "${P}/design-archive/p-001.bare@2026-01-01/index.html"
printf 'ledger=p-001.other@2026-01-01\nsource=x\n' > "${P}/design-archive/p-001.misnamed@2026-01-01/MANIFEST"

green() { cat <<Y
schema_version: 1
product: p-001
features:
  - {id: home, title: "Б.1 Головна"}
  - {id: kit, title: "Дизайн-система"}
entries:
  - id: p-001.canvas@2026-07-21
    title: "Canvas, перший експорт"
    kind: screens
    features: [home]
    status: superseded
    date: 2026-07-21
    sources:
      - {git: "p-ios@${V1}:design-reference/Canvas.dc.html"}
    superseded_by: p-001.canvas@2026-10-20
  - id: p-001.canvas@2026-10-20
    title: "Canvas після back-sync"
    kind: screens
    features: [home]
    status: live
    date: 2026-10-20
    live_evidence: "p-ios main@${V2}"
    sources:
      - {git: "p-ios@${V2}:design-reference/Canvas.dc.html", sha256: "${V2SHA}"}
    supersedes: [p-001.canvas@2026-07-21]
  - id: p-001.home@v3
    title: "Головна v3"
    kind: screens
    features: [home]
    status: in-work
    date: 2026-10-29
    sources:
      - {artifact: "https://claude.ai/artifact/XyZ", version: "1-a"}
    items: [p-001.design.home-v3]
  - id: p-001.templates@2026-10-20
    title: "10 шаблонів договору"
    kind: templates
    features: [home]
    status: planned
    date: 2026-10-20
    plan_ref: dec-049
  - id: p-001.home-option-b@2026-10-29
    title: "Головна, варіант Б"
    kind: screens
    features: [home]
    status: not-taken
    date: 2026-10-29
    sources:
      - {path: "p-ios/design-archive/p-001.review@2026-08-19"}
    return_if: "якщо конверсія з порожнього стану < 20%"
    note: "архівна тека позичена для фікстури"
  - id: p-001.review@2026-08-19
    title: "Ревʼю кнопок"
    kind: review
    features: [kit]
    status: superseded
    date: 2026-08-19
    sources:
      - {path: "p-ios/design-archive/p-001.review@2026-08-19"}
    superseded_by: p-001.ds@2026-10-29
  - id: p-001.ds@2026-10-29
    title: "Дизайн-система в Claude"
    kind: design-system
    features: [kit]
    status: live
    date: 2026-10-29
    live_evidence: "p-ios main@${V2}"
    sources:
      - {artifact: "https://claude.ai/artifact/DS1", version: "3"}
      - {git: "p-ios@${V2}:design-reference/Canvas.dc.html"}
    supersedes: [p-001.review@2026-08-19]
Y
}
run() { # run <назва> <rc> <фрагмент або ""> <файл> [ще аргументи]
    local name=$1 want=$2 msg=$3 f=$4 out rc; shift 4
    out="$(python3 "$L" "$f" --repo-root "$R" --items "$R/strw-state/engine/items" --today 2026-10-29 "$@" 2>&1)"; rc=$?
    if [ "$rc" -eq "$want" ] && { [ -z "$msg" ] || printf '%s' "$out" | grep -qF -- "$msg"; }; then ok "$name"
    else bad "$name" "rc=$rc (чекали $want) · $out"; fi
}
edit() { # edit <файл> <python над `d`> — реєстр з ОДНІЄЮ зміною
    green > "$1"
    python3 - "$1" "$2" <<'PY'
import sys, yaml
p, expr = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(p))
E = {e["id"]: e for e in d["entries"]}
exec(expr)
yaml.safe_dump(d, open(p, "w"), allow_unicode=True, sort_keys=False)
PY
}

green > "$TMP/green.yaml"
run "зелений реєстр — усі п'ять станів" 0 "реєстр макетів у формі" "$TMP/green.yaml"

edit "$TMP/f1.yaml" "E['p-001.canvas@2026-10-20']['status']='in-work'; E['p-001.canvas@2026-10-20']['items']=['p-001.design.home-v3']; E['p-001.home@v3']['status']='live'; E['p-001.home@v3']['live_evidence']='x'"
run "live без незмінного джерела" 1 "p-001.home@v3: live без незмінного джерела" "$TMP/f1.yaml"

edit "$TMP/f2.yaml" "E['p-001.canvas@2026-07-21']['status']='live'; E['p-001.canvas@2026-07-21']['live_evidence']='x'; del E['p-001.canvas@2026-07-21']['superseded_by']; E['p-001.canvas@2026-10-20']['supersedes']=[]"
run "два live на одну фічу й вид" 1 "дві live-версії для home/screens: p-001.canvas@2026-07-21, p-001.canvas@2026-10-20" "$TMP/f2.yaml"

edit "$TMP/f3.yaml" "del E['p-001.canvas@2026-07-21']['superseded_by']"
run "superseded без наступника" 1 "p-001.canvas@2026-07-21: superseded без superseded_by" "$TMP/f3.yaml"

edit "$TMP/f4.yaml" "E['p-001.canvas@2026-10-20']['supersedes']=[]"
run "наступник не знає попередника" 1 "p-001.canvas@2026-07-21: superseded_by p-001.canvas@2026-10-20, а той не має його в supersedes" "$TMP/f4.yaml"

edit "$TMP/f5.yaml" "del E['p-001.canvas@2026-10-20']['live_evidence']"
run "live без доказу проду" 1 "p-001.canvas@2026-10-20: live без live_evidence" "$TMP/f5.yaml"

edit "$TMP/f6.yaml" "E['p-001.home@v3']['items']=[]"
run "in-work без елемента реєстру" 1 "p-001.home@v3: in-work без items" "$TMP/f6.yaml"

edit "$TMP/f7.yaml" "E['p-001.home@v3']['items']=['p-001.design.ghost']"
run "in-work з неіснуючим елементом" 1 "p-001.home@v3: елемента p-001.design.ghost немає в реєстрі" "$TMP/f7.yaml"

edit "$TMP/f8.yaml" "del E['p-001.templates@2026-10-20']['plan_ref']"
run "planned без підстави" 1 "p-001.templates@2026-10-20: planned без plan_ref" "$TMP/f8.yaml"

edit "$TMP/f9.yaml" "del E['p-001.home-option-b@2026-10-29']['return_if']"
run "not-taken без умови повернення" 1 "p-001.home-option-b@2026-10-29: not-taken без return_if" "$TMP/f9.yaml"

edit "$TMP/f10.yaml" "E['p-001.home@v3']['features']=['nowhere']"
run "фіча, якої немає в переліку" 1 "p-001.home@v3: фіча nowhere не оголошена" "$TMP/f10.yaml"

edit "$TMP/f11.yaml" "E['p-001.home@v3']['status']='archived'"
run "невідомий стан" 1 "p-001.home@v3: status='archived'" "$TMP/f11.yaml"

edit "$TMP/f12.yaml" "E['p-001.canvas@2026-10-20']['date']='2026-07-01'"
run "наступник старший за попередника" 1 "p-001.canvas@2026-07-21: замінена версією, датованою раніше" "$TMP/f12.yaml"

edit "$TMP/f13.yaml" "E['p-001.canvas@2026-07-21']['sources']=[{'git':'p-ios@0000000:design-reference/Canvas.dc.html'}]"
run "git-джерело, якого немає" 3 "p-001.canvas@2026-07-21: p-ios@0000000:design-reference/Canvas.dc.html не читається" "$TMP/f13.yaml"

edit "$TMP/f14.yaml" "E['p-001.canvas@2026-10-20']['sources'][0]['sha256']='00'"
run "git-джерело з іншим вмістом" 1 "p-001.canvas@2026-10-20: p-ios@" "$TMP/f14.yaml"

edit "$TMP/f15.yaml" "E['p-001.review@2026-08-19']['sources']=[{'path':'p-ios/design-archive/p-001.other@2026-01-01'}]"
run "архівна тека, якої немає" 3 "p-001.review@2026-08-19: p-ios/design-archive/p-001.other@2026-01-01 не читається" "$TMP/f15.yaml"

edit "$TMP/f16.yaml" "E['p-001.review@2026-08-19']['sources']=[]; E['p-001.review@2026-08-19']['snapshot_pending']={'what':'експорт з Claude Design','by':'2026-12-14'}"
run "чесна дірка архіву — код 4, не зелене" 4 "p-001.review@2026-08-19: знімка ще немає — експорт з Claude Design, до 2026-12-14" "$TMP/f16.yaml"

edit "$TMP/f17.yaml" "E['p-001.review@2026-08-19']['sources']=[]; E['p-001.review@2026-08-19']['snapshot_pending']={'what':'експорт','by':'2026-10-01'}"
run "прострочена дірка архіву — правило" 1 "p-001.review@2026-08-19: знімок прострочено (до 2026-10-01)" "$TMP/f17.yaml"

edit "$TMP/f18.yaml" "E['p-001.home@v3']['id']='p-001.canvas@2026-10-20'"
run "id повторюється" 1 "p-001.canvas@2026-10-20: id повторюється" "$TMP/f18.yaml"

# форма реєстру й записів — кожне правило свідком (мутаційний прогін: без цих випадків 18 guard'ів жили)
edit "$TMP/g1.yaml" "d['schema_version']=2"
run "schema_version не 1" 1 "schema_version має бути 1" "$TMP/g1.yaml"
edit "$TMP/g2.yaml" "del d['product']"
run "немає product" 1 "немає product" "$TMP/g2.yaml"
edit "$TMP/g3.yaml" "d['features'].append({'id':'home','title':'x'})"
run "фіча оголошена двічі" 1 "фіча home оголошена двічі" "$TMP/g3.yaml"
edit "$TMP/g4.yaml" "d['entries']=[]"
run "порожній реєстр" 1 "entries має бути непорожнім списком" "$TMP/g4.yaml"
edit "$TMP/g5.yaml" "E['p-001.home@v3']['kind']='screen'"
run "невідомий вид" 1 "p-001.home@v3: kind='screen'" "$TMP/g5.yaml"
edit "$TMP/g6.yaml" "E['p-001.home@v3']['date']='29.10.2026'"
run "дата не ISO" 1 "p-001.home@v3: date має бути YYYY-MM-DD" "$TMP/g6.yaml"
edit "$TMP/g7.yaml" "E['p-001.templates@2026-10-20']['features']=[]"
run "версія без фічі" 1 "p-001.templates@2026-10-20: немає features" "$TMP/g7.yaml"
edit "$TMP/g8.yaml" "E['p-001.review@2026-08-19']['sources']=[]; E['p-001.review@2026-08-19']['snapshot_pending']={'what':'експорт'}"
run "snapshot_pending без терміну" 1 "p-001.review@2026-08-19: snapshot_pending потребує what і by" "$TMP/g8.yaml"
edit "$TMP/g9.yaml" "E['p-001.canvas@2026-07-21']['superseded_by']='p-001.ghost'"
run "наступника немає в реєстрі" 1 "p-001.canvas@2026-07-21: superseded_by p-001.ghost — такого запису немає" "$TMP/g9.yaml"
edit "$TMP/g10.yaml" "E['p-001.canvas@2026-10-20']['supersedes'].append('p-001.ghost')"
run "попередника немає в реєстрі" 1 "p-001.canvas@2026-10-20: supersedes p-001.ghost — такого запису немає" "$TMP/g10.yaml"
edit "$TMP/g11.yaml" "E['p-001.ds@2026-10-29']['supersedes'].append('p-001.canvas@2026-07-21')"
run "попередник не знає наступника" 1 "p-001.ds@2026-10-29: supersedes p-001.canvas@2026-07-21, а той не називає його superseded_by" "$TMP/g11.yaml"
edit "$TMP/g12.yaml" "E['p-001.canvas@2026-07-21']['sources']=[{'git':'p-ios:design-reference/Canvas.dc.html'}]"
run "git-джерело без sha" 1 "не у формі <repo>@<sha>:<шлях>" "$TMP/g12.yaml"
edit "$TMP/g13.yaml" "E['p-001.review@2026-08-19']['sources']=[{'path':'p-ios/design-archive/p-001.bare@2026-01-01'}]"
run "архівна тека без MANIFEST" 1 "p-001.review@2026-08-19: архівна тека p-ios/design-archive/p-001.bare@2026-01-01 без MANIFEST" "$TMP/g13.yaml"
edit "$TMP/g14.yaml" "E['p-001.review@2026-08-19']['sources']=[{'path':'p-ios/design-archive/p-001.misnamed@2026-01-01'}]"
run "MANIFEST називає іншу теку" 1 "MANIFEST теки p-ios/design-archive/p-001.misnamed@2026-01-01 не називає її" "$TMP/g14.yaml"
edit "$TMP/g15.yaml" "E['p-001.review@2026-08-19']['sources']=[{'path':'p-ios/design-archive/p-001.review@2026-08-19/index.html','sha256':'00'}]"
run "архівний файл з іншим вмістом" 1 "p-001.review@2026-08-19: p-ios/design-archive/p-001.review@2026-08-19/index.html має інший вміст" "$TMP/g15.yaml"
edit "$TMP/g16.yaml" "E['p-001.home@v3']['sources']=[{'artifact':'https://example.com/x','version':'1'}]"
run "artifact не з claude.ai" 1 "p-001.home@v3: artifact-джерело не claude.ai-посилання" "$TMP/g16.yaml"
edit "$TMP/g17.yaml" "del E['p-001.home@v3']['sources'][0]['version']"
run "artifact без version" 1 "p-001.home@v3: artifact-джерело без version" "$TMP/g17.yaml"
edit "$TMP/g18.yaml" "E['p-001.home@v3']['sources']=[{'figma':'abc'}]"
run "невідомий вид джерела" 1 "p-001.home@v3: невідомий вид джерела" "$TMP/g18.yaml"

printf 'schema_version: 1\nproduct: p\nentries: [\n' > "$TMP/broken.yaml"
run "реєстр не парситься" 2 "не парситься" "$TMP/broken.yaml"

printf 'schema_version: 1\nproduct: p\nentries: []\nproduct: q\n' > "$TMP/dup.yaml"
run "дубль ключа — читач рушія" 2 "дубльований ключ \`product\`" "$TMP/dup.yaml"

# звіт: що в проді, в роботі, заплановано, історія — з того самого реєстру
out="$(python3 "$L" "$TMP/green.yaml" --repo-root "$R" --items "$R/strw-state/engine/items" --today 2026-10-29 --report 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF '## Зараз у проді' \
   && printf '%s' "$out" | grep -qF -- '- Б.1 Головна · screens: p-001.canvas@2026-10-20' \
   && printf '%s' "$out" | grep -qF -- '- p-001.home@v3 — Головна v3 · елементи: p-001.design.home-v3' \
   && printf '%s' "$out" | grep -qF '| 2026-07-21 | p-001.canvas@2026-07-21 | superseded → p-001.canvas@2026-10-20 |'; then ok "звіт: прод, робота, історія з наступником"
else bad "звіт" "rc=$rc · $out"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
