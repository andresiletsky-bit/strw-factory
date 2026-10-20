# -*- coding: utf-8 -*-
"""Журнал рішень і свіжість `acceptance_basis` — один код для двох читачів.

validate-items.sh (уся черга) і autonomy-route.sh (один елемент, режим A/B)
мусять казати те саме «STALE» про той самий елемент. Дві копії логіки
розходяться мовчки — клас tri-070 («два case розійшлися рівно на strw-ops»),
тому лічильник, звуження за `affects` і датовий запасний шлях живуть тут.

Семантика — дослівно та, що була у validate-items.sh до винесення (аудит
2026-09-03 П1.5; рішення №81): вузол без `affects` торкається ВСЬОГО;
порожній `affects` — помилка, не «нікого»; лічильник `decisions_log_entries`
точніший за дату і має пріоритет.
"""
import glob as globmod
import os
import re

FM_RE = re.compile(r"\A---\n(.*?)\n---\n", re.S)


def _entry(line):
    m = re.match(r"^##\s+(\d{4}-\d{2}-\d{2})\b", line)
    return (m.group(1), line[3:].strip()) if m else None


def _affects(path, rel, load_nodup, errors):
    """Список `affects` вузла, або None — «торкається всього» (стара семантика)."""
    raw = open(path, encoding="utf-8").read()
    m = FM_RE.match(raw)
    if not m:
        return None
    try:
        fm = load_nodup(m.group(1)) or {}   # affects: дублем → протухання не на ті елементи (6a #27)
    except Exception as e:
        errors.append(f"{rel}: frontmatter вузла рішення не читається: {e}")
        return None
    if not isinstance(fm, dict) or "affects" not in fm:
        return None
    a = fm.get("affects")
    if not isinstance(a, list) or not a:
        # Порожній список — не «нікого не стосується», а недописаний рядок:
        # інакше `affects: []` — найтихіший спосіб вимкнути протухання назавжди.
        errors.append(f"{rel}: `affects` мусить бути НЕПОРОЖНІМ списком "
                      f"(відсутність поля = «торкається всього»; порожній список — недописаний рядок)")
        return None
    bad = [x for x in a if not (str(x) == "factory" or
           str(x).startswith(("product:", "lane:", "item:")))]
    if bad:
        # Одрук у префіксі звузив би вплив рішення до НУЛЯ мовчки.
        errors.append(f"{rel}: `affects` містить непізнані записи {bad} — "
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


def load_decisions(decisions_log, load_nodup):
    """Записи журналу: вузли `decisions/YYYY/*.md` поруч із фасадом, інакше моноліт.

    Повертає dict: dates, titles, affects (паралельні списки в порядку дописування),
    errors (рядки ERROR), found (False — немає ні теки, ні моноліту: не поміряно).
    """
    d = {"dates": [], "titles": [], "affects": [], "errors": [], "found": True}
    decisions_dir = os.path.join(os.path.dirname(decisions_log), "decisions")
    node_files = sorted(globmod.glob(os.path.join(decisions_dir, "*", "*.md")))
    if node_files:
        for path in node_files:
            rel = os.path.relpath(path, decisions_dir)
            for line in open(path, encoding="utf-8"):
                e = _entry(line)
                if e:
                    d["dates"].append(e[0]); d["titles"].append(e[1])
                    d["affects"].append(_affects(path, rel, load_nodup, d["errors"]))
                    break
            else:
                d["errors"].append(f"{rel}: вузол рішення без заголовка "
                                   f"`## YYYY-MM-DD · …` — його не видно лічильнику")
    elif os.path.isfile(decisions_log):
        for line in open(decisions_log, encoding="utf-8"):
            e = _entry(line)
            if e:
                d["dates"].append(e[0]); d["titles"].append(e[1])
                d["affects"].append(None)   # моноліт полів не має — стара семантика
    else:
        d["found"] = False
        d["errors"].append(f"немає ні {decisions_dir}/, ні {decisions_log}")
    return d


def freshness(it, dec):
    """Свіжість підстави ОДНОГО елемента проти журналу. Форму acceptance_basis
    (мапа, ISO-дата) перевіряє викликач ДО цього — тут вона вже правильна.

    Повертає (вид, деталь):
      ("fresh", None)
      ("stale-count", (stored, count, hits, skipped)) — дописано записи, що його торкаються
      ("vanished", (stored, count))                   — лічильник більший за журнал
      ("bad-counter", stored)                         — не невід'ємне ціле
      ("stale-date", (vdate, newer))                  — запасний шлях без лічильника
      ("no-counter", vdate)                           — без лічильника, новіших дат немає
    """
    ab = it["acceptance_basis"]
    vdate = str(ab["verified_against_decisions_log_at"])[:10]
    count = len(dec["dates"])
    stored = ab.get("decisions_log_entries")
    if stored is not None:
        if not isinstance(stored, int) or stored < 0:
            return ("bad-counter", stored)
        if count > stored:
            fresh = [(dec["titles"][i], dec["affects"][i]) for i in range(stored, count)]
            hits = [t for t, a in fresh if touches(a, it)]
            if hits:
                return ("stale-count", (stored, count, hits, len(fresh) - len(hits)))
        elif count < stored:
            return ("vanished", (stored, count))
        return ("fresh", None)
    newer = sorted({dec["dates"][i] for i in range(count)
                    if dec["dates"][i] > vdate and touches(dec["affects"][i], it)})
    if newer:
        return ("stale-date", (vdate, newer))
    return ("no-counter", vdate)
