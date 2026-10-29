#!/usr/bin/env bash
# design-ledger.test.sh — реєстр версій макетів продукту (dec-117: «що в проді, що вже змінено —
# старий дизайн, що в роботі, що ще буде»). Кожен випадок міняє ОДНУ річ у зеленому реєстрі й
# звіряє ПРИЧИНУ; коди виходу — 0 · 1 правило (значення) · 2 форма (тип, парсинг) · 3 джерело нечитане ·
# 4 архів неповний.
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
sum() { python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
archive() { # archive <id> <вміст index.html> — тека design-archive/<id>/ з чесним MANIFEST
    local a="${P}/design-archive/$1"; mkdir -p "${a}"
    printf '%s\n' "$2" > "${a}/index.html"
    printf 'ledger=%s\nsource=x\nsha256  %s  index.html\n' "$1" "$(sum "${a}/index.html")" > "${a}/MANIFEST"
}
archive "p-001.review@2026-08-19" '<html>review</html>'
archive "p-001.home-option-b@2026-10-29" '<html>option b</html>'
A="${P}/design-archive/p-001.review@2026-08-19"
printf 'schema_version: 1\nid: p-001.design.home-v3\n' > "${R}/strw-state/engine/items/p-001.design.home-v3.yaml"
mkdir -p "${P}/design-archive/p-001.bare@2026-01-01" "${P}/design-archive/p-001.misnamed@2026-01-01" "${P}/design-reference/sub"
printf '<html>bare</html>\n' > "${P}/design-archive/p-001.bare@2026-01-01/index.html"
printf 'ledger=p-001.other@2026-01-01\nsource=x\n' > "${P}/design-archive/p-001.misnamed@2026-01-01/MANIFEST"
printf '<html>live working copy</html>\n' > "${P}/design-reference/sub/Live.dc.html"
ln -s /Users/someone/Downloads/x.html "${P}/design-reference/Link.dc.html"
git -C "${P}" add design-reference/Link.dc.html && git -C "${P}" commit -qm link
V3="$(git -C "${P}" rev-parse --short HEAD)"
F="${P}/design-reference/p-001.canvas@2026-10-20"; mkdir -p "${F}"; printf 'x\n' > "${F}/index.html"
printf 'ledger=p-001.canvas@2026-10-20\nsha256  %s  index.html\n' "$(python3 -c 'import hashlib;print(hashlib.sha256(b"x\n").hexdigest())')" > "${F}/MANIFEST"

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
      - {path: "p-ios/design-archive/p-001.home-option-b@2026-10-29"}
    return_if: "якщо конверсія з порожнього стану < 20%"
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
run "MANIFEST називає інший запис" 1 "MANIFEST теки p-ios/design-archive/p-001.misnamed@2026-01-01 не називає ledger=p-001.review@2026-08-19" "$TMP/g14.yaml"
edit "$TMP/g14b.yaml" "E['p-001.home-option-b@2026-10-29']['sources']=[{'path':'p-ios/design-archive/p-001.review@2026-08-19'}]"
run "позичена архівна тека чужого запису" 1 "p-001.home-option-b@2026-10-29: архівна тека p-ios/design-archive/p-001.review@2026-08-19 належить іншому запису" "$TMP/g14b.yaml"
edit "$TMP/g15.yaml" "E['p-001.review@2026-08-19']['sources']=[{'path':'p-ios/design-reference/sub/Live.dc.html','sha256':'00'}]"
run "файл із сумою, вміст інший" 1 "p-001.review@2026-08-19: p-ios/design-reference/sub/Live.dc.html має інший вміст, ніж записаний sha256" "$TMP/g15.yaml"
edit "$TMP/g16.yaml" "E['p-001.home@v3']['sources']=[{'artifact':'https://example.com/x','version':'1'}]"
run "artifact не з claude.ai" 1 "p-001.home@v3: artifact-джерело не claude.ai-посилання" "$TMP/g16.yaml"
edit "$TMP/g17.yaml" "del E['p-001.home@v3']['sources'][0]['version']"
run "artifact без version" 1 "p-001.home@v3: artifact-джерело без version" "$TMP/g17.yaml"
edit "$TMP/g18.yaml" "E['p-001.home@v3']['sources']=[{'figma':'abc'}]"
run "невідомий вид джерела" 1 "p-001.home@v3: невідомий вид джерела" "$TMP/g18.yaml"

# зовнішнє рев'ю (6a, 29.10): кожна знайдена діра — свідком
cp "${A}/index.html" "$TMP/index.bak"; printf '<html>rewritten</html>\n' > "${A}/index.html"
run "файл архіву переписано, MANIFEST старий" 1 "p-001.review@2026-08-19: p-ios/design-archive/p-001.review@2026-08-19/index.html має інший вміст, ніж записано в MANIFEST" "$TMP/green.yaml"
cp "$TMP/index.bak" "${A}/index.html"
printf 'x\n' > "${A}/extra.png"
run "файл в архіві, якого MANIFEST не називає" 1 "у теці p-ios/design-archive/p-001.review@2026-08-19 файл extra.png, якого MANIFEST не називає" "$TMP/green.yaml"
rm -f "${A}/extra.png"
edit "$TMP/h1.yaml" "E['p-001.canvas@2026-10-20']['sources']=[{'path':'p-ios/design-reference/sub/Live.dc.html'}]"
run "live на робочому дереві без суми — не незмінне" 1 "p-001.canvas@2026-10-20: live без незмінного джерела" "$TMP/h1.yaml"
edit "$TMP/h2.yaml" "E['p-001.canvas@2026-10-20']['sources']=[{'path':'p-ios/design-reference/sub/Live.dc.html','sha256':'$(sum "${P}/design-reference/sub/Live.dc.html")'}]"
run "файл робочого дерева з sha256 — незмінний (контроль)" 0 "реєстр макетів у формі" "$TMP/h2.yaml"
edit "$TMP/h3.yaml" "E['p-001.canvas@2026-07-21']['sources']=[{'git':'p-ios@${V1}:design-reference'}]"
run "git-джерело на теку, а не файл" 1 "p-001.canvas@2026-07-21: p-ios@${V1}:design-reference — це tree, а не файл" "$TMP/h3.yaml"
edit "$TMP/h4.yaml" "E['p-001.review@2026-08-19']['sources']=[{'path':'p-ios/../../etc/design-archive/x'}]"
run "path з .. — поза парасолькою" 1 "p-001.review@2026-08-19: path-джерело 'p-ios/../../etc/design-archive/x' виходить за межі парасольки" "$TMP/h4.yaml"
edit "$TMP/h5.yaml" "E['p-001.canvas@2026-07-21']['sources']=[{'git':'..@${V1}:design-reference/Canvas.dc.html'}]"
run "git-репо .. — відкинуто формою (ні «..», ні «-опція» не проходять)" 1 "git-джерело '..@" "$TMP/h5.yaml"
out="$(python3 "$L" "$TMP/green.yaml" --items "$R/strw-state/engine/items" --today 2026-10-29 2>&1)"; rc=$?
if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -qF "p-001.canvas@2026-07-21: p-ios@${V1}:design-reference/Canvas.dc.html не звірено — немає --repo-root" \
   && printf '%s' "$out" | grep -qF 'p-001.review@2026-08-19: p-ios/design-archive/p-001.review@2026-08-19 не звірено — немає --repo-root'; then ok "без --repo-root — код 3 і для git, і для path, не тихий нуль"; else bad "без --repo-root" "rc=$rc · $out"; fi
out="$(python3 "$L" "$TMP/green.yaml" --repo-root "$R" --today 2026-10-29 2>&1)"; rc=$?
if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -qF 'p-001.home@v3: елементи p-001.design.home-v3 не звірено — немає --items'; then ok "без --items — код 3"; else bad "без --items" "rc=$rc · $out"; fi
edit "$TMP/h6.yaml" "E['p-001.canvas@2026-10-20']['superseded_by']='p-001.home@v3'"
run "superseded_by у live-записі" 1 "p-001.canvas@2026-10-20: superseded_by у стані live" "$TMP/h6.yaml"
edit "$TMP/h7.yaml" "E['p-001.review@2026-08-19']['superseded_by']='p-001.home-option-b@2026-10-29'; E['p-001.home-option-b@2026-10-29']['supersedes']=['p-001.review@2026-08-19']; E['p-001.ds@2026-10-29']['supersedes']=[]"
run "наступник — невзятий варіант" 1 "p-001.review@2026-08-19: замінена варіантом not-taken" "$TMP/h7.yaml"
edit "$TMP/h8.yaml" "E['p-001.canvas@2026-10-20']['status']='superseded'; E['p-001.canvas@2026-10-20']['superseded_by']='p-001.canvas@2026-07-21'; E['p-001.canvas@2026-07-21']['supersedes']=['p-001.canvas@2026-10-20']; E['p-001.canvas@2026-07-21']['date']='2026-10-20'; del E['p-001.canvas@2026-10-20']['live_evidence']"
run "цикл замін" 1 "цикл замін" "$TMP/h8.yaml"
edit "$TMP/h9.yaml" "E['p-001.home@v3']['date']='2026-13-45'"
run "дата, якої не буває" 1 "p-001.home@v3: date має бути YYYY-MM-DD" "$TMP/h9.yaml"
run "--today не дата" 2 "--today 'завтра'" "$TMP/green.yaml" --today завтра
edit "$TMP/s1.yaml" "E['p-001.review@2026-08-19']['snapshot_pending']='скоро'"
run "snapshot_pending рядком — не в формі (2), не трейсбек" 2 "p-001.review@2026-08-19: snapshot_pending має бути dict" "$TMP/s1.yaml"
edit "$TMP/s2.yaml" "E['p-001.canvas@2026-07-21']['superseded_by']=['p-001.canvas@2026-10-20']"
run "superseded_by списком — не в формі" 2 "superseded_by має бути str" "$TMP/s2.yaml"
edit "$TMP/s3.yaml" "E['p-001.home@v3']['features']=[{'id':'home'}]"
run "фіча мапою в записі — не в формі" 2 "p-001.home@v3: features — список рядків" "$TMP/s3.yaml"
: > "$TMP/empty.yaml"
run "порожній реєстр — 2, не 1" 2 "порожній" "$TMP/empty.yaml"

# внутрішнє рев'ю (29.10): мутанти, що жили, — свідками
edit "$TMP/m1.yaml" "E['p-001.home-option-b@2026-10-29']['sources']=[{'artifact':'https://claude.ai/artifact/O','version':'1'}]"
run "not-taken без незмінного джерела" 1 "p-001.home-option-b@2026-10-29: not-taken без незмінного джерела" "$TMP/m1.yaml"
edit "$TMP/m2.yaml" "E['p-001.review@2026-08-19']['sources']=[{'claude-design':'proj/Buttons.dc.html'}]"
run "superseded лише з посиланням claude-design" 1 "p-001.review@2026-08-19: superseded без незмінного джерела" "$TMP/m2.yaml"
edit "$TMP/m3.yaml" "E['p-001.canvas@2026-10-20']['date']='2026-07-21'"
run "заміна того самого дня — дозволена (контроль)" 0 "реєстр макетів у формі" "$TMP/m3.yaml"
edit "$TMP/m4.yaml" "E['p-001.review@2026-08-19']['sources']=[]; E['p-001.review@2026-08-19']['snapshot_pending']={'what':'експорт','by':'2026-10-29'}"
run "термін знімка — сьогодні: ще не прострочено" 4 "до 2026-10-29" "$TMP/m4.yaml"
edit "$TMP/m5.yaml" "E['p-001.ds@2026-10-29']['features']=['kit','home']; E['p-001.ds@2026-10-29']['kind']='screens'"
run "дві live на ДРУГУ фічу запису" 1 "дві live-версії для home/screens: p-001.canvas@2026-10-20, p-001.ds@2026-10-29" "$TMP/m5.yaml"
edit "$TMP/m6.yaml" "E['p-001.review@2026-08-19']['sources']=[]; E['p-001.review@2026-08-19']['snapshot_pending']={'by':'2026-12-14'}"
run "snapshot_pending без what" 1 "p-001.review@2026-08-19: snapshot_pending потребує what і by" "$TMP/m6.yaml"
edit "$TMP/m7.yaml" "E['p-001.home@v3']['features']=['home','home']"
run "фіча двічі в одному записі" 1 "p-001.home@v3: фіча повторюється в features" "$TMP/m7.yaml"
edit "$TMP/m8.yaml" "E['p-001.home@v3']['sources'][0]['version']=0"
run "artifact version: 0 — версія є (контроль)" 0 "реєстр макетів у формі" "$TMP/m8.yaml"
edit "$TMP/m9.yaml" "E['p-001.canvas@2026-07-21']['sources']=[{'git':'p-ios@${V1}:../outside.html'}]"
run "git-шлях з .. — поза парасолькою" 1 "p-001.canvas@2026-07-21: git-джерело 'p-ios@${V1}:../outside.html' виходить за межі парасольки" "$TMP/m9.yaml"
edit "$TMP/m10.yaml" "E['p-001.home@v3']['status']='archived'; E['p-001.canvas@2026-07-21']['sources']=[{'git':'p-ios@0000000:design-reference/Canvas.dc.html'}]"
out="$(python3 "$L" "$TMP/m10.yaml" --repo-root "$R" --items "$R/strw-state/engine/items" --today 2026-10-29 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF "ERROR: p-001.home@v3: status='archived'" && printf '%s' "$out" | grep -qF 'UNREAD: p-001.canvas@2026-07-21'; then ok "правило і нечитане джерело разом — код 1, обидва рядки"
else bad "старшинство кодів" "rc=$rc · $out"; fi

# генеративний мутаційний прогін (29.10): решта гілок — свідками
cp "${A}/MANIFEST" "$TMP/manifest.bak"; printf 'sha256  %s  gone.html\n' "$(printf x | python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')" >> "${A}/MANIFEST"
run "MANIFEST називає файл, якого в теці немає" 1 "p-001.review@2026-08-19: MANIFEST теки p-ios/design-archive/p-001.review@2026-08-19 називає gone.html, якого в теці немає" "$TMP/green.yaml"
cp "$TMP/manifest.bak" "${A}/MANIFEST"
mv "${A}/index.html" "$TMP/index.keep"; grep -v '^sha256' "$TMP/manifest.bak" > "${A}/MANIFEST"
run "архівна тека без жодного знімка" 1 "p-001.review@2026-08-19: архівна тека p-ios/design-archive/p-001.review@2026-08-19 порожня" "$TMP/green.yaml"
mv "$TMP/index.keep" "${A}/index.html"; cp "$TMP/manifest.bak" "${A}/MANIFEST"
edit "$TMP/n1.yaml" "E['p-001.templates@2026-10-20']['sources']=[{'path':'p-ios/design-reference/missing.html'}]"
run "path у робоче дерево, якого немає" 3 "p-001.templates@2026-10-20: p-ios/design-reference/missing.html не читається" "$TMP/n1.yaml"
edit "$TMP/n2.yaml" "d['features'].append({'title':'без id'})"
run "фіча без id" 1 "features: кожна фіча — {id, title}" "$TMP/n2.yaml"
edit "$TMP/n3.yaml" "d['entries'].append({'status':'planned'})"
run "запис без id" 1 "entries[7]: немає id" "$TMP/n3.yaml"

# повторне рев'ю дельти (29.10): решта шляхів — свідками
OB="${P}/design-archive/p-001.home-option-b@2026-10-29"
edit "$TMP/r1.yaml" "E['p-001.home-option-b@2026-10-29']['sources']=[{'path':'p-ios/design-archive/p-001.review@2026-08-19/index.html','sha256':'$(sum "${A}/index.html")'}]"
run "файл усередині чужої архівної теки" 1 "p-001.home-option-b@2026-10-29: path 'p-ios/design-archive/p-001.review@2026-08-19/index.html' веде всередину архівної теки" "$TMP/r1.yaml"
edit "$TMP/r2.yaml" "E['p-001.canvas@2026-07-21']['sources']=[{'git':'p-ios@${V3}:design-reference/Link.dc.html'}]"
run "git-джерело — симлінк, а не файл" 1 "p-001.canvas@2026-07-21: p-ios@${V3}:design-reference/Link.dc.html — це симлінк, а не файл" "$TMP/r2.yaml"
mv "${OB}" "$TMP/ob.real"; ln -s "$TMP/ob.real" "${OB}"
run "архівна тека — симлінк" 1 "p-001.home-option-b@2026-10-29: p-ios/design-archive/p-001.home-option-b@2026-10-29 проходить через симлінк" "$TMP/green.yaml"
rm "${OB}"; mv "$TMP/ob.real" "${OB}"; cp "${OB}/MANIFEST" "$TMP/ob.manifest"
ln -s ../../design-reference/sub/Live.dc.html "${OB}/live.html"
printf 'sha256  %s  live.html\n' "$(sum "${P}/design-reference/sub/Live.dc.html")" >> "${OB}/MANIFEST"
run "файл архіву — симлінк на робоче дерево" 1 "p-001.home-option-b@2026-10-29: p-ios/design-archive/p-001.home-option-b@2026-10-29/live.html — симлінк" "$TMP/green.yaml"
rm "${OB}/live.html"; cp "$TMP/ob.manifest" "${OB}/MANIFEST"
mkdir -p "${OB}/assets"; printf 'png\n' > "${OB}/assets/a.png"; printf 'mac\n' > "${OB}/.DS_Store"
run "файл без рядка в MANIFEST у підтеці" 1 "у теці p-ios/design-archive/p-001.home-option-b@2026-10-29 файл assets/a.png, якого MANIFEST не називає" "$TMP/green.yaml"
printf 'sha256  %s  assets/a.png\n' "$(sum "${OB}/assets/a.png")" >> "${OB}/MANIFEST"
run "підтека з рядком у MANIFEST, .DS_Store поруч — зелено (контроль)" 0 "реєстр макетів у формі" "$TMP/green.yaml"
printf 'sha256  %s  assets/a.png\n' "$(sum "${OB}/index.html")" >> "${OB}/MANIFEST"
run "MANIFEST називає файл двічі" 1 "MANIFEST теки p-ios/design-archive/p-001.home-option-b@2026-10-29 називає assets/a.png двічі" "$TMP/green.yaml"
rm -rf "${OB}/assets" "${OB}/.DS_Store"; cp "$TMP/ob.manifest" "${OB}/MANIFEST"
printf '\xff\n' >> "${OB}/MANIFEST"
run "MANIFEST не UTF-8" 1 "MANIFEST теки p-ios/design-archive/p-001.home-option-b@2026-10-29 не UTF-8" "$TMP/green.yaml"
cp "$TMP/ob.manifest" "${OB}/MANIFEST"
edit "$TMP/r3.yaml" "E['p-001.canvas@2026-10-20']['sources']=[{'path':'p-ios/design-reference/p-001.canvas@2026-10-20'}]"
run "тека з MANIFEST поза design-archive — не знімок" 1 "p-001.canvas@2026-10-20: live без незмінного джерела" "$TMP/r3.yaml"
edit "$TMP/r4.yaml" "E['p-001.review@2026-08-19']['sources']=[{'path':'/etc/hostname','sha256':'00'}]"
run "абсолютний path" 1 "p-001.review@2026-08-19: path-джерело '/etc/hostname' виходить за межі парасольки" "$TMP/r4.yaml"
edit "$TMP/r5.yaml" "E['p-001.home@v3']['items']=['$R/strw-state/engine/items/p-001.design.home-v3']"
run "елемент in-work абсолютним шляхом (файл існує) — не з реєстру" 1 "p-001.home@v3: елемента $R/strw-state/engine/items/p-001.design.home-v3 немає в реєстрі" "$TMP/r5.yaml"
edit "$TMP/r6.yaml" "E['p-001.templates@2026-10-20']['sources']=[{'path':'p-ios/design-reference/sub/Live.dc.html'}]"
out="$(python3 "$L" "$TMP/r6.yaml" --items "$R/strw-state/engine/items" --today 2026-10-29 2>&1)"; rc=$?
if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -qF 'p-001.templates@2026-10-20: p-ios/design-reference/sub/Live.dc.html не звірено — немає --repo-root'; then ok "робоче дерево без суми і без --repo-root — теж код 3"
else bad "path без --repo-root" "rc=$rc · $out"; fi
edit "$TMP/r6b.yaml" "E['p-001.canvas@2026-10-20']['sources']=[{'path':'p-ios/design-reference/sub/Live.dc.html'}]"
out="$(python3 "$L" "$TMP/r6b.yaml" --items "$R/strw-state/engine/items" --today 2026-10-29 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'p-001.canvas@2026-10-20: live без незмінного джерела' && printf '%s' "$out" | grep -qF 'UNREAD: p-001.canvas@2026-10-20'; then ok "live лише на робочому дереві без --repo-root — правило (1), бо змінне й без звірки"
else bad "live на робочому дереві без --repo-root" "rc=$rc · $out"; fi
edit "$TMP/r7.yaml" "E['p-001.templates@2026-10-20']['live_evidence']='main@abc'"
run "live_evidence не в live" 1 "p-001.templates@2026-10-20: live_evidence у стані planned" "$TMP/r7.yaml"
edit "$TMP/r8.yaml" "E['p-001.canvas@2026-10-20']['items']=['p-001.design.home-v3']"
run "items не в in-work" 1 "p-001.canvas@2026-10-20: items у стані live" "$TMP/r8.yaml"
edit "$TMP/r9.yaml" "E['p-001.canvas@2026-10-20']['snapshot_pending']={'what':'x','by':'2026-12-14'}"
run "live з snapshot_pending" 1 "p-001.canvas@2026-10-20: live з snapshot_pending" "$TMP/r9.yaml"
edit "$TMP/r10.yaml" "d['schema_version']=True"
run "schema_version: true — не 1" 1 "schema_version має бути 1" "$TMP/r10.yaml"
edit "$TMP/r11.yaml" "d['product']={'a':1}"
run "product не рядок" 1 "немає product" "$TMP/r11.yaml"
edit "$TMP/r12.yaml" "E['p-001.canvas@2026-07-21']['sources'][0]['path']='/etc/passwd'"
run "джерело з двома видами" 1 "p-001.canvas@2026-07-21: одне джерело — один вид, а тут git, path" "$TMP/r12.yaml"
edit "$TMP/r13.yaml" "d['entries'].append(1)"
run "запис — не мапа: форма (2), не трейсбек" 2 "entries[7]: запис має бути мапою" "$TMP/r13.yaml"
edit "$TMP/r14.yaml" "E['p-001.home@v3']['sources']=['path']"
run "джерело — не мапа: форма (2)" 2 "p-001.home@v3: sources[0] має бути мапою" "$TMP/r14.yaml"
edit "$TMP/r15.yaml" "d['features']='home'"
run "features рядком: форма (2)" 2 "features має бути списком" "$TMP/r15.yaml"
edit "$TMP/r16.yaml" "d['entries']={'a':1}"
run "entries мапою: форма (2)" 2 "entries має бути списком" "$TMP/r16.yaml"
edit "$TMP/r17.yaml" "d['features'][0]['id']=5"
run "id фічі не рядок: форма (2)" 2 "features[0].id має бути рядком" "$TMP/r17.yaml"

# третє рев'ю (29.10): шлях git-джерела точно, симлінки на шляху, форма MANIFEST, колишня live
edit "$TMP/t1.yaml" "E['p-001.canvas@2026-10-20']['sources']=[{'git':'p-ios@${V2}:design-reference/'}]"
run "git-джерело — тека зі скісною в кінці" 1 "p-001.canvas@2026-10-20: git-джерело 'p-ios@${V2}:design-reference/' — шлях на теку" "$TMP/t1.yaml"
edit "$TMP/t2.yaml" "E['p-001.canvas@2026-10-20']['sources']=[{'git':'p-ios@${V2}:design-reference//Canvas.dc.html'}]"
run "git-шлях з подвійною скісною" 1 "p-001.canvas@2026-10-20: git-джерело 'p-ios@${V2}:design-reference//Canvas.dc.html' — шлях на теку, з «//»" "$TMP/t2.yaml"
edit "$TMP/t2c.yaml" "E['p-001.canvas@2026-10-20']['sources']=[{'git':'p-ios@${V2}:design-reference/*.dc.html'}]"
run "git-шлях-маска: pathspec знайшов би файл, але це не той шлях" 3 "p-001.canvas@2026-10-20: p-ios@${V2}:design-reference/*.dc.html не читається" "$TMP/t2c.yaml"
edit "$TMP/t2b.yaml" "E['p-001.canvas@2026-10-20']['sources']=[{'git':'p-ios@${V2}:design-reference'}]"
run "git-джерело — тека без скісної: ls-tree дав дітей, а не її" 1 "p-001.canvas@2026-10-20: p-ios@${V2}:design-reference — це tree, а не файл" "$TMP/t2b.yaml"
ln -s "${A}" "${P}/design-reference/alias"
edit "$TMP/t3.yaml" "E['p-001.home-option-b@2026-10-29']['sources']=[{'path':'p-ios/design-reference/alias/index.html','sha256':'$(sum "${A}/index.html")'}]"
run "файл чужого архіву через симлінк-аліас" 1 "p-001.home-option-b@2026-10-29: p-ios/design-reference/alias/index.html проходить через симлінк" "$TMP/t3.yaml"
rm "${P}/design-reference/alias"
edit "$TMP/t4.yaml" "E['p-001.home-option-b@2026-10-29']['sources']=[{'path':'p-ios/Design-Archive/p-001.review@2026-08-19/index.html','sha256':'$(sum "${A}/index.html")'}]"
run "Design-Archive іншим регістром — те саме правило" 1 "веде всередину архівної теки" "$TMP/t4.yaml"
cp "${OB}/MANIFEST" "$TMP/ob.manifest"; printf 'sha256  %s  a b.html\n' "$(sum "${OB}/index.html")" >> "${OB}/MANIFEST"
run "рядок MANIFEST з пробілом в імені — не у формі" 1 "рядок не у формі" "$TMP/green.yaml"
cp "$TMP/ob.manifest" "${OB}/MANIFEST"; printf 'mac\n' > "${OB}/.DS_Store"; printf 'sha256  %s  .DS_Store\n' "$(sum "${OB}/.DS_Store")" >> "${OB}/MANIFEST"
run ".DS_Store в MANIFEST і на диску — ігнорується з обох боків (контроль)" 0 "реєстр макетів у формі" "$TMP/green.yaml"
rm -f "${OB}/.DS_Store"; cp "$TMP/ob.manifest" "${OB}/MANIFEST"
edit "$TMP/t5.yaml" "E['p-001.canvas@2026-07-21']['live_evidence']='main@old'; E['p-001.canvas@2026-10-20']['status']='in-work'; E['p-001.canvas@2026-10-20']['items']=['p-001.design.home-v3']; del E['p-001.canvas@2026-10-20']['live_evidence']; E['p-001.home@v3']['features']=['kit']; E['p-001.home@v3']['kind']='review'"
run "колишню live замінила версія в роботі" 1 "p-001.canvas@2026-07-21: була live (live_evidence), а замінена версією у стані in-work" "$TMP/t5.yaml"
edit "$TMP/t6.yaml" "E['p-001.canvas@2026-07-21']['live_evidence']='main@old'"
run "колишня live, замінена live — зелено (контроль)" 0 "реєстр макетів у формі" "$TMP/t6.yaml"

# фінальне рев'ю (29.10): примітки — свідками
edit "$TMP/u1.yaml" "E['p-001.canvas@2026-10-20']['sources']=[{'git':'p-ios@${V2}::/design-reference/Canvas.dc.html'}]"
run "git-шлях з магією pathspec" 1 "з магією pathspec «:»" "$TMP/u1.yaml"
edit "$TMP/u2.yaml" "E['p-001.canvas@2026-07-21']['live_evidence']='   '"
run "порожній live_evidence на superseded" 1 "p-001.canvas@2026-07-21: live_evidence порожній" "$TMP/u2.yaml"
cp "${OB}/MANIFEST" "$TMP/ob.manifest"; printf '  SHA256  %s  index.html\n' "$(sum "${OB}/index.html")" >> "${OB}/MANIFEST"
run "рядок SHA256 з відступом — не мовчки пропущений" 1 "рядок не у формі" "$TMP/green.yaml"
cp "$TMP/ob.manifest" "${OB}/MANIFEST"

printf 'schema_version: 1\nproduct: p\nentries: [\n' > "$TMP/broken.yaml"
run "реєстр не парситься" 2 "не парситься" "$TMP/broken.yaml"

printf 'schema_version: 1\nproduct: p\nentries: []\nproduct: q\n' > "$TMP/dup.yaml"
run "дубль ключа — читач рушія" 2 "дубльований ключ \`product\`" "$TMP/dup.yaml"

# звіт: дірки архіву — окремим розділом, з терміном
out="$(python3 "$L" "$TMP/f16.yaml" --repo-root "$R" --items "$R/strw-state/engine/items" --today 2026-10-29 --report 2>/dev/null)"
if printf '%s' "$out" | grep -qF -- '- p-001.review@2026-08-19 — експорт з Claude Design · до 2026-12-14'; then ok "звіт: дірка архіву названа з терміном"
else bad "звіт без дірки архіву" "$out"; fi

# звіт: що в проді, в роботі, заплановано, історія — з того самого реєстру
out="$(python3 "$L" "$TMP/green.yaml" --repo-root "$R" --items "$R/strw-state/engine/items" --today 2026-10-29 --report 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF '## Зараз у проді' \
   && printf '%s' "$out" | grep -qF -- '- Б.1 Головна · screens: p-001.canvas@2026-10-20' \
   && printf '%s' "$out" | grep -qF -- '- p-001.home@v3 — Головна v3 · елементи: p-001.design.home-v3' \
   && printf '%s' "$out" | grep -qF '| 2026-07-21 | p-001.canvas@2026-07-21 | superseded → p-001.canvas@2026-10-20 |' \
   && [ "$(printf '%s' "$out" | grep -cF -- '- p-001.canvas@2026-10-20 (2026-10-20) — Canvas після back-sync · p-ios main@')" -eq 1 ]; then ok "звіт: прод, доказ один раз, робота, історія з наступником"
else bad "звіт" "rc=$rc · $out"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
