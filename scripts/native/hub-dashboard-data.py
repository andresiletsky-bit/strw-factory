#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Дані приватного Dashboard хаба (factory.hub-dashboard): числа дошки — з джерел, не переказом.

    hub-dashboard-data.py --state <тека strw-state> --sessions <list_sessions.json>
                          (--prs-dir <тека> | --gh) --out <порожня тека> --now <YYYY-MM-DDTHH:MM[:SS]Z>
                          [--state-label <звідки state>]

Чотири джерела:
  · сесії — JSON-масив, який хаб записав із виходу list_sessions (рядки isArchived пропускаються);
  · відкриті PR п'яти репо (REPOS) — `--prs-dir` з файлами <repo>.json (вихід `gh pr list --json`), або
    `--gh`: генератор сам кличе `gh pr list` для кожного репо і кладе сирі відповіді в <out>/prs/ —
    той самий знімок, переданий як --prs-dir, дає побайтно той самий hub.json;
  · <state>/triage/open/*.md — передмова YAML карток тріажу;
  · <state>/engine/items/*.yaml — елементи реєстру.

Вихід — один файл <out>/hub.json: масив рядків, кожен із полем `table` (summary, sessions, prs, repos,
triage, items, lanes). Сторінка ділить його на таблиці через dash.calc; один файл = одне завантаження
при оновленні (`references/native-outputs.md` § «Живий Dashboard хаба»).

Не валідатор джерел. Відмовляє (код 2, причина одним рядком, hub.json не пишеться) лише там, де дашборд
збрехав би: загубив рядок (дубль id, репо без знімка, обрізаний список), порахував невідоме значення
(стан елемента, статус картки), назвав старе свіжим. `--state` — не спільна копія strw-state
($STRW_ROOT/strw-state): її робоче дерево буває замороженим; обгортка hub-dashboard-refresh.sh дає
знімок origin/main. Генератор нічого не публікує.
"""
import argparse
import datetime as dt
import glob
import hashlib
import json
import os
import re
import subprocess
import sys

# Читач YAML без дублікатів ключів — один на весь рушій (tri-094); пошук — як у tools-dashboard-data.py.
_here = os.path.dirname(os.path.abspath(__file__))
for _c in (os.environ.get("STRW_ENGINE_LIB", ""),
           os.path.join(_here, "..", "engine", "lib"),
           os.path.join(os.environ.get("STRW_ROOT", os.path.expanduser("~/Developer/STRW")),
                        "strw-factory", "scripts", "engine", "lib")):
    if _c and os.path.isfile(os.path.join(_c, "yaml_nodup.py")):
        sys.path.insert(0, _c)
        break
try:
    from yaml_nodup import load_nodup
except ImportError:
    sys.stderr.write("ERROR: немає lib/yaml_nodup.py — читач YAML рушія (ні STRW_ENGINE_LIB, ні scripts/engine/lib "
                     "поруч, ні STRW_ROOT/strw-factory); не поміряти (код 2)\n")
    sys.exit(2)
import yaml  # noqa: E402 — після вибору шляху читача

RC_REFUSE = 2
OWNER = "andresiletsky-bit"
REPOS = ("strw-ops", "strw-factory", "strw-state", "pact-ios", "pact-backend")
GH_FIELDS = "number,title,isDraft,author,headRefName,createdAt,updatedAt,url,reviewDecision,statusCheckRollup"
GH_LIMIT = 200          # рівно стільки рядків у відповіді — список обрізано, відмова
SESSIONS_DEFAULT_LIMIT = 20
# Словник станів — validate-items.sh (STATES); «інші» в смугах — проміжні стани циклу.
ITEM_STATES = ("ready", "claimed", "running", "gated", "reviewed", "merge-pending", "done", "blocked", "parked")
LANE_COLS = ("ready", "running", "blocked", "done", "parked")
TRIAGE_KINDS = ("question", "finding", "error")
CHECK_FAIL = {"FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"}
CHECK_OK = {"SUCCESS", "NEUTRAL", "SKIPPED"}
IDLE_HOURS = 24
# Назву сесії пише людина; адреса тестувальника в ній — персональні дані, дашборду не потрібні.
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
PR_STALE_DAYS = 7


class Refuse(Exception):
    pass


def parse_ts(v, what):
    """ISO-UTC (з мілісекундами чи без) або YAML datetime → aware UTC. Інше — відмова."""
    if isinstance(v, dt.datetime):
        return v.astimezone(dt.timezone.utc) if v.tzinfo else v.replace(tzinfo=dt.timezone.utc)
    if isinstance(v, str):
        s = v[:-1] if v.endswith("Z") else None
        if s is not None:
            if "." in s:
                s = s.split(".", 1)[0]
            for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M"):
                try:
                    return dt.datetime.strptime(s, fmt).replace(tzinfo=dt.timezone.utc)
                except ValueError:
                    pass
    raise Refuse("%s: «%s» — не час UTC (YYYY-MM-DDTHH:MM[:SS[.fff]]Z)" % (what, v))


def parse_day(v, what):
    """YAML date або рядок YYYY-MM-DD → date. Інше — відмова."""
    if isinstance(v, dt.datetime):
        return v.date()
    if isinstance(v, dt.date):
        return v
    if isinstance(v, str):
        try:
            return dt.datetime.strptime(v, "%Y-%m-%d").date()
        except ValueError:
            pass
    raise Refuse("%s: «%s» — не дата YYYY-MM-DD" % (what, v))


def fmt_ts(t):
    return t.strftime("%Y-%m-%dT%H:%MZ")


def text(v):
    return "" if v is None else str(v)


def need_str(d, k, where):
    v = d.get(k)
    if not isinstance(v, str) or not v.strip():
        raise Refuse("%s: немає %s (або не рядок)" % (where, k))
    return v


def sha256_of(paths):
    h = hashlib.sha256()
    for p in paths:
        h.update(os.path.basename(p).encode("utf-8") + b"\0")
        h.update(open(p, "rb").read())
        h.update(b"\0")
    return h.hexdigest()


# --- сесії ---------------------------------------------------------------------------------------
def build_sessions(raw, now):
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as e:
        raise Refuse("сесії: не JSON (%s)" % str(e).splitlines()[0])
    if not isinstance(data, list):
        raise Refuse("сесії: очікувався масив виходу list_sessions")
    rows, seen, archived = [], set(), 0
    for i, s in enumerate(data):
        where = "сесії[%d]" % i
        if not isinstance(s, dict):
            raise Refuse("%s: не об'єкт" % where)
        sid = need_str(s, "sessionId", where)
        where = "сесії[%d] %s" % (i, sid)
        if sid in seen:
            raise Refuse("%s: дубль sessionId" % where)
        seen.add(sid)
        if s.get("isArchived") is True:
            archived += 1
            continue
        if not isinstance(s.get("isRunning"), bool):
            raise Refuse("%s: isRunning не true/false" % where)
        last = parse_ts(s.get("lastActivityAt"), where + ": lastActivityAt")
        pr = s.get("prNumber")
        if pr is not None and (isinstance(pr, bool) or not isinstance(pr, int)):
            raise Refuse("%s: prNumber %r — не ціле" % (where, pr))
        g = s.get("group")
        rows.append({
            "table": "sessions",
            "id": sid,
            "name": text(s.get("name")),
            "title": EMAIL.sub("[email]", text(s.get("title"))),
            "group": text(g.get("name")) if isinstance(g, dict) else "",
            "running": s["isRunning"],
            "pr": pr,
            "pr_state": text(s.get("prState")),
            "last_activity": fmt_ts(last),
            "idle_hours": max(0, int((now - last).total_seconds() // 3600)),
            "started_by": text(s.get("startedBy")),
        })
        rows[-1]["idle"] = rows[-1]["idle_hours"] >= IDLE_HOURS
    rows.sort(key=lambda r: (r["last_activity"], r["id"]), reverse=True)
    return rows, archived


# --- PR ------------------------------------------------------------------------------------------
def checks_of(rollup, where):
    if rollup is None:
        rollup = []
    if not isinstance(rollup, list):
        raise Refuse("%s: statusCheckRollup не список" % where)
    if not rollup:
        return "none"
    states = []
    for c in rollup:
        if not isinstance(c, dict):
            raise Refuse("%s: запис statusCheckRollup не об'єкт" % where)
        if c.get("__typename") == "StatusContext" or "state" in c and "status" not in c:
            st = text(c.get("state")).upper()
            states.append("fail" if st in CHECK_FAIL else "ok" if st in CHECK_OK else "pending")
        else:  # CheckRun: до завершення conclusion порожній — це й є «йде»
            con = text(c.get("conclusion")).upper()
            states.append("fail" if con in CHECK_FAIL else "ok" if con in CHECK_OK else "pending")
    if "fail" in states:
        return "fail"
    if "pending" in states:
        return "pending"
    return "pass"


def build_prs(raws, now):
    rows = []
    for repo in REPOS:
        raw = raws[repo]
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as e:
            raise Refuse("PR %s: не JSON (%s)" % (repo, str(e).splitlines()[0]))
        if not isinstance(data, list):
            raise Refuse("PR %s: очікувався масив gh pr list --json" % repo)
        if len(data) >= GH_LIMIT:
            raise Refuse("PR %s: %d рядків = --limit %d, список обрізано" % (repo, len(data), GH_LIMIT))
        seen = set()
        for i, p in enumerate(data):
            where = "PR %s[%d]" % (repo, i)
            if not isinstance(p, dict):
                raise Refuse("%s: не об'єкт" % where)
            n = p.get("number")
            if isinstance(n, bool) or not isinstance(n, int):
                raise Refuse("%s: number %r — не ціле" % (where, n))
            where = "PR %s#%d" % (repo, n)
            if n in seen:
                raise Refuse("%s: дубль номера" % where)
            seen.add(n)
            if not isinstance(p.get("isDraft"), bool):
                raise Refuse("%s: isDraft не true/false" % where)
            created = parse_ts(p.get("createdAt"), where + ": createdAt")
            updated = parse_ts(p.get("updatedAt"), where + ": updatedAt")
            a = p.get("author")
            rows.append({
                "table": "prs",
                "key": "%s#%d" % (repo, n),
                "repo": repo,
                "number": n,
                "title": need_str(p, "title", where),
                "draft": p["isDraft"],
                "author": text(a.get("login")) if isinstance(a, dict) else "",
                "branch": text(p.get("headRefName")),
                "checks": checks_of(p.get("statusCheckRollup"), where),
                "review": text(p.get("reviewDecision")),
                "age_days": max(0, int((now - created).total_seconds() // 86400)),
                "updated_days": max(0, int((now - updated).total_seconds() // 86400)),
                "url": need_str(p, "url", where),
            })
            rows[-1]["stale"] = rows[-1]["updated_days"] >= PR_STALE_DAYS
    order = {r: i for i, r in enumerate(REPOS)}
    rows.sort(key=lambda r: (order[r["repo"]], r["number"]))
    repos = []
    for repo in REPOS:
        mine = [r for r in rows if r["repo"] == repo]
        repos.append({
            "table": "repos",
            "repo": repo,
            "open": len(mine),
            "draft": sum(1 for r in mine if r["draft"]),
            "checks_fail": sum(1 for r in mine if r["checks"] == "fail"),
            "checks_pending": sum(1 for r in mine if r["checks"] == "pending"),
        })
    return rows, repos


# --- strw-state: тріаж і реєстр ------------------------------------------------------------------
def front_matter(path, where):
    try:
        t = open(path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError) as e:
        raise Refuse("%s: не читається (%s)" % (where, type(e).__name__))
    if not t.startswith("---\n"):
        raise Refuse("%s: немає передмови YAML (---)" % where)
    end = t.find("\n---", 4)
    if end < 0:
        raise Refuse("%s: передмова не закрита (---)" % where)
    try:
        fm = load_nodup(t[4:end + 1])
    except (yaml.YAMLError, ValueError) as e:
        raise Refuse("%s: передмова не читається: %s" % (where, str(e).splitlines()[0] if str(e) else type(e).__name__))
    if not isinstance(fm, dict):
        raise Refuse("%s: передмова не мапа" % where)
    return fm


def build_triage(state, today):
    d = os.path.join(state, "triage", "open")
    if not os.path.isdir(d):
        raise Refuse("немає теки %s (--state — корінь strw-state?)" % d)
    rows, seen = [], {}
    for p in sorted(glob.glob(os.path.join(d, "*.md"))):
        where = "triage/open/" + os.path.basename(p)
        fm = front_matter(p, where)
        tid = need_str(fm, "id", where)
        if tid in seen:
            raise Refuse("%s: дубль id %s (і %s)" % (where, tid, seen[tid]))
        seen[tid] = os.path.basename(p)
        if fm.get("status") != "open":
            raise Refuse("%s: status «%s» у triage/open — картка не на своєму місці" % (where, fm.get("status")))
        kind = need_str(fm, "kind", where)
        db = fm.get("decide_by")
        due = parse_day(db, where + ": decide_by") if db not in (None, "") else None
        rows.append({
            "table": "triage",
            "id": tid,
            "kind": kind,
            "product": text(fm.get("product")),
            "class": text(fm.get("class")),
            "date": parse_day(fm.get("date"), where + ": date").isoformat(),
            "decide_by": due.isoformat() if due else "",
            "overdue_days": (today - due).days if due and today > due else 0,
            "summary": text(fm.get("summary")),
        })
    rows.sort(key=lambda r: (r["decide_by"] or "9999", r["id"]))
    return rows


def build_items(state):
    d = os.path.join(state, "engine", "items")
    if not os.path.isdir(d):
        raise Refuse("немає теки %s (--state — корінь strw-state?)" % d)
    rows, seen = [], {}
    for p in sorted(glob.glob(os.path.join(d, "*.yaml"))):
        where = "engine/items/" + os.path.basename(p)
        try:
            it = load_nodup(open(p, encoding="utf-8").read())
        except (OSError, UnicodeDecodeError, yaml.YAMLError, ValueError) as e:
            raise Refuse("%s: не читається: %s" % (where, str(e).splitlines()[0] if str(e) else type(e).__name__))
        if not isinstance(it, dict):
            raise Refuse("%s: не мапа" % where)
        iid = need_str(it, "id", where)
        if iid in seen:
            raise Refuse("%s: дубль id %s (і %s)" % (where, iid, seen[iid]))
        seen[iid] = os.path.basename(p)
        st = it.get("state")
        if st not in ITEM_STATES:
            raise Refuse("%s: state «%s» поза словником validate-items" % (where, st))
        lane = need_str(it, "lane", where)
        bb = it.get("blocked_by") or []
        if not isinstance(bb, list) or not all(isinstance(x, str) for x in bb):
            raise Refuse("%s: blocked_by не список рядків" % where)
        ev = it.get("evidence")
        pr = ev.get("pr") if isinstance(ev, dict) else None
        rows.append({
            "table": "items",
            "id": iid,
            "product": text(it.get("product")),
            "lane": lane,
            "state": st,
            "size": text(it.get("size")),
            "autonomy": text(it.get("autonomy")),
            "repo": text(it.get("repo")),
            "blocked_by": ", ".join(bb),
            "on_ceo": any(x.startswith("ceo:") for x in bb),
            "pr": pr if isinstance(pr, int) and not isinstance(pr, bool) else None,
        })
    rows.sort(key=lambda r: r["id"])
    lanes = []
    for lane in sorted({r["lane"] for r in rows}):
        mine = [r for r in rows if r["lane"] == lane]
        row = {"table": "lanes", "lane": lane, "total": len(mine)}
        for s in LANE_COLS:
            row[s] = sum(1 for r in mine if r["state"] == s)
        row["other"] = sum(1 for r in mine if r["state"] not in LANE_COLS)
        lanes.append(row)
    return rows, lanes


def build(state, sessions_raw, pr_raws, now):
    sessions, archived = build_sessions(sessions_raw, now)
    prs, repos = build_prs(pr_raws, now)
    triage = build_triage(state, now.date())
    items, lanes = build_items(state)

    def n(rows, f):
        return sum(1 for r in rows if f(r))
    s = {
        "table": "summary",
        "sessions": len(sessions),
        "sessions_running": n(sessions, lambda r: r["running"]),
        "sessions_idle_24h": n(sessions, lambda r: r["idle"]),
        "sessions_pr_open": n(sessions, lambda r: r["pr_state"] == "OPEN"),
        "sessions_archived_skipped": archived,
        "prs_open": len(prs),
        "prs_draft": n(prs, lambda r: r["draft"]),
        "prs_checks_fail": n(prs, lambda r: r["checks"] == "fail"),
        "prs_checks_pending": n(prs, lambda r: r["checks"] == "pending"),
        "prs_stale_7d": n(prs, lambda r: r["stale"]),
        "triage_open": len(triage),
        "triage_overdue": n(triage, lambda r: r["overdue_days"] > 0),
    }
    for k in TRIAGE_KINDS:
        s["triage_" + k] = n(triage, lambda r, k=k: r["kind"] == k)
    s["triage_other"] = n(triage, lambda r: r["kind"] not in TRIAGE_KINDS)
    s["items"] = len(items)
    for st in LANE_COLS:
        s["items_" + st] = n(items, lambda r, st=st: r["state"] == st)
    s["items_other"] = n(items, lambda r: r["state"] not in LANE_COLS)
    s["items_on_ceo"] = n(items, lambda r: r["state"] == "blocked" and r["on_ceo"])
    s["lanes"] = len(lanes)
    s["idle_limit_hours"] = IDLE_HOURS      # пороги — даними: сторінка називає їх із summary, не повторює числом
    s["pr_stale_limit_days"] = PR_STALE_DAYS
    return [s] + sessions + prs + repos + triage + items + lanes


def gh_fetch(out_dir):
    """Сирі відповіді `gh pr list` у <out>/prs/<repo>.json; помилка gh — відмова з назвою репо."""
    d = os.path.join(out_dir, "prs")
    os.mkdir(d)
    raws = {}
    for repo in REPOS:
        cmd = ["gh", "pr", "list", "--repo", "%s/%s" % (OWNER, repo), "--state", "open",
               "--limit", str(GH_LIMIT), "--json", GH_FIELDS]
        try:
            r = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except OSError as e:
            raise Refuse("gh не запускається (%s)" % e)
        if r.returncode != 0:
            raise Refuse("gh pr list %s: код %d — %s" % (repo, r.returncode, r.stderr.decode("utf-8", "replace").strip()[:200]))
        with open(os.path.join(d, repo + ".json"), "wb") as f:
            f.write(r.stdout)
        raws[repo] = r.stdout
    return raws, [os.path.join(d, repo + ".json") for repo in REPOS]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--state", required=True)
    ap.add_argument("--sessions", required=True)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--prs-dir")
    g.add_argument("--gh", action="store_true")
    ap.add_argument("--out", required=True)
    ap.add_argument("--now", required=True)
    ap.add_argument("--state-label", default="", help="звідки state, для summary.state_source (типово — шлях)")
    a = ap.parse_args()
    if not os.path.isdir(a.out) or os.listdir(a.out):
        sys.stderr.write("ERROR: --out %s — не порожня тека (потрібна свіжа: mktemp -d); дашборд не оновлено (код 2)\n" % a.out)
        return RC_REFUSE
    try:
        try:
            now = dt.datetime.strptime(a.now, "%Y-%m-%dT%H:%MZ")
        except ValueError:
            try:
                now = dt.datetime.strptime(a.now, "%Y-%m-%dT%H:%M:%SZ")
            except ValueError:
                raise Refuse("--now «%s»: потрібен UTC YYYY-MM-DDTHH:MM[:SS]Z" % a.now)
        now = now.replace(tzinfo=dt.timezone.utc)
        shared = os.path.join(os.environ.get("STRW_ROOT", os.path.expanduser("~/Developer/STRW")), "strw-state")
        if os.path.realpath(a.state) == os.path.realpath(shared):
            raise Refuse("--state %s — спільна копія strw-state (її дерево буває замороженим); дай знімок "
                         "origin/main — scripts/native/hub-dashboard-refresh.sh" % a.state)
        try:
            sessions_raw = open(a.sessions, "rb").read()
        except OSError as e:
            raise Refuse("сесії %s не читаються (%s)" % (a.sessions, type(e).__name__))
        if a.gh:
            pr_raws, pr_paths = gh_fetch(a.out)
        else:
            pr_raws, pr_paths = {}, []
            for repo in REPOS:
                p = os.path.join(a.prs_dir, repo + ".json")
                try:
                    pr_raws[repo] = open(p, "rb").read()
                except OSError:
                    raise Refuse("PR %s: немає знімка %s — дашборд показав би репо без PR" % (repo, p))
                pr_paths.append(p)
        rows = build(a.state, sessions_raw, pr_raws, now)
    except Refuse as e:
        sys.stderr.write("ERROR: %s; дашборд не оновлено (код 2)\n" % e)
        return RC_REFUSE
    s = rows[0]
    s["generated_at"] = fmt_ts(now)
    s["state_source"] = a.state_label or a.state
    s["sessions_sha256"] = hashlib.sha256(sessions_raw).hexdigest()
    s["prs_sha256"] = sha256_of(pr_paths)
    if s["sessions"] + s["sessions_archived_skipped"] == SESSIONS_DEFAULT_LIMIT:
        sys.stderr.write("УВАГА: у знімку сесій рівно %d рядків — стільки list_sessions дає без limit; "
                         "можливо, обрізано (передай limit: 200)\n" % SESSIONS_DEFAULT_LIMIT)
    tmp = os.path.join(a.out, ".hub.json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=1)
        f.write("\n")
    os.replace(tmp, os.path.join(a.out, "hub.json"))
    print("hub-dashboard-data: сесій %d · PR %d · тріаж %d · елементів %d · %s"
          % (s["sessions"], s["prs_open"], s["triage_open"], s["items"], os.path.join(a.out, "hub.json")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
