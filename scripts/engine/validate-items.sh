#!/usr/bin/env bash
# validate-items.sh — детермінована валідація реєстру рушія. БЕЗ моделі.
# Рівень 0 для фази 0 Preflight диспетчера (спека v2 §4): схеми item-файлів,
# існування глобів `owns`, непересічність смуг, свіжість acceptance_basis.
#
# Usage: bash strw-factory/scripts/engine/validate-items.sh [engine-dir]
#   engine-dir за замовчуванням — <STRW>/strw-state/engine (шукається від розташування скрипта).
#
# Класи виводу:
#   ERROR — валідація провалена, exit != 0
#   STALE — acceptance_basis протух (у decisions-log є новіший запис) → ТЕЖ exit != 0.
#           Свідомо помилка, а не попередження: спека §3.3 вимагає, щоб такий елемент
#           був `blocked`, а не `ready`. Критерій, написаний зі старого джерела, проходить
#           і гейт, і checker'а — і будує те, що CEO вже скасував.
#   WARN  — не блокує (напр. шлях смуги перетинається з `shared`).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# `$STRW_ROOT` — парасолька ~/Developer/STRW, під якою лежать усі клони; та сама
# змінна й та сама семантика, що в `.githooks/pre-commit` обох репо. Виведення з
# розташування скрипта лишається дефолтом, але перестає бути ЄДИНИМ джерелом:
# із worktree (`strw-factory-worktrees/<гілка>/`) `../../..` вказує на теку
# worktree-ів, де сусідніх репо немає, і валідатор оголошував 20 глобів `owns`
# помилкою конфігурації на здоровому реєстрі. Тобто інструмент червонів від
# того, ЗВІДКИ його покликали, — рівно клас `measure-of-the-wrong-subject`.
STRW_ROOT="${STRW_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
ENGINE_DIR="${1:-$STRW_ROOT/strw-state/engine}"
# `repo:` → тека: з ОДНОГО словника (repo-dir.sh), спільного з bin/strw-worktree.sh.
# strw-ops — це сам корінь парасольки, не $STRW_ROOT/strw-ops (tri-070, PR #70).
# shellcheck source=repo-dir.sh
. "$SCRIPT_DIR/repo-dir.sh"
STRW_REPO_DIRS="$(strw_repo_dirs "$STRW_ROOT")" || { echo "ERROR: словник репо розійшовся сам із собою (repo-dir.sh)" >&2; exit 2; }
# Журнал рішень береться ПОРУЧ із реєстром, а не з $STRW_ROOT. Інакше аргумент
# `engine-dir` бреше: елементи читаються з worktree, а журнал — зі спільної
# копії, і 18.08 це дало точно хибний діагноз (обидві копії мали по 76
# записів, але РІЗНИХ).
DECISIONS_LOG="$(cd "$ENGINE_DIR/.." 2>/dev/null && pwd)/decisions-log.md"

[[ -d "$ENGINE_DIR" ]] || { echo "ERROR: engine-теки немає: $ENGINE_DIR" >&2; exit 2; }
command -v python3 >/dev/null || { echo "ERROR: потрібен python3" >&2; exit 2; }

# Знімок HEAD кожного репо, який згадують смуги. git-виклики — тут, у bash;
# python нижче тільки читає готові списки, тож валідація детермінована й офлайнова.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Читач YAML — lib/yaml_nodup.py: поруч зі скриптом, або STRW_ENGINE_LIB, або зі strw-factory
# парасольки (копії скрипта у фікстурах тестів strw-ops лежать без lib/). Ніде немає — код 2 з
# названою передумовою, не трейсбек ModuleNotFoundError.
# Тека береться лише ПОВНА (усі три модулі): стара lib/ без decisions_basis.py/item_fields.py
# (спільна копія до мержу, кеш плагіна старшої версії) дала б трейсбек імпорту, а не код 2.
ENGINE_LIB=""
for c in "${STRW_ENGINE_LIB:-}" "$SCRIPT_DIR/lib" "${STRW_ROOT:-$HOME/Developer/STRW}/strw-factory/scripts/engine/lib"; do   # явна змінна → поруч → парасолька
  [ -n "$c" ] && [ -f "$c/yaml_nodup.py" ] && [ -f "$c/decisions_basis.py" ] && [ -f "$c/item_fields.py" ] && { ENGINE_LIB="$c"; break; }
done
[ -n "$ENGINE_LIB" ] || { echo "ERROR: немає повної lib/ (yaml_nodup.py · decisions_basis.py · item_fields.py) — читач YAML рушія (strw-factory: scripts/engine/lib/; ні поруч зі скриптом, ні в STRW_ENGINE_LIB, ні в STRW_ROOT/strw-factory); валідатор без нього не міряє (код 2)" >&2; exit 2; }
STRW_ENGINE_LIB="$ENGINE_LIB" python3 - "$ENGINE_DIR" "$DECISIONS_LOG" "$STRW_ROOT" "$WORK" "$STRW_REPO_DIRS" <<'PY'
import os, re, sys, subprocess, glob as globmod

engine_dir, decisions_log, strw_root, work, repo_dirs_arg = sys.argv[1:6]
# repo → тека, зі словника repo-dir.sh (bash), не з os.path.join(strw_root, repo):
# strw-ops резолвиться в корінь, невідоме репо — помилка конфігурації з назвою словника.
# Пари «repo=тека» по одному на рядок: `:` і `=` у шляху дозволені, перенос рядка — ні.
repo_dirs = dict(kv.split("=", 1) for kv in repo_dirs_arg.split("\n") if kv)
try:
    import yaml
except ImportError:
    print("ERROR: потрібен python3 з PyYAML", file=sys.stderr); sys.exit(2)

errors, stales, warns = [], [], []
def err(m):   errors.append(m)

# ---------- YAML без дублікатів ключів (tri-094) ----------
# Читач один на всі скрипти рушія — scripts/engine/lib/yaml_nodup.py (шлях — з bash через
# STRW_ENGINE_LIB); toolchain-filter.sh, design-emit.py, design-hash.py, validate-design-index.py
# читають ним же; bin/strw-run.sh (strw-ops) — парним PR strw-ops #19.
sys.path.insert(0, os.environ["STRW_ENGINE_LIB"])
from yaml_nodup import load_nodup
# Журнал рішень і свіжість підстави; форма полів елемента й «готовність до A» — спільні з
# autonomy-route.sh: обидва мусять казати те саме про той самий елемент (клас tri-070).
from decisions_basis import load_decisions, freshness
from item_fields import plan_errors, form_errors, readiness_gaps
def stale(m): stales.append(m)
def warn(m):  warns.append(m)

# ---------- 0. schema_version ----------
sv_path = os.path.join(engine_dir, "schema_version")
if not os.path.isfile(sv_path):
    err(f"немає {sv_path}")
    schema_version = None
else:
    schema_version = open(sv_path).read().strip()
    if schema_version != "1":
        err(f"schema_version = '{schema_version}', очікується '1'")

# ---------- glob → regex ----------
# `**` перетинає '/', `*` — ні. fnmatch цього не вміє, тому власний транслятор.
def glob_re(g):
    out, i = [], 0
    while i < len(g):
        if g[i:i+3] == "**/": out.append(r"(?:.*/)?"); i += 3; continue
        if g[i:i+2] == "**":  out.append(r".*");       i += 2; continue
        if g[i]    == "*":    out.append(r"[^/]*");    i += 1; continue
        if g[i]    == "?":    out.append(r"[^/]");     i += 1; continue
        out.append(re.escape(g[i])); i += 1
    return re.compile("^" + "".join(out) + "$")

_tree_cache = {}
def repo_tree(repo):
    """Список шляхів на HEAD репо. Порожній список = репо недоступне (це помилка)."""
    if repo in _tree_cache: return _tree_cache[repo]
    path = repo_dirs.get(repo)
    if path is None:
        err(f"репо '{repo}' невідоме словнику strw-factory/scripts/engine/repo-dir.sh "
            f"(відомі: {', '.join(sorted(repo_dirs))})")
        _tree_cache[repo] = []
        return []
    if not os.path.isdir(os.path.join(path, ".git")):
        err(f"репо '{repo}' не знайдено як git-клон у {path}")
        _tree_cache[repo] = []
        return []
    out = subprocess.run(["git", "-C", path, "ls-tree", "-r", "--name-only", "HEAD"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        err(f"git ls-tree впав у '{repo}': {out.stderr.strip()}")
        _tree_cache[repo] = []
        return []
    _tree_cache[repo] = out.stdout.splitlines()
    return _tree_cache[repo]

# ---------- 1. lanes.yaml ----------
lanes_path = os.path.join(engine_dir, "lanes.yaml")
lanes, shared_globs = {}, []
if not os.path.isfile(lanes_path):
    err(f"немає {lanes_path}")
else:
    try:
        doc = load_nodup(open(lanes_path)) or {}
    except Exception as e:
        err(f"lanes.yaml не парситься: {e}"); doc = {}
    if str(doc.get("schema_version")) != "1":
        err(f"lanes.yaml: schema_version = {doc.get('schema_version')!r}, очікується 1")
    shared_globs = doc.get("shared") or []
    # `tools:` — словник інструментів для Step 3a і поля `requires:` елемента
    # (dec-095 §2). Необов'язковий доти, доки жоден елемент не має `requires:`
    # і жодна смуга — `resources:` (тоді міряти нема чого); з ними — обов'язковий,
    # бо ресурс/інструмент без probe фільтр не може виміряти, лише «припустити».
    tools = doc.get("tools")
    tools_declared = tools is not None
    if tools is None:
        tools = {}
    elif not isinstance(tools, dict):
        err(f"lanes.yaml: `tools` має бути мапою ім'я → {{probe: <команда>}}"); tools = {}
    else:
        for tname, spec in tools.items():
            if not isinstance(spec, dict) or not isinstance(spec.get("probe"), str) or not spec.get("probe").strip():
                err(f"lanes.yaml: tools.{tname} — потрібне поле `probe` (рядок-команда, що ВИКОНУЄ інструмент; код 0 = є)")
            elif spec.get("kind") not in ("tool", "resource"):
                err(f"lanes.yaml: tools.{tname} — потрібне поле `kind: tool|resource` (resources: смуги → resource, requires: елемента → tool)")
    for lane in (doc.get("lanes") or []):
        lid = lane.get("id")
        if not lid: err("lanes.yaml: смуга без `id`"); continue
        if lid in lanes: err(f"lanes.yaml: дубль смуги '{lid}'")
        # `repo` і `owns` мусять бути НЕПОРОЖНІ: смуга без репо або без шляхів
        # нічим не володіє, а доказ непересічності над порожньою множиною
        # вакуумно істинний (спека §3.4).
        for field in ("repo", "owns"):
            if not lane.get(field):
                err(f"смуга '{lid}': немає обов'язкового поля `{field}`")
        # `resources` — інакше: поле мусить БУТИ, але порожній список є валідною
        # відповіддю. Смуга інструментів (`scripts/**`, `.github/**`) не тримає
        # ні симулятора, ні бази, ні gradle-кешу — вимагати від неї вигаданий
        # ресурс означало б вписати в реєстр неправду заради проходження
        # перевірки. Розрізняємо «немає поля» і «порожньо, і це відповідь».
        if "resources" not in lane:
            err(f"смуга '{lid}': немає обов'язкового поля `resources` "
                f"(порожній список валідний, відсутність — ні)")
        elif not isinstance(lane.get("resources"), list):
            err(f"смуга '{lid}': `resources` має бути списком, а не {type(lane.get('resources')).__name__}")
        elif tools_declared:   # без `tools:` ресурси лишаються іменами, як до 04.09
            for rname in lane.get("resources"):
                if not isinstance(rname, str):
                    err(f"смуга '{lid}': ресурс {rname!r} має бути рядком"); continue
                if rname not in tools:
                    err(f"смуга '{lid}': ресурс '{rname}' не має probe у lanes.yaml `tools:` — фільтр Step 3a не зможе його виміряти")
                elif isinstance(tools[rname], dict) and tools[rname].get("kind") == "tool":
                    err(f"смуга '{lid}': ресурс '{rname}' оголошено в tools: як kind: tool — ресурс смуги мусить бути kind: resource")
        lanes[lid] = lane

# ---------- 2. кожен глоб `owns` матчить ≥1 шлях на HEAD свого репо ----------
# Глоб, що матчить 0 шляхів, — ПОМИЛКА КОНФІГУРАЦІЇ, не «нічим не володію»:
# доказ непересічності над порожньою множиною вакуумно істинний (спека §3.4).
lane_paths = {}   # lane_id -> (repo, set(paths))
for lid, lane in lanes.items():
    repo = lane.get("repo")
    tree = repo_tree(repo) if repo else []
    owned = set()
    for g in (lane.get("owns") or []):
        rx = glob_re(g)
        hits = [p for p in tree if rx.match(p)]
        if not hits:
            err(f"смуга '{lid}': глоб `{g}` матчить 0 шляхів на HEAD репо '{repo}' "
                f"— помилка конфігурації, не «нічим не володію»")
        owned.update(hits)
    lane_paths[lid] = (repo, owned)

# ---------- 3. жоден шлях не належить двом смугам одночасно ----------
# Порівняння в межах ОДНОГО репо: однаковий рядок шляху в різних репо — різні файли.
lids = sorted(lane_paths)
for i in range(len(lids)):
    for j in range(i + 1, len(lids)):
        a, b = lids[i], lids[j]
        (ra, pa), (rb, pb) = lane_paths[a], lane_paths[b]
        if ra != rb: continue
        both = pa & pb
        if both:
            sample = ", ".join(sorted(both)[:5])
            err(f"смуги '{a}' і '{b}' (репо '{ra}') ділять {len(both)} шлях(ів): {sample}")

# ---------- 3b. WARN: смуга перетинається з `shared` ----------
# Спека §3.4: `shared` = файли ПОЗА всіма смугами. Перетин не ламає ізоляцію
# (shared лише серіалізує), але робить правило «поза смугами» неправдивим.
for lid, (repo, owned) in lane_paths.items():
    tree = repo_tree(repo) if repo else []
    for g in shared_globs:
        rx = glob_re(g)
        overlap = {p for p in tree if rx.match(p)} & owned
        if overlap:
            warn(f"смуга '{lid}' володіє шляхом(ами) з `shared` `{g}`: "
                 f"{', '.join(sorted(overlap)[:3])} — `shared` мав бути ПОЗА смугами (спека §3.4)")

# ---------- 4. decisions-log: дати й КІЛЬКІСТЬ записів ----------
# Заголовки несуть лише дату, без часу, тож порівняння дат не розрізняє записи
# в межах однієї доби. Лог append-only → кількість датованих записів є монотонним
# лічильником, і саме він дає точну відповідь «чи дописали щось ПІСЛЯ звірки».
# Дати лишаються запасним варіантом для елементів без лічильника.
#
# Джерел два, і після розбивки Second Brain (19.08) головне — ДИРЕКТОРІЯ.
# `decisions-log.md` став фасадом: записів у ньому нуль, вони живуть у
# `decisions/YYYY/dec-NNN-*.md`. Валідатор, який рахував лише моноліт, бачив 0
# і оголошував, що 53 елементи посилаються на зниклі записи — на здоровому
# реєстрі. Порядок вузлів = порядок дописування (`dec-NNN`), бо саме він, а не
# дата, є семантикою лічильника `decisions_log_entries`.
# Розбір вузлів, поле `affects:` і звуження протухання — scripts/engine/lib/decisions_basis.py
# (аудит 2026-09-03, П1.5). СТАРА СЕМАНТИКА ЗБЕРЕЖЕНА ДОСЛІВНО: **вузол без `affects`
# торкається ВСЬОГО** — «поля немає» означає «ніхто не звужував», а не «нікого не стосується».
# До поля протухання було ТОТАЛЬНИМ: вимір 03.09 — 18 елементів протухли, 8 з них через
# `dec-093`, яке стосується трьох. Нові вузли без поля не проходять pre-commit strw-state.
_dec = load_decisions(decisions_log, load_nodup)
for m in _dec["errors"]:
    err(m)
decision_dates = _dec["dates"]
newest_decision = max(decision_dates) if decision_dates else None
decisions_count = len(decision_dates)

# ---------- 5. items ----------
REQUIRED = ["schema_version", "id", "product", "loop", "lane", "state",
            "repo", "branch", "acceptance", "acceptance_basis",
            "lease", "evidence", "attempts"]
STATES = {"ready", "claimed", "running", "gated", "reviewed",
          "merge-pending", "done", "blocked", "parked"}

items_dir = os.path.join(engine_dir, "items")
item_files = sorted(globmod.glob(os.path.join(items_dir, "*.yaml")))
if not item_files:
    err(f"немає жодного item-файлу в {items_dir}")

items = {}
for path in item_files:
    name = os.path.basename(path)
    try:
        it = load_nodup(open(path))
    except Exception as e:
        err(f"{name}: не парситься: {e}"); continue
    if not isinstance(it, dict):
        err(f"{name}: корінь не мапа"); continue

    for f in REQUIRED:
        if f not in it or it[f] is None or it[f] == "":
            err(f"{name}: немає обов'язкового поля `{f}`")

    iid = it.get("id")
    if iid:
        items[iid] = it
        if name != f"{iid}.yaml":
            err(f"{name}: ім'я файлу не збігається з `id` ('{iid}.yaml')")

    if str(it.get("schema_version")) != "1":
        err(f"{name}: schema_version = {it.get('schema_version')!r}, очікується 1")

    st = it.get("state")
    if st not in STATES:
        err(f"{name}: state = {st!r} — не зі списку {sorted(STATES)}")
    if st == "blocked" and not it.get("blocked_by"):
        err(f"{name}: state=blocked, але немає `blocked_by`")
    if it.get("blocked_by") and st != "blocked":
        err(f"{name}: є `blocked_by`, але state = {st!r} (мав бути 'blocked')")

    lane = it.get("lane")
    if lane and lane not in lanes:
        err(f"{name}: lane '{lane}' не оголошена в lanes.yaml")
    elif lane and it.get("repo") and it["repo"] != lanes[lane].get("repo"):
        err(f"{name}: repo '{it['repo']}' ≠ repo смуги '{lane}' ('{lanes[lane].get('repo')}')")

    for extra in (it.get("also_touches") or []):
        if extra not in lanes:
            err(f"{name}: also_touches '{extra}' не оголошена в lanes.yaml")

    # `requires:` — інструменти понад ресурси смуги (dec-095 §2, tri-053). Форма:
    # список рядків, кожен — ключ `tools:`; покручена форма — ERROR, не WARN, бо
    # Step 3a читає це поле машинно і «список із мапою» мовчки став би «нічого».
    req = it.get("requires")
    if req == []:
        req = None   # порожній список = поля немає: міряти нема чого
    if req is not None and not tools_declared:
        err(f"{name}: є `requires`, а в lanes.yaml немає словника `tools:` — інструменти нічим виміряти")
    elif req is not None:
        if not isinstance(req, list) or not all(isinstance(x, str) and x.strip() for x in req):
            err(f"{name}: `requires` має бути списком непорожніх рядків (імена з lanes.yaml `tools:`), а не {req!r}")
        else:
            for tname in req:
                if tname not in tools:
                    err(f"{name}: requires '{tname}' — інструмента немає в lanes.yaml `tools:` (є: {', '.join(sorted(tools)) or 'нічого'})")
                elif isinstance(tools[tname], dict) and tools[tname].get("kind") == "resource":
                    err(f"{name}: requires '{tname}' — це ресурс смуги (kind: resource), а не інструмент; ресурси задає смуга")

    ab = it.get("acceptance_basis")
    if not isinstance(ab, dict):
        err(f"{name}: `acceptance_basis` мусить бути мапою з `sources` і "
            f"`verified_against_decisions_log_at`")
        continue
    if not ab.get("sources"):
        err(f"{name}: acceptance_basis.sources порожній")
    ver = ab.get("verified_against_decisions_log_at")
    if not ver:
        err(f"{name}: немає acceptance_basis.verified_against_decisions_log_at")
        continue
    vdate = str(ver)[:10]
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", vdate):
        err(f"{name}: verified_against_decisions_log_at = {ver!r} — не ISO-дата"); continue

    # design_sources: лише форма. Ще без висновків про протухання (те — окреме
    # завдання) — навмисно, щоб контракт даних і логіку протухання можна було
    # прийняти чи відхилити рев'ю окремо.
    #
    # Місце вибране точно: ДО `done`-виходу і ДО гілки decisions_log_entries —
    # жодна з них форму не відсікає. Два `continue` ВИЩЕ її таки відсікають
    # (acceptance_basis не мапа; немає verified_against_decisions_log_at), і це
    # не діра: обидва вже поклали ERROR, елемент червоний, а форма поля всередині
    # структури, якої немає, невизначена. Раніше цей коментар твердив, що не
    # відсікає ЖОДНА — неправда, за яку рев'ю справедливо вчепилось.
    ds = ab.get("design_sources")
    if ds is not None:
        if not isinstance(ds, list):
            err(f"{name}: design_sources має бути списком")
        else:
            for j, entry in enumerate(ds):
                at = f"{name}: design_sources[{j}]"
                if not isinstance(entry, dict):
                    err(f"{at} — має бути записом {{ref, hash, verified_at}}")
                    continue
                for key in ("ref", "hash", "verified_at"):
                    if not entry.get(key):
                        err(f"{at} — немає {key}")
                h = entry.get("hash")
                if h and not (isinstance(h, str) and h.startswith("sha256:")):
                    err(f"{at} — hash має починатись із 'sha256:', отримано {h!r}")

    # ---------- `human_checklist` (factory.human-test-checklist, CEO 29.10) ----------
    # `human_checklist:` — шлях до чекліста ручної перевірки CEO в репо елемента (стандарт
    # references/human-test-checklist.md). Раннер strw-ops читає цей файл із дерева агента, тож форма
    # тут — перша лінія: відносний `docs/smoke/<…>.md`, сегменти без пробілів, без `.`/`..`, один рядок
    # (друга — симлінки в раннері). Та сама форма, що human_checklist_form_ok у bin/strw-run.sh.
    # Стоїть ДО ланцюга `if plan … elif` — усередині нього розірвала б його (чекер #41, B1).
    hc = it.get("human_checklist")
    if hc is not None and not (isinstance(hc, str)
                               and re.fullmatch(r"docs/smoke/(?:[^/\s]+/)*[^/\s]+\.md", hc)
                               and not ({".", ".."} & set(hc.split("/")))):
        err(f"{name}: human_checklist: {hc!r} — мусить бути відносним шляхом docs/smoke/<…>.md без «.»/«..» "
            f"(стандарт references/human-test-checklist.md)")

    # ---------- схема `plan` (аудит 2026-09-03, П1.4) ----------
    # ЧОМУ ПОЛЕ. 30 із 60 PR — «великі» за критерієм L3 6a, раунди чекера 2–6,
    # до 11. Без плану, який рецензують ДО коду, рев'ю читає диф, а не рішення,
    # і ціна росте лінійно з розміром. `acceptance` каже, ЩО мусить бути
    # правдою; `plan` каже, ЧИМ і В ЯКОМУ ПОРЯДКУ це робиться.
    #
    # Місце вибране, як і для `design_sources`: ДО `done`-виходу. Форма поля не
    # залежить від стану елемента — покручений `plan` у закритому елементі
    # лишається помилкою реєстру, а не історією.
    # Форма — lib/item_fields.py: plan_errors (закритий словник ключів; files/order непорожні;
    # risks або risks_none_because; proof). Той самий код читає autonomy-route.sh.
    plan = it.get("plan")
    if plan is not None:
        for m in plan_errors(plan):
            err(f"{name}: {m}")
    elif st == "ready" and str(it.get("size")) in ("M", "L"):
        # WARN, а не ERROR — свідомо. ERROR зробив би елемент `blocked`, тобто
        # черга спинилась би на кожному елементі M/L разом, а це рівно та шкода,
        # яку П1.5 щойно прибрав з іншого боку. Старт без плану забороняє раннер
        # і скіл `strw-loop-run` (Step 4), тобто там, де це дешево полагодити.
        warn(f"{name}: size={it.get('size')} і state=ready, а `plan` немає — "
             f"maker мусить подати plan (files/order/risks/proof) ДО першого коміту "
             f"(L3 правило 10)")

    # ---------- режими A/B (спека strw-ops reports/2026-10-20-hybrid-autonomy-spec.md §2–§3) ----------
    # Форма полів autonomy/touches/tests_spec/plan_review/budget — завжди, як і `plan`: від стану
    # не залежить. Для `autonomy: unattended` — ще й «готовність до A» (§3), і для S теж: елемент,
    # який будильник може взяти без людини, без плану, тестів-до-коду і вердикту по ПОТОЧНОМУ плану —
    # ERROR реєстру, а не тихий «with-ceo» у маршруті. Маршрут (autonomy-route.sh) читає ті самі
    # функції й додає умови, яких форма не бачить (стадія продукту, «великий» за 6a, тріаж).
    for m in form_errors(it):
        err(f"{name}: {m}")
    if it.get("autonomy") == "unattended":
        for g in readiness_gaps(it):
            err(f"{name}: autonomy: unattended, а готовність до A неповна — {g}")

    # `done` НЕ перевіряється на свіжість — рішення CEO 2026-08-19 №81, після
    # питання, яке цикл `factory.validate-items-owner` виніс замість вирішити
    # тихо (і чекер справедливо назвав ту тиху правку блокером).
    #
    # Підстава — вимір, не зручність: із 51 протухлого елемента 38 були `done`,
    # тобто три чверті червоного стосувались роботи, яка вже зроблена й не може
    # змінитись від нового рішення. Дія, яку спека §3.3 приписує протухлому
    # елементу («не `ready`, а `blocked`»), для закритого не існує.
    #
    # Ціна, названа в самому рішенні: критерій закритого елемента більше ніколи
    # не звіряється з новими рішеннями автоматично — про скасування вже
    # побудованого скаже рев'ю або людина, не валідатор.
    if st == "done":
        continue

    # Друга гілка протухання: дизайн. Індекс живе поруч із реєстром, тим самим
    # правилом, що й журнал рішень (інакше аргумент engine-dir бреше на worktree).
    # normpath — бо `engine-dir` із хвостовим слешем робить dirname() тотожним:
    # os.path.dirname("…/strw-state/engine/") == "…/strw-state/engine", і індекс
    # шукається на рівень глибше, ніж лежить. Журнал рішень цього не помічав, бо
    # береться через bash `cd ..`, який слеш переживає.
    design_index = os.path.join(os.path.dirname(os.path.normpath(engine_dir)),
                                "products", it.get("product", ""), "design", "index.yaml")
    # Свідомо isinstance, а не `or []`: design_sources-рядок пройшов би `if ds:`,
    # цикл нижче ітерував би його ПОСИМВОЛЬНО і впав на `entry.get` — сирим
    # traceback, тобто рівно тим класом, що Critical 3. Форму вже названо вище.
    ds = ab.get("design_sources")
    ds = ds if isinstance(ds, list) else []
    if ds:
        if not os.path.exists(design_index):
            err(f"{name}: design_sources є, а індексу немає: {design_index}")
        else:
            # try/except — так само, як для lanes.yaml і item-файлів поруч.
            # Без нього зіпсований index.yaml валив увесь звіт сирим traceback:
            # ані `ERROR:`, ані `STALE:`, ані підсумку — а хук registry-check.sh
            # ґрепає саме ці префікси, тож лишалось голе «🔴 FAIL» без причини,
            # і ОДНА поламана дизайн-одиниця ховала всі інші помилки реєстру.
            try:
                idx = load_nodup(open(design_index)) or {}   # другий hash: одиниці → хибний STALE (6a #27)
            except Exception as e:
                err(f"{name}: дизайн-індекс {design_index} не парситься: {e}")
                idx = None
            if idx is None:
                pass
            elif not isinstance(idx, dict):
                err(f"{name}: дизайн-індекс {design_index}: корінь не мапа, "
                    f"а {type(idx).__name__}")
            elif not idx.get("units"):
                # Називаємо порожній ІНДЕКС. Інакше цикл нижче звинуватив би
                # кожну одиницю в тому, що її «немає в індексі» — той самий клас
                # брехні про причину, який випадок 9e вже одного разу зловив.
                err(f"{name}: дизайн-індекс {design_index} не містить жодної "
                    f"одиниці — підстава не втрачена одиницею, її немає де взяти")
            else:
                by_ref = {u.get("ref"): u for u in idx.get("units", [])}
                for entry in ds:
                    ref, stored = entry.get("ref"), entry.get("hash")
                    unit = by_ref.get(ref)
                    if unit is None:
                        err(f"{name}: design_source вказує на одиницю {ref!r}, якої в "
                            f"індексі немає. Елемент тихо втратив підставу — це не "
                            f"попередження")
                    elif unit.get("state") != "watched":
                        pass  # за unwatched стежити неможливо; це не мовчання, а розділ 6.2
                    elif unit.get("hash") and unit["hash"] != stored:
                        stale(f"{name}: дизайн-одиниця {ref} розійшлась із записаною "
                              f"підставою → ПОТРЕБУЄ ПЕРЕПЕРЕВІРКИ.\n"
                              f"       Переглянути макет, звірити з ним `acceptance`, "
                              f"і лише потім оновлювати hash.")

    # Свіжість — lib/decisions_basis.py:freshness (той самий вимір читає autonomy-route.sh).
    # ТОЧНИЙ шлях — лічильник записів: ловить дописи в межах доби, яких дати не бачать.
    # Звуження ТОЧКОВЕ: із дописаних беруться лише ті, чий `affects` торкається елемента.
    kind, detail = freshness(it, _dec)
    if kind == "bad-counter":
        err(f"{name}: decisions_log_entries = {detail!r} — має бути невід'ємне ціле")
    elif kind == "stale-count":
        stored, count, hits, skipped = detail
        # Називаємо, ЩО САМЕ дописали. Без цього людина в спішці «оновлює» лічильник,
        # не перечитавши підставу, — рівно те, проти чого acceptance_basis придуманий.
        listed = "".join(f"\n         · {t_}" for t_ in hits[:5])
        more = f"\n         … ще {len(hits) - 5}" if len(hits) > 5 else ""
        aside = (f" ({skipped} дописаних елемента не стосуються)" if skipped else "")
        stale(f"{name}: звірено проти {stored} записів decisions-log, зараз їх "
              f"{count}; ТОРКАЮТЬСЯ ЦЬОГО ЕЛЕМЕНТА: {len(hits)}{aside} "
              f"→ ПОТРЕБУЄ ПЕРЕПЕРЕВІРКИ "
              f"(спека §3.3: такий елемент не 'ready', а 'blocked')."
              f"\n       Прочитати ці записи, звірити з ними `acceptance`, і лише потім "
              f"піднімати лічильник:{listed}{more}")
    elif kind == "vanished":
        stored, count = detail
        err(f"{name}: decisions_log_entries = {stored}, а в decisions-log лише "
            f"{count} записів. Лог append-only — зменшення означає, що "
            f"записи ЗНИКЛИ (клас інциденту dcd6a6c) або лічильник вигаданий")
    elif kind == "stale-date":
        # ЗАПАСНИЙ шлях для елементів без лічильника — свідомо грубіший: у межах доби
        # нічого не розрізняє. Не додавай нових елементів без лічильника.
        vd, newer = detail
        stale(f"{name}: acceptance_basis звірено на {vd}, а в decisions-log є новіші "
              f"записи ({', '.join(newer[-3:])}) → ПОТРЕБУЄ ПЕРЕПЕРЕВІРКИ "
              f"(спека §3.3: такий елемент не 'ready', а 'blocked')")
    elif kind == "no-counter":
        warn(f"{name}: немає `decisions_log_entries` — свіжість перевірено лише за датою, "
             f"тобто дописи в межах {detail} не виявляються")

# ---------- 6. blocked_by: посилання і цикли ----------
graph = {}
for iid, it in items.items():
    deps, has_ceo, unresolved = [], False, 0
    for ref in (it.get("blocked_by") or []):
        ref = str(ref)
        if ref.startswith("item:"):
            dep = ref[5:]
            if dep not in items:
                err(f"{iid}: blocked_by посилається на неіснуючий елемент '{dep}'")
                unresolved += 1
            else:
                deps.append(dep)
        elif ref.startswith("ceo:"):
            has_ceo = True    # зовнішній блокер — дія CEO, не елемент реєстру
        else:
            err(f"{iid}: blocked_by '{ref}' — очікується префікс 'item:' або 'ceo:'")
            unresolved += 1
    graph[iid] = deps

    # ---------- 6a. задоволений blocked_by: реєстр каже «зайнято» про вільне ----------
    # Дзеркало `registry.knows-open-prs` (той каже «вільно» про зроблене). STALE, а не
    # WARN: WARN друкується і не зупиняє нікого, а ціна тут — робота, що мовчки зникає
    # з черги; петля звітує «немає роботи» правдиво про свій вимір і хибно про реєстр.
    #
    # МЕХАНІЗМ НЕВИДИМОСТІ — ВИПРАВЛЕНО 07.09 після зовнішнього рев'ю 6a. Перша
    # редакція цього коментаря казала «toolchain-filter пропускає за непорожнім
    # `blocked_by`». Це НЕПРАВДА про причину. Рядок 72 фільтра:
    #     if it.get("state") != "ready" or it.get("blocked_by"): continue
    # для елемента `state: blocked` перший диз'юнкт істинний ЗАВЖДИ — до другого
    # черга не доходить. Тобто елемент невидимий через свій СТАН, а `blocked_by`
    # для нього не встигає стати причиною ніколи (він міг би спрацювати лише на
    # `ready` з непорожнім `blocked_by`, а це вже ERROR на рядку 351).
    # Чому це не косметика: за хибним діагнозом наступний виконавець пішов би
    # правити диз'юнкт у фільтрі, виміряв нульову зміну поведінки й закрив би
    # завдання як «клас уже неможливий». Висновок від цього не змінюється, а
    # МІЦНІШАЄ: лікувати треба реєстр (стан мусить бути правдивим), бо споживач
    # чесно вірить полю `state`.
    # Виміряно 2026-09-07 (headless L3, слот PM): ЧОТИРИ такі елементи одночасно —
    # factory.portability-gate-all-repos (блокер змержено 04.09, `1f64fa8`),
    # m3.locales-five (`3bae692`), m3.purchase-flow і m3.subscription-screen
    # (блокер m3.purchase-transport-adr → done 02.09, `ef259dd`; сам ADR-022 прийнято
    # ще 18.08 — інша подія). Найстарішому боргу було шість днів (від 02.09).
    # `ceo:` поруч мовчить свідомо: стану дії CEO звідси не видно, і вгадувати його
    # означало б червоніти на здоровому реєстрі.
    # `unresolved` — блокери, яких перевірка НЕ ЗМОГЛА прочитати (неіснуючий id,
    # чужий префікс). Вони вже дали ERROR і не потрапили в `deps` — а без цього
    # гарда 6a твердила б «ВСІ блокери done», перелічивши лише розв'язану
    # ПІДМНОЖИНУ, і припис «почисти blocked_by» стер би разом з одруком реальну,
    # незакриту залежність. Знахідка зовнішнього рев'юера 6a (Important, 07.09);
    # відтворено пробою 7 ДО фікса. Мовчати про те, чого не прочитав, — обов'язок,
    # а не обережність: `absence-told-as-answer`.
    if it.get("state") == "blocked" and deps and not has_ceo and not unresolved:
        pending = [d for d in deps if items[d].get("state") != "done"]
        if not pending:
            stale(f"{iid}.yaml: state=blocked, але ВСІ блокери вже done "
                  f"({', '.join(sorted(set(deps)))}) → елемент невидимий для черги "
                  f"(toolchain-filter відсікає за state != ready — стан протух, не поле); "
                  f"мав бути 'ready' з порожнім `blocked_by`")

WHITE, GREY, BLACK = 0, 1, 2
color = {k: WHITE for k in graph}
def visit(n, path):
    color[n] = GREY
    for d in graph.get(n, []):
        if color.get(d) == GREY:
            err(f"цикл залежностей: {' → '.join(path + [n, d])}")
        elif color.get(d) == WHITE:
            visit(d, path + [n])
    color[n] = BLACK
for n in sorted(graph):
    if color[n] == WHITE: visit(n, [])

# ---------- вивід ----------
def show(tag, rows):
    for r in rows: print(f"{tag}: {r}")

show("WARN", warns)
show("STALE", stales)
show("ERROR", errors)

by_state = {}
for it in items.values():
    by_state[it.get("state")] = by_state.get(it.get("state"), 0) + 1
summary = ", ".join(f"{k}={v}" for k, v in sorted(by_state.items(), key=lambda x: str(x[0])))

print()
print(f"смуг: {len(lanes)} · елементів: {len(items)} · {summary}")
print(f"глобів owns перевірено на HEAD: "
      f"{sum(len(l.get('owns') or []) for l in lanes.values())} "
      f"(репо: {', '.join(sorted({l.get('repo') for l in lanes.values() if l.get('repo')}))})")
print(f"найновіший запис decisions-log: {newest_decision or 'н/д'}")

if errors or stales:
    print(f"\nFAIL: {len(errors)} error(s), {len(stales)} stale, {len(warns)} warn")
    sys.exit(1)
print(f"\nOK: реєстр валідний ({len(warns)} warn)")
PY
