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

python3 - "$ENGINE_DIR" "$DECISIONS_LOG" "$STRW_ROOT" "$WORK" <<'PY'
import os, re, sys, subprocess, glob as globmod

engine_dir, decisions_log, strw_root, work = sys.argv[1:5]
try:
    import yaml
except ImportError:
    print("ERROR: потрібен python3 з PyYAML", file=sys.stderr); sys.exit(2)

errors, stales, warns = [], [], []
def err(m):   errors.append(m)
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
    path = os.path.join(strw_root, repo)
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
        doc = yaml.safe_load(open(lanes_path)) or {}
    except Exception as e:
        err(f"lanes.yaml не парситься: {e}"); doc = {}
    if str(doc.get("schema_version")) != "1":
        err(f"lanes.yaml: schema_version = {doc.get('schema_version')!r}, очікується 1")
    shared_globs = doc.get("shared") or []
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
def _entry(line):
    m = re.match(r"^##\s+(\d{4}-\d{2}-\d{2})\b", line)
    return (m.group(1), line[3:].strip()) if m else None

# ПОЛЕ `affects:` (аудит 2026-09-03, П1.5) — і чому воно не може бути
# необовʼязковою прикрасою. До нього протухання було ТОТАЛЬНИМ: +1 будь-яке
# рішення робило STALE кожен `ready`-елемент, отже кожен ставав `blocked`
# (спека §3.3), отже черга спинялась цілком. Вимір 03.09: 18 елементів
# протухли, з них 8 — через `dec-093`, яке стосується трьох.
#
# СТАРА СЕМАНТИКА ЗБЕРЕЖЕНА ДОСЛІВНО: **вузол без `affects` торкається
# ВСЬОГО**. Це не поблажка до 93 історичних вузлів, а єдиний безпечний
# дефолт: «поля немає» означає «ніхто не звужував», а не «нікого не
# стосується». Звуження без свідка — це те саме fail-open, проти якого весь
# цей валідатор. Нові вузли без поля не проходять pre-commit strw-state
# (блок «П1.5 affects»), тож борг не росте.
FM_RE = re.compile(r"\A---\n(.*?)\n---\n", re.S)

def _affects(path, rel):
    """Список `affects` вузла, або None — «торкається всього» (стара семантика)."""
    raw = open(path, encoding="utf-8").read()
    m = FM_RE.match(raw)
    if not m:
        return None
    try:
        fm = yaml.safe_load(m.group(1)) or {}
    except Exception as e:
        err(f"{rel}: frontmatter вузла рішення не читається: {e}")
        return None
    if not isinstance(fm, dict) or "affects" not in fm:
        return None
    a = fm.get("affects")
    if not isinstance(a, list) or not a:
        # Порожній список — не «нікого не стосується», а недописаний рядок.
        # Прийняти його означало б дати найтихіший спосіб вимкнути протухання:
        # `affects: []` у вузлі, і жоден елемент більше не протухає ніколи.
        err(f"{rel}: `affects` мусить бути НЕПОРОЖНІМ списком "
            f"(відсутність поля = «торкається всього»; порожній список — недописаний рядок)")
        return None
    bad = [x for x in a if not (str(x) == "factory" or
           str(x).startswith(("product:", "lane:", "item:")))]
    if bad:
        # Одрук у префіксі звузив би вплив рішення до НУЛЯ мовчки — тобто
        # зробив би реєстр зеленим саме тоді, коли підстава протухла.
        err(f"{rel}: `affects` містить непізнані записи {bad} — "
            f"очікується factory | product:<id> | lane:<id> | item:<id>")
    return [str(x) for x in a]

def touches(affects, it):
    if affects is None:
        return True
    for a in affects:
        if a == "factory" and it.get("product") == "factory":
            return True
        if a.startswith("item:") and a[5:] == it.get("id"):
            return True
        if a.startswith("product:") and a[8:] == it.get("product"):
            return True
        if a.startswith("lane:") and a[5:] == it.get("lane"):
            return True
    return False

decision_dates, decision_titles, decision_affects = [], [], []
decisions_dir = os.path.join(os.path.dirname(decisions_log), "decisions")
node_files = sorted(globmod.glob(os.path.join(decisions_dir, "*", "*.md")))
if node_files:
    for path in node_files:
        rel = os.path.relpath(path, decisions_dir)
        for line in open(path):
            e = _entry(line)
            if e:
                decision_dates.append(e[0]); decision_titles.append(e[1])
                decision_affects.append(_affects(path, rel))
                break
        else:
            err(f"{rel}: вузол рішення без заголовка "
                f"`## YYYY-MM-DD · …` — його не видно лічильнику")
elif os.path.isfile(decisions_log):
    for line in open(decisions_log):
        e = _entry(line)
        if e:
            decision_dates.append(e[0]); decision_titles.append(e[1])
            decision_affects.append(None)   # моноліт полів не має — стара семантика
else:
    err(f"немає ні {decisions_dir}/, ні {decisions_log}")
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
        it = yaml.safe_load(open(path))
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

    # ---------- схема `plan` (аудит 2026-09-03, П1.4) ----------
    # ЧОМУ ПОЛЕ. 30 із 60 PR — «великі» за критерієм L3 6a, раунди чекера 2–6,
    # до 11. Без плану, який рецензують ДО коду, рев'ю читає диф, а не рішення,
    # і ціна росте лінійно з розміром. `acceptance` каже, ЩО мусить бути
    # правдою; `plan` каже, ЧИМ і В ЯКОМУ ПОРЯДКУ це робиться.
    #
    # Місце вибране, як і для `design_sources`: ДО `done`-виходу. Форма поля не
    # залежить від стану елемента — покручений `plan` у закритому елементі
    # лишається помилкою реєстру, а не історією.
    PLAN_KEYS = {"files", "order", "risks", "proof", "risks_none_because"}
    plan = it.get("plan")
    if plan is not None:
        if not isinstance(plan, dict):
            err(f"{name}: `plan` має бути мапою з `files`, `order`, `risks`, `proof`, "
                f"а не {type(plan).__name__}")
        else:
            unknown = sorted(set(plan) - PLAN_KEYS)
            if unknown:
                # Закритий словник, а не відкритий: одрук у назві ключа інакше
                # мовчки викидає половину плану з-під перевірки.
                err(f"{name}: plan має непізнані ключі {unknown} — "
                    f"дозволені {sorted(PLAN_KEYS)}")
            for f_ in ("files", "order"):
                v = plan.get(f_)
                if not isinstance(v, list) or not v:
                    err(f"{name}: plan.{f_} мусить бути НЕПОРОЖНІМ списком "
                        f"(отримано {v!r})")
            r = plan.get("risks")
            if not isinstance(r, list):
                err(f"{name}: plan.risks мусить бути списком (порожній — лише разом "
                    f"із рядком plan.risks_none_because)")
            elif not r:
                why = plan.get("risks_none_because")
                if not (isinstance(why, str) and why.strip()):
                    # «Ризиків немає» без причини — це не вимір, а пропуск поля.
                    err(f"{name}: plan.risks порожній без plan.risks_none_because — "
                        f"«ризиків немає» мусить бути ТВЕРДЖЕННЯМ, а не мовчанням")
            pr = plan.get("proof")
            if not (isinstance(pr, str) and pr.strip()):
                err(f"{name}: plan.proof мусить бути непорожнім рядком — чим саме "
                    f"буде доведено, що план виконано")
    elif st == "ready" and str(it.get("size")) in ("M", "L"):
        # WARN, а не ERROR — свідомо. ERROR зробив би елемент `blocked`, тобто
        # черга спинилась би на кожному елементі M/L разом, а це рівно та шкода,
        # яку П1.5 щойно прибрав з іншого боку. Старт без плану забороняє раннер
        # і скіл `strw-loop-run` (Step 4), тобто там, де це дешево полагодити.
        warn(f"{name}: size={it.get('size')} і state=ready, а `plan` немає — "
             f"maker мусить подати plan (files/order/risks/proof) ДО першого коміту "
             f"(L3 правило 10)")

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
                idx = yaml.safe_load(open(design_index)) or {}
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

    stored = ab.get("decisions_log_entries")
    if stored is not None:
        # ТОЧНИЙ шлях: лічильник записів. Ловить дописи в межах тієї самої доби,
        # яких порівняння дат не бачить у принципі.
        if not isinstance(stored, int) or stored < 0:
            err(f"{name}: decisions_log_entries = {stored!r} — має бути невід'ємне ціле")
        elif decisions_count > stored:
            # ТОЧКОВО, а не тотально: із дописаних беруться лише ті, чий `affects`
            # перетинається з цим елементом. Вузол без `affects` торкається всього —
            # стара семантика, збережена дослівно.
            fresh = [(decision_titles[i], decision_affects[i])
                     for i in range(stored, decisions_count)]
            hits = [t for t, a in fresh if touches(a, it)]
            if hits:
                # Називаємо, ЩО САМЕ дописали. Без цього людина мусить сама шукати
                # різницю і в спішці «оновлює» лічильник, не перечитавши підставу, —
                # тобто робить рівно те, проти чого acceptance_basis і придуманий.
                listed = "".join(f"\n         · {t}" for t in hits[:5])
                more = f"\n         … ще {len(hits) - 5}" if len(hits) > 5 else ""
                skipped = len(fresh) - len(hits)
                aside = (f" ({skipped} дописаних елемента не стосуються)"
                         if skipped else "")
                stale(f"{name}: звірено проти {stored} записів decisions-log, зараз їх "
                      f"{decisions_count}; ТОРКАЮТЬСЯ ЦЬОГО ЕЛЕМЕНТА: {len(hits)}{aside} "
                      f"→ ПОТРЕБУЄ ПЕРЕПЕРЕВІРКИ "
                      f"(спека §3.3: такий елемент не 'ready', а 'blocked')."
                      f"\n       Прочитати ці записи, звірити з ними `acceptance`, і лише потім "
                      f"піднімати лічильник:{listed}{more}")
        elif decisions_count < stored:
            err(f"{name}: decisions_log_entries = {stored}, а в decisions-log лише "
                f"{decisions_count} записів. Лог append-only — зменшення означає, що "
                f"записи ЗНИКЛИ (клас інциденту dcd6a6c) або лічильник вигаданий")
        continue

    # ЗАПАСНИЙ шлях для елементів без лічильника: порівняння дат. Свідомо грубіше —
    # у межах доби нічого не розрізняє. Не додавай нових елементів без лічильника.
    # Датова гілка — ТА САМА логіка звуження, інакше елемент без лічильника
    # лишився б під тотальним протуханням, і «точкове» було б неправдою для
    # частини реєстру.
    newer = sorted({decision_dates[i] for i in range(len(decision_dates))
                    if decision_dates[i] > vdate and touches(decision_affects[i], it)})
    if newer:
        stale(f"{name}: acceptance_basis звірено на {vdate}, а в decisions-log є новіші "
              f"записи ({', '.join(newer[-3:])}) → ПОТРЕБУЄ ПЕРЕПЕРЕВІРКИ "
              f"(спека §3.3: такий елемент не 'ready', а 'blocked')")
    else:
        warn(f"{name}: немає `decisions_log_entries` — свіжість перевірено лише за датою, "
             f"тобто дописи в межах {vdate} не виявляються")

# ---------- 6. blocked_by: посилання і цикли ----------
graph = {}
for iid, it in items.items():
    deps = []
    for ref in (it.get("blocked_by") or []):
        ref = str(ref)
        if ref.startswith("item:"):
            dep = ref[5:]
            if dep not in items:
                err(f"{iid}: blocked_by посилається на неіснуючий елемент '{dep}'")
            else:
                deps.append(dep)
        elif ref.startswith("ceo:"):
            pass          # зовнішній блокер — дія CEO, не елемент реєстру
        else:
            err(f"{iid}: blocked_by '{ref}' — очікується префікс 'item:' або 'ceo:'")
    graph[iid] = deps

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
