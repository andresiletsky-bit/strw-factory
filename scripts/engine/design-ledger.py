#!/usr/bin/env python3
"""Реєстр версій макетів продукту — `products/<id>/design/ledger.yaml`. Детерміновано, офлайн.

Рішення CEO 29.10 (dec-115): «процес зберігання та архівування макетів під фічі та нові версії,
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

Джерела: `git: <repo>@<sha>:<шлях>` (незмінне задарма; `sha256` — за бажання) · `path: <repo>/<шлях>`
(файл або тека `design-archive/<id>/` з MANIFEST, чий `ledger=` дорівнює id запису) — обидва
незмінні · `artifact: <url>` + `version` · `claude-design: <проєкт>/<файл>` — змінні посилання,
історією самі не є. Немає ще знімка — `snapshot_pending: {what, by}`: чесна дірка, код 4;
прострочена (`by` < сьогодні) — порушення, код 1.

Коди виходу: 0 у формі · 1 правило порушено · 2 реєстр не в формі / не парситься ·
3 джерело нечитане (НЕ «без змін») · 4 архів неповний (є snapshot_pending).
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
GIT_RE = re.compile(r"^([A-Za-z0-9_.-]+)@([0-9a-f]{7,40}):(.+)$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def as_date(v):
    s = str(v) if v is not None else ""
    return s if DATE_RE.match(s) else None


def check_source(root, eid, src, unread, errors):
    """→ True, якщо джерело незмінного виду (git або path). Нечитане незмінне джерело — все одно
    незмінне за видом: його відсутність — код 3 «не поміряти», а не «джерела немає»."""
    if not isinstance(src, dict):
        errors.append(f"{eid}: джерело має бути мапою, а не {type(src).__name__}")
        return False
    if "git" in src:
        m = GIT_RE.match(str(src["git"]))
        if not m:
            errors.append(f"{eid}: git-джерело {src['git']!r} не у формі <repo>@<sha>:<шлях>")
            return False
        if root is None:
            return True
        repo, sha, path = m.groups()
        r = subprocess.run(["git", "--no-optional-locks", "-C", os.path.join(root, repo), "show", f"{sha}:{path}"],
                           capture_output=True)
        if r.returncode != 0:
            unread.append(f"{eid}: {src['git']} не читається (немає коміту чи шляху; неглибока копія?) — "
                          f"це НЕ «без змін»")
            return True
        want = src.get("sha256")
        if want and sha256_bytes(r.stdout) != str(want):
            errors.append(f"{eid}: {src['git']} має інший вміст, ніж записаний sha256 — історію переписано")
        return True
    if "path" in src:
        if root is None:
            return True
        p = os.path.join(root, str(src["path"]))
        if os.path.isdir(p):
            manifest = os.path.join(p, "MANIFEST")
            if os.path.basename(os.path.dirname(p.rstrip("/"))) == "design-archive":
                if not os.path.isfile(manifest):
                    errors.append(f"{eid}: архівна тека {src['path']} без MANIFEST")
                    return False
                led = re.search(r"^ledger=(.+)$", open(manifest, encoding="utf-8").read(), re.M)
                if not led or led.group(1).strip() != os.path.basename(p.rstrip("/")):
                    errors.append(f"{eid}: MANIFEST теки {src['path']} не називає її ledger=<ім'я теки>")
            return True
        if os.path.isfile(p):
            want = src.get("sha256")
            if want and sha256_bytes(open(p, "rb").read()) != str(want):
                errors.append(f"{eid}: {src['path']} має інший вміст, ніж записаний sha256 — історію переписано")
            return True
        unread.append(f"{eid}: {src['path']} не читається — це НЕ «без змін»")
        return True
    if "artifact" in src:
        if not str(src["artifact"]).startswith("https://claude.ai/"):
            errors.append(f"{eid}: artifact-джерело не claude.ai-посилання: {src['artifact']!r}")
        if not str(src.get("version") or "").strip():
            errors.append(f"{eid}: artifact-джерело без version — «яка версія» і є змістом запису")
        return False
    if "claude-design" in src:
        return False
    errors.append(f"{eid}: невідомий вид джерела {sorted(src)} — git · path · artifact · claude-design")
    return False


def validate(doc, root, items_dir, today):
    errors, unread, pending = [], [], []
    if not isinstance(doc, dict):
        return None, [], [], []
    if doc.get("schema_version") != 1:
        errors.append("schema_version має бути 1")
    if not str(doc.get("product") or "").strip():
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
        if not isinstance(e, dict) or not e.get("id"):
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
        for f in feats:
            if f not in features:
                errors.append(f"{eid}: фіча {f} не оголошена в features")

        immutable = False
        for src in e.get("sources") or []:
            immutable = check_source(root, eid, src, unread, errors) or immutable
        sp = e.get("snapshot_pending")
        if sp is not None:
            by = as_date((sp or {}).get("by"))
            if not by or not str((sp or {}).get("what") or "").strip():
                errors.append(f"{eid}: snapshot_pending потребує what і by (YYYY-MM-DD)")
            elif by < today:
                errors.append(f"{eid}: знімок прострочено (до {by}) — {sp['what']}")
            else:
                pending.append(f"{eid}: знімка ще немає — {sp['what']}, до {by}")
        if st in IMMUTABLE_NEEDED and not immutable and sp is None:
            errors.append(f"{eid}: {st} без незмінного джерела (git або path) — історія, що живе лише "
                          f"за посиланням, зникає разом із ним; або snapshot_pending")

        if st == "live":
            if not str(e.get("live_evidence") or "").strip():
                errors.append(f"{eid}: live без live_evidence (збірка чи main@sha, що це показує)")
            for f in feats:
                live_slots.setdefault((f, e.get("kind")), []).append(eid)
        if st == "superseded":
            nxt = e.get("superseded_by")
            if not nxt:
                errors.append(f"{eid}: superseded без superseded_by — чим замінено?")
            elif nxt not in by_id:
                errors.append(f"{eid}: superseded_by {nxt} — такого запису немає")
            else:
                if eid not in (by_id[nxt].get("supersedes") or []):
                    errors.append(f"{eid}: superseded_by {nxt}, а той не має його в supersedes")
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
            elif items_dir:
                for it in its:
                    if not os.path.isfile(os.path.join(items_dir, f"{it}.yaml")):
                        errors.append(f"{eid}: елемента {it} немає в реєстрі ({items_dir})")
        if st == "planned" and not str(e.get("plan_ref") or "").strip():
            errors.append(f"{eid}: planned без plan_ref (dec-NNN, tri-NNN чи елемент)")
        if st == "not-taken" and not str(e.get("return_if") or "").strip():
            errors.append(f"{eid}: not-taken без return_if — варіант зберігають З умовою повернення")

    for (f, k), ids in sorted(live_slots.items()):
        if len(ids) > 1:
            errors.append(f"дві live-версії для {f}/{k}: {', '.join(sorted(ids))} — у проді одна")
    return (features, by_id), errors, unread, pending


def report(doc, features, by_id):
    out = [f"# Дизайн-історія · {doc.get('product')}", "",
           "_Згенеровано `design-ledger.py --report` з `design/ledger.yaml`; руками не редагується._", ""]
    def line(e, extra=""):
        return f"- {e['id']} — {e.get('title', '')}{extra}"
    out += ["## Зараз у проді", ""]
    for eid, e in sorted(by_id.items(), key=lambda kv: (kv[1].get("features") or [""])[0]):
        if e.get("status") == "live":
            for f in e.get("features") or []:
                out.append(f"- {features.get(f, f)} · {e.get('kind')}: {eid} ({e.get('date')}) — "
                           f"{e.get('title', '')} · {e.get('live_evidence', '')}")
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
    ap.add_argument("--repo-root", help="парасолька STRW (репо продуктів поруч) — без неї джерела не звіряються")
    ap.add_argument("--items", help="engine/items — для перевірки, що елементи in-work існують")
    ap.add_argument("--today", default=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"))
    ap.add_argument("--report", action="store_true")
    a = ap.parse_args(argv)
    try:
        doc = load_nodup(open(a.ledger, encoding="utf-8")) or {}
    except Exception as e:
        print(f"ERROR: {a.ledger} не парситься: {e}", file=sys.stderr)
        return RC_SHAPE
    parsed, errors, unread, pending = validate(doc, a.repo_root, a.items, a.today)
    if parsed is None:
        print(f"ERROR: {a.ledger}: корінь не мапа", file=sys.stderr)
        return RC_SHAPE
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
