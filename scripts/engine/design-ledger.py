#!/usr/bin/env python3
"""Реєстр версій макетів продукту — `products/<id>/design/ledger.yaml`. Детерміновано, офлайн.

Рішення CEO 29.10 (dec-117): «процес зберігання та архівування макетів під фічі та нові версії,
щоб можна було прослідувати історію змін у продукті … що в проді зараз, що вже змінено і це старий
дизайн, що в роботі і що ще буде». `index.yaml` відповідає «чи змінився макет» (хеш одиниці);
цей реєстр — «яка версія чого і в якому стані». Один запис = одна версія макета.

Стани — п'ять, і в кожного своя обов'язкова підстава, бо стан без підстави — це слово:
  live        — те, що показує прод: `live_evidence` (збірка / main@sha) і НЕЗМІННЕ джерело;
                на пару (фіча, вид) — щонайбільше одна live-версія;
  superseded  — старий дизайн: `superseded_by` на запис, який його замінив і знає про це
                (`supersedes`, в обидва боки), датований не раніше; незмінне джерело;
  in-work     — у роботі: `items` — елементи реєстру рушія, що її ведуть (і вони існують);
  planned     — буде: `plan_ref` (dec-NNN, tri-NNN, елемент) — без підстави «заплановано» не буває;
  not-taken   — варіант, який не взяли (design-options дизайнера): `return_if` — умова повернення.

Джерела. Незмінні: `git: <repo>@<sha>:<шлях>` (файл-blob у коміті; `sha256` — за бажання) ·
`path: <repo>/design-archive/<id>/` — тека, названа САМЕ id запису, з MANIFEST (`ledger=<id>`, рядок
`sha256  <сума>  <файл>` на КОЖЕН файл теки — суми звіряються) · `path:` на файл із `sha256`. Змінні
(історією самі не є): `path:` на робоче дерево без `sha256`, `artifact: <url>` + `version`,
`claude-design: <проєкт>/<файл>`. Шлях з `..` чи абсолютний — помилка: джерело поза парасолькою.
Немає ще знімка — `snapshot_pending: {what, by}`: чесна дірка, код 4; прострочена (`by` < сьогодні) —
порушення, код 1. Без `--repo-root` джерела не звірено, без `--items` — елементи `in-work`: обидва
випадки — код 3 з названою причиною, не тихий нуль.

Супровід: `superseded_by` — лише в стані `superseded`; кожен запис із `supersedes` замінює саме
`superseded`-записи; наступник не може бути `not-taken`; ланцюг замін без циклів.

Коди виходу: 0 у формі · 1 правило порушено (неприпустиме ЗНАЧЕННЯ: стан, вид, дата, підстава…) ·
2 не в формі — не парситься, порожній, корінь не мапа, поле не того ТИПУ ·
3 джерело нечитане (НЕ «без змін») · 4 архів неповний (є snapshot_pending). Старшинство 2 > 1 > 3 > 4:
порушене правило не ховає нечитаного джерела — обидва рядки друкуються, код — старший.
`path:` читається з робочої копії репо продукту — звіряти на тій гілці, де лежить історія (main).
Live-версію замінює лише live-версія: поки нова `in-work`, стара лишається `live`. Замінена live-версія
лишає свій `live_evidence` («була в проді») — і тоді її наступник мусить бути live (чи такою ж колишньою
live); `superseded` без `live_evidence` з наступником `in-work`/`planned` — стара версія макета, що в прод
не дійшла. Чи прибрали `live_evidence` при заміні, скрипт не бачить — це звіряє критик L7 (перевірка 8).
Форма: live_evidence — лише в live/superseded, items — лише в in-work, snapshot_pending — не в live.
`--report` друкує markdown: що в проді, що в роботі, що заплановано, не взяте, історія за фічами.
"""
import argparse, datetime, hashlib, os, re, subprocess, sys
# Читач YAML рушія (tri-094): поруч зі скриптом → STRW_ENGINE_LIB → strw-factory парасольки
# (копії скриптів у фікстурах лежать без lib/); ніде — код 2 з названою передумовою.
for _c in (os.environ.get("STRW_ENGINE_LIB", ""),   # явна змінна → поруч → парасолька
           os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"),
           os.path.join(os.environ.get("STRW_ROOT", os.path.expanduser("~/Developer/STRW")),
                        "strw-factory", "scripts", "engine", "lib")):
    if _c and os.path.isfile(os.path.join(_c, "yaml_nodup.py")):
        sys.path.insert(0, _c); break
try:
    from yaml_nodup import load_nodup  # один читач реєстру на весь рушій (tri-094)
except ImportError:
    sys.stderr.write("ERROR: немає lib/yaml_nodup.py — читач YAML рушія (ні поруч зі скриптом, ні STRW_ENGINE_LIB, ні STRW_ROOT/strw-factory); не поміряти (код 2)\n")
    sys.exit(2)

STATUSES = ("live", "superseded", "in-work", "planned", "not-taken")
KINDS = ("design-system", "screens", "component", "prototype", "review", "templates", "logo")
IMMUTABLE_NEEDED = ("live", "superseded", "not-taken")
RC_RULE, RC_SHAPE, RC_UNREAD, RC_PENDING = 1, 2, 3, 4
GIT_RE = re.compile(r"^([A-Za-z0-9_][A-Za-z0-9_.-]*)@([0-9a-f]{7,40}):(.+)$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
IGNORED_NAMES = (".DS_Store",)   # Finder пише їх у робочу копію; у git їх немає
SUM_RE = re.compile(r"^sha256\s+([0-9a-f]{64})\s+(\S+)$")   # як гейт продукту: ім'я без пробілів
# Поля запису й тип, якого вони мусять бути. Поле не того типу — «не в формі» (код 2), а не трейсбек,
# що виходить кодом 1 і читається як «порушено правило».
FIELD_TYPES = {"id": str, "title": str, "kind": str, "status": str, "features": list, "sources": list,
               "supersedes": list, "superseded_by": str, "items": list, "plan_ref": str, "return_if": str,
               "live_evidence": str, "snapshot_pending": dict, "note": str}
LIST_OF_STR = ("features", "supersedes", "items")


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def as_date(v):
    """YAML віддає `2026-07-21` як datetime.date — str() дає ту саму ISO-форму. Дата, якої не буває
    (2026-13-45), — не дата: рядкове порівняння з нею дало б хибне «прострочено»."""
    s = str(v) if v is not None else ""
    if not DATE_RE.match(s):
        return None
    try:
        datetime.date(int(s[:4]), int(s[5:7]), int(s[8:]))
    except ValueError:
        return None
    return s


def unsafe(path):
    """Шлях, що виходить за парасольку: абсолютний або з `..`/`.` серед частин."""
    parts = str(path).replace("\\", "/").split("/")
    return str(path).startswith("/") or any(x in ("..", ".") for x in parts)


def shape_errors(doc):
    out = []
    if not isinstance(doc.get("features", []), list):
        out.append("features має бути списком")
    for i, f in enumerate(doc.get("features") or []):
        if isinstance(f, dict) and not isinstance(f.get("id", ""), str):
            out.append(f"features[{i}].id має бути рядком")
    entries = doc.get("entries")
    if entries is not None and not isinstance(entries, list):
        out.append("entries має бути списком")
        return out
    for i, e in enumerate(entries or []):
        if not isinstance(e, dict):
            out.append(f"entries[{i}]: запис має бути мапою")
            continue
        where = e.get("id") if isinstance(e.get("id"), str) else f"entries[{i}]"
        for k, t in FIELD_TYPES.items():
            if k in e and e[k] is not None and not isinstance(e[k], t):
                out.append(f"{where}: {k} має бути {t.__name__}, а не {type(e[k]).__name__}")
        for k in LIST_OF_STR:
            if isinstance(e.get(k), list) and not all(isinstance(x, str) for x in e[k]):
                out.append(f"{where}: {k} — список рядків")
        for j, src in enumerate(e.get("sources") or [] if isinstance(e.get("sources"), list) else []):
            if not isinstance(src, dict):
                out.append(f"{where}: sources[{j}] має бути мапою")
    return out


def check_archive(root, eid, rel, p, errors):
    """Тека design-archive/<id>/: ім'я = id запису, MANIFEST з ledger=<id> і сумою КОЖНОГО файла (шляхи
    відносні, підтеки дозволені — як у гейті продукту); симлінк у теці чи сама тека-симлінк — не знімок."""
    name = os.path.basename(p.rstrip("/"))
    manifest = os.path.join(p, "MANIFEST")
    if not os.path.isfile(manifest):
        errors.append(f"{eid}: архівна тека {rel} без MANIFEST")
        return
    if name != eid:
        errors.append(f"{eid}: архівна тека {rel} належить іншому запису ({name}) — тека пишеться під "
                      f"свій запис, позичена тека не є знімком цієї версії")
    try:
        text = open(manifest, encoding="utf-8").read()
    except UnicodeDecodeError:
        errors.append(f"{eid}: MANIFEST теки {rel} не UTF-8 — його рядків не прочитати")
        return
    led = re.search(r"^ledger=(.+)$", text, re.M)
    if not led or led.group(1).strip() != eid:
        errors.append(f"{eid}: MANIFEST теки {rel} не називає ledger={eid}")
    listed = {}
    for line in text.splitlines():
        if line.strip().lower().startswith("sha256") and not SUM_RE.match(line.strip()):
            errors.append(f"{eid}: MANIFEST теки {rel}: рядок не у формі `sha256  <сума>  <файл>`: {line.strip()}")
            continue
        m = SUM_RE.match(line.strip())
        if m:
            f = m.group(2).strip()
            if os.path.basename(f) in IGNORED_NAMES:
                continue
            if f in listed:
                errors.append(f"{eid}: MANIFEST теки {rel} називає {f} двічі — сума одна")
            listed[f] = m.group(1)
    on_disk = []
    for dirpath, dirs, files in os.walk(p):
        for x in sorted(dirs + files):
            full = os.path.join(dirpath, x)
            relx = os.path.relpath(full, p).replace(os.sep, "/")
            if os.path.islink(full):
                errors.append(f"{eid}: {rel}/{relx} — симлінк; знімок — це файл, не посилання на нього")
            elif x in files and relx != "MANIFEST" and x not in IGNORED_NAMES:
                on_disk.append(relx)
    for f in sorted(on_disk):
        fp = os.path.join(p, f)
        if f not in listed:
            errors.append(f"{eid}: у теці {rel} файл {f}, якого MANIFEST не називає")
        elif sha256_bytes(open(fp, "rb").read()) != listed[f]:
            errors.append(f"{eid}: {rel}/{f} має інший вміст, ніж записано в MANIFEST — історію переписано")
    for f in sorted(set(listed) - set(on_disk)):
        errors.append(f"{eid}: MANIFEST теки {rel} називає {f}, якого в теці немає")
    if not on_disk:
        errors.append(f"{eid}: архівна тека {rel} порожня — знімка немає")


def check_source(root, eid, src, unread, errors):
    """→ True, якщо джерело НЕЗМІННЕ (git-blob, тека design-archive/<id>/, файл із sha256). Нечитане
    незмінне джерело — все одно незмінне за видом: його відсутність — код 3, а не «джерела немає»."""
    kinds = [k for k in ("git", "path", "artifact", "claude-design") if k in src]
    if len(kinds) > 1:
        errors.append(f"{eid}: одне джерело — один вид, а тут {', '.join(kinds)}")
        return False
    if "git" in src:
        m = GIT_RE.match(str(src["git"]))
        if not m:
            errors.append(f"{eid}: git-джерело {src['git']!r} не у формі <repo>@<sha>:<шлях>")
            return False
        repo, sha, path = m.groups()
        if unsafe(repo) or unsafe(path):
            errors.append(f"{eid}: git-джерело {src['git']!r} виходить за межі парасольки")
            return False
        if path.endswith("/") or "//" in path or path.startswith(":"):
            errors.append(f"{eid}: git-джерело {src['git']!r} — шлях на теку, з «//» чи з магією pathspec «:»; "
                          f"знімок версії — файл за буквальним шляхом")
            return False
        if root is None:
            unread.append(f"{eid}: {src['git']} не звірено — немає --repo-root")
            return True
        gitc = ["git", "--no-optional-locks", "-C", os.path.join(root, repo)]
        # ls-tree, не cat-file -t: симлінк теж «blob» (mode 120000) — 40 байт шляху замість знімка
        t = subprocess.run(gitc + ["ls-tree", "-z", "--full-tree", sha, "--", path], capture_output=True)
        recs = [r.decode("utf-8", "surrogateescape") for r in t.stdout.split(b"\0") if r] if t.returncode == 0 else []
        entry = recs[0] if len(recs) == 1 else ""
        if not entry:
            unread.append(f"{eid}: {src['git']} не читається (немає коміту чи шляху; неглибока копія?) — "
                          f"це НЕ «без змін»")
            return True
        mode, kind = entry.split("\t", 1)[0].split()[:2]
        if kind != "blob" or mode not in ("100644", "100755"):
            what = "симлінк" if mode == "120000" else kind
            errors.append(f"{eid}: {src['git']} — це {what}, а не файл; знімок версії — файл")
            return False
        want = src.get("sha256")
        if want:
            r = subprocess.run(gitc + ["cat-file", "blob", f"{sha}:{path}"], capture_output=True)
            if sha256_bytes(r.stdout) != str(want):
                errors.append(f"{eid}: {src['git']} має інший вміст, ніж записаний sha256 — історію переписано")
        return True
    if "path" in src:
        rel = str(src["path"]).rstrip("/")
        if unsafe(rel):
            errors.append(f"{eid}: path-джерело {src['path']!r} виходить за межі парасольки")
            return False
        parts = rel.split("/")
        low = [x.lower() for x in parts]   # macOS: Design-Archive/ і design-archive/ — та сама тека
        if "design-archive" in low[:-1] and low.index("design-archive") != len(parts) - 2:
            errors.append(f"{eid}: path {src['path']!r} веде всередину архівної теки — назвіть саму теку "
                          f"design-archive/{eid}/, а не файл у ній (і не теку іншого запису)")
            return False
        archive = len(parts) >= 2 and low[-2] == "design-archive"
        if root is None:
            unread.append(f"{eid}: {src['path']} не звірено — немає --repo-root")
            return bool(archive or src.get("sha256"))
        p = os.path.join(root, rel)
        repo_real = os.path.realpath(os.path.join(root, parts[0]))
        if os.path.lexists(p) and os.path.realpath(p) != os.path.join(repo_real, *parts[1:]):
            errors.append(f"{eid}: {src['path']} проходить через симлінк — знімок має лежати там, куди веде шлях, "
                          f"а не за посиланням (воно переїде, куди перевірка не дивиться)")
            return False
        if os.path.isdir(p) and archive:
            check_archive(root, eid, rel, p, errors)
            return True
        if os.path.isfile(p) and src.get("sha256"):
            if sha256_bytes(open(p, "rb").read()) != str(src["sha256"]):
                errors.append(f"{eid}: {src['path']} має інший вміст, ніж записаний sha256 — історію переписано")
            return True
        if os.path.exists(p):
            return False   # робоче дерево без суми: читається, але змінне — історією не є
        if archive or src.get("sha256"):
            unread.append(f"{eid}: {src['path']} не читається — це НЕ «без змін»")
            return True
        unread.append(f"{eid}: {src['path']} не читається — це НЕ «без змін»")
        return False
    if "artifact" in src:
        if not str(src["artifact"]).startswith("https://claude.ai/"):
            errors.append(f"{eid}: artifact-джерело не claude.ai-посилання: {src['artifact']!r}")
        if src.get("version") is None or not str(src.get("version")).strip():
            errors.append(f"{eid}: artifact-джерело без version — «яка версія» і є змістом запису")
        return False
    if "claude-design" in src:
        return False
    errors.append(f"{eid}: невідомий вид джерела {sorted(src)} — git · path · artifact · claude-design")
    return False


def validate(doc, root, items_dir, today):
    errors, unread, pending = [], [], []
    if type(doc.get("schema_version")) is not int or doc.get("schema_version") != 1:
        errors.append("schema_version має бути 1")
    if not isinstance(doc.get("product"), str) or not doc["product"].strip():
        errors.append("немає product")
    features = {}
    for f in doc.get("features") or []:
        if not isinstance(f, dict) or not f.get("id"):
            errors.append("features: кожна фіча — {id, title}")
            continue
        if f["id"] in features:
            errors.append(f"фіча {f['id']} оголошена двічі")
        features[f["id"]] = f.get("title") or f["id"]
    entries = doc.get("entries")
    if not isinstance(entries, list) or not entries:
        errors.append("entries має бути непорожнім списком")
        entries = []
    by_id = {}
    for i, e in enumerate(entries):
        if not e.get("id"):
            errors.append(f"entries[{i}]: немає id")
            continue
        if e["id"] in by_id:
            errors.append(f"{e['id']}: id повторюється")
            continue
        by_id[e["id"]] = e

    live_slots = {}
    for eid, e in by_id.items():
        st = e.get("status")
        if st not in STATUSES:
            errors.append(f"{eid}: status={st!r}, дозволені {', '.join(STATUSES)}")
            continue
        if e.get("kind") not in KINDS:
            errors.append(f"{eid}: kind={e.get('kind')!r}, дозволені {', '.join(KINDS)}")
        if not as_date(e.get("date")):
            errors.append(f"{eid}: date має бути YYYY-MM-DD")
        feats = e.get("features") or []
        if not feats:
            errors.append(f"{eid}: немає features — версія чого?")
        if len(set(feats)) != len(feats):
            errors.append(f"{eid}: фіча повторюється в features")
        for f in feats:
            if f not in features:
                errors.append(f"{eid}: фіча {f} не оголошена в features")

        immutable = False
        for src in e.get("sources") or []:
            immutable = check_source(root, eid, src, unread, errors) or immutable
        sp = e.get("snapshot_pending")
        if sp is not None:
            by = as_date(sp.get("by"))
            if not by or not str(sp.get("what") or "").strip():
                errors.append(f"{eid}: snapshot_pending потребує what і by (YYYY-MM-DD)")
            elif by < today:
                errors.append(f"{eid}: знімок прострочено (до {by}) — {sp['what']}")
            else:
                pending.append(f"{eid}: знімка ще немає — {sp['what']}, до {by}")
        if st in IMMUTABLE_NEEDED and not immutable and sp is None:
            errors.append(f"{eid}: {st} без незмінного джерела (git, design-archive/<id>/ або файл із sha256) — "
                          f"історія, що живе лише за посиланням чи в робочому дереві, зникає разом із ним; "
                          f"або snapshot_pending")

        if st == "superseded" and e.get("live_evidence") is not None and not str(e["live_evidence"]).strip():
            errors.append(f"{eid}: live_evidence порожній — або доказ, що версія була в проді, або без поля")
        if st not in ("live", "superseded") and e.get("live_evidence") is not None:
            errors.append(f"{eid}: live_evidence у стані {st} — доказ проду має лише live-версія (чи superseded, "
                          f"що була live)")
        if st != "in-work" and e.get("items") is not None:
            errors.append(f"{eid}: items у стані {st} — елементи веде лише in-work-версія (решту — в note)")
        if st == "live" and sp is not None:
            errors.append(f"{eid}: live з snapshot_pending — те, що в проді, мусить мати знімок уже зараз")
        if st == "live":
            if not str(e.get("live_evidence") or "").strip():
                errors.append(f"{eid}: live без live_evidence (збірка чи main@sha, що це показує)")
            for f in feats:
                live_slots.setdefault((f, e.get("kind")), []).append(eid)
        nxt = e.get("superseded_by")
        if nxt and st != "superseded":
            errors.append(f"{eid}: superseded_by у стані {st} — заміненою буває лише superseded-версія")
        if st == "superseded":
            if not nxt:
                errors.append(f"{eid}: superseded без superseded_by — чим замінено?")
            elif nxt not in by_id:
                errors.append(f"{eid}: superseded_by {nxt} — такого запису немає")
            else:
                if eid not in (by_id[nxt].get("supersedes") or []):
                    errors.append(f"{eid}: superseded_by {nxt}, а той не має його в supersedes")
                nx = by_id[nxt]
                was_live = str(e.get("live_evidence") or "").strip()
                if was_live and not (nx.get("status") == "live" or
                                     nx.get("status") == "superseded" and str(nx.get("live_evidence") or "").strip()):
                    errors.append(f"{eid}: була live (live_evidence), а замінена версією у стані {nx.get('status')} — "
                                  f"live-версію замінює лише та, що дійшла до проду")
                if by_id[nxt].get("status") == "not-taken":
                    errors.append(f"{eid}: замінена варіантом not-taken ({nxt}) — невзятий варіант нічого не замінює")
                d1, d2 = as_date(e.get("date")), as_date(by_id[nxt].get("date"))
                if d1 and d2 and d2 < d1:
                    errors.append(f"{eid}: замінена версією, датованою раніше ({d2} < {d1})")
        for prev in e.get("supersedes") or []:
            if prev not in by_id:
                errors.append(f"{eid}: supersedes {prev} — такого запису немає")
            elif by_id[prev].get("superseded_by") != eid:
                errors.append(f"{eid}: supersedes {prev}, а той не називає його superseded_by")
        if st == "in-work":
            its = e.get("items") or []
            if not its:
                errors.append(f"{eid}: in-work без items — хто веде цю роботу?")
            elif not items_dir:
                unread.append(f"{eid}: елементи {', '.join(its)} не звірено — немає --items")
            else:
                for it in its:
                    if unsafe(it) or not os.path.isfile(os.path.join(items_dir, f"{it}.yaml")):
                        errors.append(f"{eid}: елемента {it} немає в реєстрі ({items_dir})")
        if st == "planned" and not str(e.get("plan_ref") or "").strip():
            errors.append(f"{eid}: planned без plan_ref (dec-NNN, tri-NNN чи елемент)")
        if st == "not-taken" and not str(e.get("return_if") or "").strip():
            errors.append(f"{eid}: not-taken без return_if — варіант зберігають З умовою повернення")

    for eid in by_id:   # ланцюг замін без циклів: A → B → A означало б, що найновішої версії немає
        seen, cur = [], eid
        while cur in by_id and by_id[cur].get("superseded_by") and cur not in seen:
            seen.append(cur)
            cur = by_id[cur]["superseded_by"]
        if cur in seen and cur == eid:
            errors.append(f"{eid}: цикл замін {' → '.join(seen + [cur])}")
    for (f, k), ids in sorted(live_slots.items()):
        if len(ids) > 1:
            errors.append(f"дві live-версії для {f}/{k}: {', '.join(sorted(ids))} — у проді одна")
    return (features, by_id), errors, unread, pending


def report(doc, features, by_id):
    out = [f"# Дизайн-історія · {doc.get('product')}", "",
           "_Згенеровано `design-ledger.py --report` з `design/ledger.yaml`; руками не редагується._", ""]
    def line(e, extra=""):
        return f"- {e['id']} — {e.get('title', '')}{extra}"
    live = sorted((e for e in by_id.values() if e.get("status") == "live"), key=lambda x: x["id"])
    out += ["## Зараз у проді", ""]
    for fid, ftitle in features.items():   # порядок фіч — як оголошено в реєстрі
        for e in live:
            if fid in (e.get("features") or []):
                out.append(f"- {ftitle} · {e.get('kind')}: {e['id']}")
    if live:
        out += ["", "Докази проду:", ""]
        out += [f"- {e['id']} ({e.get('date')}) — {e.get('title', '')} · {e.get('live_evidence', '')}" for e in live]
    else:
        out.append("- немає")
    holes = sorted((e for e in by_id.values() if e.get("snapshot_pending")), key=lambda x: str(x["snapshot_pending"].get("by")))
    out += ["", "## Дірки архіву (знімка ще немає)", ""]
    out += [f"- {e['id']} — {e['snapshot_pending'].get('what')} · до {e['snapshot_pending'].get('by')}" for e in holes] or ["- немає"]
    for title, st, field in (("В роботі", "in-work", "items"), ("Заплановано", "planned", "plan_ref"),
                             ("Не взяте (з умовою повернення)", "not-taken", "return_if")):
        out += ["", f"## {title}", ""]
        rows = [e for e in by_id.values() if e.get("status") == st]
        for e in sorted(rows, key=lambda x: str(x.get("date"))):
            v = e.get(field)
            v = ", ".join(v) if isinstance(v, list) else v
            label = {"items": "елементи", "plan_ref": "підстава", "return_if": "повернути, якщо"}[field]
            out.append(line(e, f" · {label}: {v}"))
        if not rows:
            out.append("- немає")
    out += ["", "## Історія за фічами"]
    for fid, ftitle in features.items():
        rows = [e for e in by_id.values() if fid in (e.get("features") or [])]
        if not rows:
            continue
        out += ["", f"### {ftitle}", "", "| Дата | Версія | Стан | Що | Джерело |", "|---|---|---|---|---|"]
        for e in sorted(rows, key=lambda x: (str(x.get("date")), x["id"])):
            st = e.get("status")
            if st == "superseded":
                st = f"superseded → {e.get('superseded_by')}"
            srcs = []
            for s in e.get("sources") or []:
                k = next((k for k in ("git", "path", "artifact", "claude-design") if k in s), None)
                if k:
                    srcs.append(f"{k}: {s[k]}" + (f" v{s['version']}" if k == "artifact" and s.get("version") else ""))
            if e.get("snapshot_pending"):
                srcs.append(f"знімка немає (до {e['snapshot_pending'].get('by')})")
            out.append(f"| {e.get('date')} | {e['id']} | {st} | {e.get('title', '')} | {'; '.join(srcs) or '—'} |")
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Реєстр версій макетів: валідація і звіт.")
    ap.add_argument("ledger")
    ap.add_argument("--repo-root", help="парасолька STRW (репо продуктів поруч); без неї джерела не звірено — код 3")
    ap.add_argument("--items", help="engine/items; без нього елементи in-work не звірено — код 3")
    ap.add_argument("--today", default=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"))
    ap.add_argument("--report", action="store_true")
    a = ap.parse_args(argv)
    if not as_date(a.today):
        print(f"ERROR: --today {a.today!r} — не дата YYYY-MM-DD; терміни знімків не поміряти", file=sys.stderr)
        return RC_SHAPE
    try:
        doc = load_nodup(open(a.ledger, encoding="utf-8"))
    except Exception as e:
        print(f"ERROR: {a.ledger} не парситься: {e}", file=sys.stderr)
        return RC_SHAPE
    if doc is None:
        print(f"ERROR: {a.ledger} порожній — реєстру немає, це не «нічого не змінилось»", file=sys.stderr)
        return RC_SHAPE
    if not isinstance(doc, dict):
        print(f"ERROR: {a.ledger}: корінь не мапа", file=sys.stderr)
        return RC_SHAPE
    shape = shape_errors(doc)
    if shape:
        for e in shape:
            print(f"ERROR: не в формі: {e}", file=sys.stderr)
        return RC_SHAPE
    parsed, errors, unread, pending = validate(doc, a.repo_root, a.items, a.today)
    for e in errors:
        print(f"ERROR: {e}", file=sys.stderr)
    for u in unread:
        print(f"UNREAD: {u}", file=sys.stderr)
    for p in pending:
        print(f"PENDING: {p}", file=sys.stderr)
    if a.report:
        sys.stdout.write(report(doc, *parsed))
    if errors:
        return RC_RULE
    if unread:
        return RC_UNREAD
    if pending:
        return RC_PENDING
    n = len(parsed[1])
    print(f"реєстр макетів у формі: {n} версій, {sum(1 for e in parsed[1].values() if e.get('status') == 'live')} live",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
