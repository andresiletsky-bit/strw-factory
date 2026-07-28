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
STRW_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ENGINE_DIR="${1:-$STRW_ROOT/strw-state/engine}"
DECISIONS_LOG="$STRW_ROOT/strw-state/decisions-log.md"

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
        for field in ("repo", "owns", "resources"):
            if not lane.get(field):
                err(f"смуга '{lid}': немає обов'язкового поля `{field}`")
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

# ---------- 4. decisions-log: дати записів ----------
decision_dates = []
if os.path.isfile(decisions_log):
    for line in open(decisions_log):
        m = re.match(r"^##\s+(\d{4}-\d{2}-\d{2})\b", line)
        if m: decision_dates.append(m.group(1))
else:
    err(f"немає {decisions_log}")
newest_decision = max(decision_dates) if decision_dates else None

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
    newer = sorted({d for d in decision_dates if d > vdate})
    if newer:
        stale(f"{name}: acceptance_basis звірено на {vdate}, а в decisions-log є новіші "
              f"записи ({', '.join(newer[-3:])}) → ПОТРЕБУЄ ПЕРЕПЕРЕВІРКИ "
              f"(спека §3.3: такий елемент не 'ready', а 'blocked')")

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
