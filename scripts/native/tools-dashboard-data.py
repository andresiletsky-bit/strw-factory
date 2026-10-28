#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Дані приватного Dashboard реєстру інструментів (factory.native-outputs).

    tools-dashboard-data.py --registry <tools.yaml> --out <тека> --now <YYYY-MM-DDTHH:MM[:SS]Z>

Читає реєстр за схемою v1/v1.1 (strw-state/engine/tools.yaml) і пише три файли-датасети типу
Dashboard застосунку Claude: tools.json (рядок на інструмент), tasks.json (рядок на task_type
словника), summary.json (один рядок підсумків). Як вони потрапляють у Dashboard — крок сесії,
`references/native-outputs.md` § «Живий Dashboard реєстру».

Не валідатор реєстру (це strw-state/scripts/tools-registry-check.sh). Відмовляє (код 2, причина
одним рядком, жодного файла у виході) лише там, де дашборд збрехав би: загубив рядок, порахував
невідоме значення, переставив порядок, назвав старий вимір свіжим. `--out` — порожня тека (mktemp -d):
у теці з попереднього прогону відмова лишила б старі файли, які легко прийняти за нові.

Експорт — ЯВНИЙ перелік полів (EXPORT нижче): probe.cmd/how, measured.by, source у дашборд не
йдуть — це службові команди, а не те, що читає людина.

`--now` — обов'язковий і лише UTC (`Z`): вік виміру залежить від нього, тож прогін відтворюваний.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import sys

# Читач YAML без дублікатів ключів — один на весь рушій (tri-094). Кандидати: STRW_ENGINE_LIB →
# сусідня scripts/engine/lib → STRW_ROOT/strw-factory/…; cwd у sys.path не потрапляє (його там і
# немає при запуску скриптом: sys.path[0] — тека скрипта).
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
STATUSES = ("active", "candidate", "forbidden")
RESULTS = ("available", "unavailable", "needs-auth")
STALE_DAYS = 14
EXPORT = ("id", "name", "kind", "status", "rank", "tasks", "roles", "loops", "contours", "provides",
          "probe_kind", "measured_at", "measured_result", "measured_age_days", "stale",
          "cost", "user_data", "enabled_by", "why")


class Refuse(Exception):
    pass


def parse_time(v, what):
    """ISO-UTC рядок, YAML date або datetime → aware datetime UTC. Інше — відмова."""
    if isinstance(v, dt.datetime):
        # aware з будь-яким зсувом → UTC: fmt_time дописує літерал Z (рев'ю #38: +03:00 показувався як Z)
        return v.astimezone(dt.timezone.utc) if v.tzinfo else v.replace(tzinfo=dt.timezone.utc)
    if isinstance(v, dt.date):
        return dt.datetime(v.year, v.month, v.day, tzinfo=dt.timezone.utc)
    if isinstance(v, str):
        for fmt in ("%Y-%m-%dT%H:%MZ", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d"):
            try:
                return dt.datetime.strptime(v, fmt).replace(tzinfo=dt.timezone.utc)
            except ValueError:
                pass
    raise Refuse("%s: «%s» — не дата/час UTC (YYYY-MM-DD або YYYY-MM-DDTHH:MM[:SS]Z)" % (what, v))


def fmt_time(t):
    return t.strftime("%Y-%m-%dT%H:%MZ")


def str_list(v, what, nonempty=False):
    if v is None:
        v = []
    if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
        raise Refuse("%s: очікувався список рядків, є %r" % (what, v))
    if nonempty and not v:
        raise Refuse("%s: порожній список" % what)
    return v


def build(reg, now):
    if not isinstance(reg, dict):
        raise Refuse("реєстр: верхній рівень не мапа")
    if reg.get("schema_version") != 1:
        raise Refuse("schema_version: %r — генератор знає лише 1 (v1/v1.1)" % reg.get("schema_version"))
    vocab = reg.get("vocab")
    if not isinstance(vocab, dict):
        raise Refuse("vocab: немає або не мапа")
    kinds = str_list(vocab.get("kinds"), "vocab.kinds", nonempty=True)
    task_types = vocab.get("task_types")
    if not isinstance(task_types, dict):
        raise Refuse("vocab.task_types: немає або не мапа")
    tools = reg.get("tools")
    if not isinstance(tools, list):
        raise Refuse("tools: немає або не список")

    rows, seen, row_tasks = [], set(), {}
    for i, t in enumerate(tools):
        where = "tools[%d]" % i
        if not isinstance(t, dict):
            raise Refuse("%s: не мапа" % where)
        tid = t.get("id")
        if not isinstance(tid, str) or not tid:
            raise Refuse("%s: немає id (або не рядок)" % where)
        where = "tools[%d] %s" % (i, tid)
        if tid in seen:
            raise Refuse("%s: дубль id" % where)
        seen.add(tid)
        if t.get("kind") not in kinds:
            raise Refuse("%s: kind «%s» поза vocab.kinds" % (where, t.get("kind")))
        if "status" not in t:
            raise Refuse("%s: немає status" % where)
        if t["status"] not in STATUSES:
            raise Refuse("%s: status «%s» поза %s" % (where, t["status"], "|".join(STATUSES)))
        tasks = str_list(t.get("tasks"), where + ": tasks", nonempty=True)
        if len(set(tasks)) != len(tasks):
            raise Refuse("%s: дубль задачі в tasks %s" % (where, tasks))
        row_tasks[tid] = set(tasks)
        for x in tasks:
            if x not in task_types:
                raise Refuse("%s: task «%s» поза vocab.task_types" % (where, x))
        rank = t.get("rank")
        if isinstance(rank, bool) or not isinstance(rank, int):
            raise Refuse("%s: rank %r — не ціле" % (where, rank))
        avail = t.get("availability") or {}
        probe = avail.get("probe") if isinstance(avail, dict) else None
        if not isinstance(probe, dict) or not isinstance(probe.get("kind"), str):
            raise Refuse("%s: немає availability.probe.kind" % where)
        m = avail.get("measured")
        at_s, result, age, stale = "", "unmeasured", None, False
        if m is not None:
            if not isinstance(m, dict):
                raise Refuse("%s: measured не мапа" % where)
            if m.get("result") not in RESULTS:
                raise Refuse("%s: measured.result «%s» поза %s" % (where, m.get("result"), "|".join(RESULTS)))
            at = parse_time(m.get("at"), where + ": measured.at")
            if at > now:
                raise Refuse("%s: measured.at %s у майбутньому відносно --now %s" % (where, fmt_time(at), fmt_time(now)))
            at_s, result = fmt_time(at), m["result"]
            age = int((now - at).total_seconds() // 86400)
            stale = (now - at).total_seconds() > STALE_DAYS * 86400  # 14 діб і 1 год — уже застарілий
        c = t.get("constraints") or {}
        if not isinstance(c, dict):
            raise Refuse("%s: constraints не мапа" % where)
        rows.append({
            "id": tid,
            "name": str(t.get("name") or tid),
            "kind": t["kind"],
            "status": t["status"],
            "rank": rank,
            "tasks": ", ".join(tasks),
            "roles": ", ".join(str_list(t.get("roles"), where + ": roles")),
            "loops": ", ".join(str_list(t.get("loops"), where + ": loops")),
            "contours": ", ".join(str_list(t.get("contours"), where + ": contours")),
            "provides": ", ".join(str_list(t.get("provides"), where + ": provides")),
            "probe_kind": probe["kind"],
            "measured_at": at_s,
            "measured_result": result,
            "measured_age_days": age,
            "stale": stale,
            "cost": str(c.get("cost") or ""),
            "user_data": str(c.get("user_data") or ""),
            "enabled_by": str(c.get("enabled_by") or ""),
            "why": str(t.get("why") or ""),
        })
        assert tuple(rows[-1]) == EXPORT

    tasks_rows = []
    for task, desc in task_types.items():
        mine = [(r["rank"], r["id"], r["status"]) for r in rows if task in row_tasks[r["id"]]]
        active = sorted((rk, i) for rk, i, s in mine if s == "active")
        tasks_rows.append({
            "task": task,
            "description": str(desc or ""),
            "active": len(active),
            "candidate": sum(1 for _, _, s in mine if s == "candidate"),
            "forbidden": sum(1 for _, _, s in mine if s == "forbidden"),
            "active_by_rank": ", ".join(i for _, i in active),
        })

    def count(f):
        return sum(1 for r in rows if f(r))
    summary = [{
        "tools": len(rows),
        "active": count(lambda r: r["status"] == "active"),
        "candidate": count(lambda r: r["status"] == "candidate"),
        "forbidden": count(lambda r: r["status"] == "forbidden"),
        "available": count(lambda r: r["measured_result"] == "available"),
        "needs_auth": count(lambda r: r["measured_result"] == "needs-auth"),
        "unavailable": count(lambda r: r["measured_result"] == "unavailable"),
        "unmeasured": count(lambda r: r["measured_result"] == "unmeasured"),
        "stale": count(lambda r: r["stale"]),
        "task_types": len(tasks_rows),
        "task_types_without_active": sum(1 for x in tasks_rows if x["active"] == 0),
        "schema_version": 1,
    }]
    return rows, tasks_rows, summary


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--registry", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--now", required=True)
    ap.add_argument("--label", default="", help="звідки реєстр, для summary.source (типово — шлях)")
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
        try:
            raw = open(a.registry, "rb").read()
            reg = load_nodup(raw.decode("utf-8"))
        except (OSError, UnicodeDecodeError, yaml.YAMLError, ValueError) as e:  # ValueError: YAML-дата 2026-02-30
            raise Refuse("реєстр %s не читається: %s" % (a.registry, str(e).splitlines()[0] if str(e) else type(e).__name__))
        rows, tasks_rows, summary = build(reg, now)
    except Refuse as e:
        sys.stderr.write("ERROR: %s; дашборд не оновлено (код 2)\n" % e)
        return RC_REFUSE
    summary[0]["generated_at"] = fmt_time(now)
    summary[0]["registry_sha256"] = hashlib.sha256(raw).hexdigest()
    summary[0]["source"] = a.label or a.registry
    # усе пораховано до першого запису: відмова вище не лишає у виході напівнабору. Тимчасовий файл і os.replace —
    # щоб не лишити обрізаного JSON під справжнім іменем; набір із трьох файлів атомарним від цього не стає
    outs = (("tools.json", rows), ("tasks.json", tasks_rows), ("summary.json", summary))
    for name, data in outs:
        with open(os.path.join(a.out, "." + name + ".tmp"), "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=1)
            f.write("\n")
    for name, _ in outs:
        os.replace(os.path.join(a.out, "." + name + ".tmp"), os.path.join(a.out, name))
    print("tools-dashboard-data: %d інструментів · %d типів задач · %s" % (len(rows), len(tasks_rows), a.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
