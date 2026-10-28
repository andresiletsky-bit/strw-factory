#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Карта нативних виходів ↔ реєстр інструментів (factory.native-outputs).

    native-outputs-map-check.py --map references/native-outputs.md --registry <tools.yaml>

Код 0 — карта узгоджена; 1 — знахідки (кожна рядком); 2 — не поміряти (файл не читається, немає читача YAML).
Тримає: таблиця між `<!-- map:begin -->` і `<!-- map:end -->` має рівно один рядок на кожен `vocab.task_types`
реєстру (ні зайвих, ні відсутніх, ні дублів); «Куди» — один із виміряних типів, `файл` або `—`; «Статус» —
`впроваджено|кандидат|чекає CEO`, а для `—` лише `—`; «Вихід» і «Чому» непорожні; розділів типів (`### <тип>` під
`## Типи`) рівно стільки, скільки виміряно, кожен раз; id кожного запису реєстру `kind: artifact-type` —
`artifact-<тип>` одного з розділів (id, не `name`: назва — для людини, «Artifact · Docs» у #283); живий Dashboard — посилання claude.ai/artifact і рядок `Dashboard · впроваджено` у карті.
"""
import argparse
import os
import re
import sys

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
    sys.stderr.write("ERROR: немає lib/yaml_nodup.py — читач YAML рушія; не поміряти (код 2)\n")
    sys.exit(2)
import yaml  # noqa: E402

# Виміряно 28.10: Artifact action:list scope:types. Новий вимір — змінити тут і розділи карти разом.
MEASURED_TYPES = ("Dashboard", "Design", "Design System", "Docs", "Slides")
TYPE_IDS = tuple("artifact-" + x.lower().replace(" ", "-") for x in MEASURED_TYPES)
WHERE_EXTRA = ("файл", "—")
STATUSES = ("впроваджено", "кандидат", "чекає CEO")
ARTIFACT_URL = re.compile(r"https://claude\.ai/artifact/[A-Za-z0-9]{10,}")


def cells(line):
    s = line.strip()
    if not (s.startswith("|") and s.endswith("|")):
        return None
    return [c.strip() for c in s[1:-1].split("|")]


def check(text, reg):
    found = []
    if text.count("<!-- map:begin -->") != 1 or text.count("<!-- map:end -->") != 1:
        return ["маркери map:begin/map:end — не рівно по одному"]
    body = text.split("<!-- map:begin -->", 1)[1].split("<!-- map:end -->", 1)[0]
    rows = [cells(l) for l in body.splitlines() if l.strip()]
    if any(r is None for r in rows):
        found.append("між маркерами є рядок, що не є рядком таблиці")
    rows = [r for r in rows if r is not None]
    if len(rows) < 2 or not set(rows[1][0]) <= set("-: "):
        return found + ["таблиця карти без заголовка й роздільника"]
    rows = rows[2:]

    vocab = (reg.get("vocab") or {}).get("task_types") if isinstance(reg, dict) else None
    if not isinstance(vocab, dict) or not vocab:
        return found + ["реєстр без vocab.task_types"]
    sections = re.findall(r"^### (.+?)\s*$", text.split("## Типи", 1)[1].split("\n## ", 1)[0], re.M) if "## Типи" in text else []
    if sorted(sections) != sorted(MEASURED_TYPES):
        found.append("розділи типів %s ≠ виміряних %s" % (sections, list(MEASURED_TYPES)))

    seen = {}
    for r in rows:
        if len(r) != 6:
            found.append("рядок не з 6 колонок: %s" % " | ".join(r))
            continue
        tid, out, where, status, who, why = r
        m = re.fullmatch(r"`([a-z0-9-]+)`", tid)  # fullmatch: «`legal` (див.)» — не task_type
        if not m:
            found.append("task_type не в бектиках: %s" % tid)
            continue
        tid = m.group(1)
        if tid in seen:
            found.append("дубль task_type: %s" % tid)
        seen[tid] = (where, status)
        if where not in MEASURED_TYPES + WHERE_EXTRA:
            found.append("%s: «Куди» «%s» — не тип, не файл і не —" % (tid, where))
        if where == "—":
            if status != "—":
                found.append("%s: не вихід-документ, але статус «%s» (має бути —)" % (tid, status))
        elif status not in STATUSES:
            found.append("%s: статус «%s» поза %s" % (tid, status, "|".join(STATUSES)))
        if not out or out == "—":
            found.append("%s: порожній «Вихід»" % tid)
        if not why or why == "—":
            found.append("%s: порожнє «Чому»" % tid)
        if not who or who == "—":
            found.append("%s: порожнє «Хто створює»" % tid)

    for x in sorted(set(vocab) - set(seen)):
        found.append("у карті немає task_type реєстру: %s" % x)
    for x in sorted(set(seen) - set(vocab)):
        found.append("task_type карти поза vocab.task_types: %s" % x)

    for t in (reg.get("tools") or []):
        if isinstance(t, dict) and t.get("kind") == "artifact-type" and t.get("id") not in TYPE_IDS:
            found.append("запис реєстру %s (artifact-type) — не %s: такого типу в карті немає" % (t.get("id"), "|".join(TYPE_IDS)))

    live = text.split("## Живий Dashboard реєстру", 1)[1] if "## Живий Dashboard реєстру" in text else ""
    if not ARTIFACT_URL.search(live):
        found.append("розділ «Живий Dashboard реєстру» без посилання claude.ai/artifact")
    if ("Dashboard", "впроваджено") not in seen.values():
        found.append("у карті немає рядка Dashboard · впроваджено (жива інтеграція)")
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--map", required=True)
    ap.add_argument("--registry", required=True)
    a = ap.parse_args()
    try:
        text = open(a.map, encoding="utf-8").read()
        reg = load_nodup(open(a.registry, encoding="utf-8").read())
    except (OSError, UnicodeDecodeError, yaml.YAMLError) as e:
        sys.stderr.write("ERROR: не читається: %s (код 2)\n" % (str(e).splitlines()[0] if str(e) else type(e).__name__))
        return 2
    found = check(text, reg)
    for f in found:
        print("FINDING: " + f)
    if found:
        return 1
    print("native-outputs-map: узгоджено · %d task_types" % len(reg["vocab"]["task_types"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
