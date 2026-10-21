#!/usr/bin/env python3
# validate-l4-trace.py — рівень 0 для trace L4 (тип `l4-trace` у validate-artifact.sh).
# Usage: validate-l4-trace.py <growth-report.md>   → 0 PASS · 1 FAIL · 2 помилка виклику
#
# ЧОМУ МЕХАНІЗМ, А НЕ ПРОЗА. Шість раундів чекера 6a на #29/#23 (19.10) стерегли
# безпеку черги Metricool пінами на ключові слова в паспорті L4 — і кожен раунд
# знаходив новий синонім того самого класу («відразу в розклад (Schedule now)»,
# «будь-чий, крім Andrii», `autoPublish: True`). Вердикт р.3: пін на прозу не
# збіжиться. Тут стережеться не текст паспорта, а те, що maker ЗРОБИВ: виклики в
# trace (паспорт L4 п. 4a–4c, 5; контракт — references/artifact-contracts.md §growth-report).
#
# Межа: trace пише сам maker. Скрипт ловить порушення, яке maker записав чесно
# (і запис у неканонічній формі — згадку інструмента запису поза `- call:`), але
# не виклик, який у trace не потрапив. Стану самого Metricool він не читає.
#
# Лише stdlib: python3 є і на Mac (3.9), і в хмарі; bash 3.2 не має JSON-розбору,
# а `"autoPublish": false` регуляркою — це знову форма замість властивості.
import io
import json
import os
import re
import sys

TOOLS = {
    "getBrandSettings", "getScheduledPosts", "getBestTimeToPostByNetwork",
    "getAnalyticsAvailableMetrics", "getAnalyticsDataByMetrics",
    "createScheduledPost", "updateScheduledPost",
    "createScheduledPostForReview", "sendScheduledPostForReview",
}
FOR_REVIEW = ("createScheduledPostForReview", "sendScheduledPostForReview")
WRITES = FOR_REVIEW + ("updateScheduledPost", "createScheduledPost")
# Межа слова вручну: «createScheduledPost» — підрядок «createScheduledPostForReview».
WRITE_MENTION = re.compile(r"(?<![A-Za-z])(createScheduledPostForReview|sendScheduledPostForReview"
                           r"|updateScheduledPost|createScheduledPost)(?![A-Za-z])")
ERROR_RESP = re.compile(r"error|does not allow|not allowed|помилк", re.I)
SOCIAL = re.compile(r"instagram|tiktok|youtube|facebook|linkedin|threads|pinterest|twitter|соцмереж"
                    r"|metricool|reels|shorts", re.I)
# Цифри, що метрикою не є: посилання, дати, час, ідентифікатори (W43, pact-001,
# tri-138), номери PR, нумерація списку. Решта цифр речення — число.
NOT_A_NUMBER = [
    re.compile(r"https?://\S+"),
    re.compile(r"\d{4}-\d{2}-\d{2}"),
    re.compile(r"(?<!\d)\d{1,2}:\d{2}(?!\d)"),
    re.compile(r"[A-Za-z]+[-_]?\d+[A-Za-z0-9_-]*"),
    re.compile(r"#\d+"),
    re.compile(r"^\s*\d+[.)]\s"),
    # посилання на пункти: «п. 5», «§3», «4a–4c» (лише a–h: «5k»/«5к» — це число)
    re.compile(r"(?:п\.|§)\s*\d+[a-h]?(?!\w)"),
    re.compile(r"(?<![\d.,])\d+[a-h](?!\w)"),
]
HEADING = re.compile(r"^(#{1,6})\s+(.*)$")


def numbers_in(text):
    for rx in NOT_A_NUMBER:
        text = rx.sub(" ", text)
    return re.findall(r"\d", text)


def sentences(lines):
    for ln in lines:
        for s in re.split(r"(?<=[.!?;])\s+", ln):
            if s.strip():
                yield s


def split_trace(lines):
    """→ (trace, report, found). Trace — від заголовка «Trace (L4)» до наступного
    заголовка того ж або вищого рівня; усе інше — сам growth-report."""
    trace, report, level, found = [], [], None, False
    for ln in lines:
        m = HEADING.match(ln)
        if m and level is not None and len(m.group(1)) <= level:
            level = None
        if m and level is None and "Trace (L4)" in m.group(2):
            level, found = len(m.group(1)), True
            continue
        (trace if level is not None else report).append(ln)
    return trace, report, found


def parse_calls(trace):
    """Рядки trace → виклики. `- call: <tool> [json]`, під ним `  > …` (відповідь
    дослівно) і `  стан: …`. Решта — `- mcp:`, `- reviewer:`, `- inbox:` і текст."""
    calls, other, cur = [], [], None
    for i, ln in enumerate(trace):
        m = re.match(r"^- call:\s*`?([A-Za-z_.]+)`?\s*(.*)$", ln)
        if m:
            cur = {"n": len(calls) + 1, "tool": m.group(1), "args_raw": m.group(2).strip(),
                   "resp": [], "state": None, "idx": i}
            calls.append(cur)
            continue
        if cur is not None and re.match(r"^\s+>", ln):
            cur["resp"].append(re.sub(r"^\s+>\s?", "", ln))
            continue
        ms = re.match(r"^\s+стан:\s*(.*)$", ln)
        if cur is not None and ms:
            cur["state"] = ms.group(1).strip()
            continue
        if ln.strip():
            if not re.match(r"^\s", ln):
                cur = None
            other.append((i, ln))
    return calls, other


def company_context_path():
    p = os.environ.get("STRW_COMPANY_CONTEXT")
    if p:
        return p
    root = os.environ.get("STRW_ROOT") or os.path.join(os.path.expanduser("~"), "Developer", "STRW")
    return os.path.join(root, "strw-state", "company-context.md")


def check(lines):
    trace, report, found = split_trace(lines)
    if not found:
        return ["немає секції «Trace (L4)» — артефакт без trace не приймається (loop-passport §3)"], 0, 0
    errs = []
    calls, other = parse_calls(trace)
    text = [ln for _, ln in other]

    mcp = " ".join(ln for ln in text if re.match(r"^- mcp:", ln))
    if not mcp:
        errs.append("немає рядка `- mcp:` — вивід `claude mcp get metricool` дослівно (паспорт L4 п. 5)")
    connected = bool(re.search(r"connected", mcp, re.I)) and not re.search(
        r"needs authentication|not connected|failed|disconnected", mcp, re.I)

    reviewer, reviewer_idx = None, None
    for i, ln in other:
        m = re.match(r"^- reviewer:\s*`?([^\s`]+@[^\s`]+?)`?(\s|$)", ln)
        if m:
            reviewer, reviewer_idx = m.group(1), i
            break
    inbox = any(re.match(r"^- inbox:\s*\S", ln) for ln in text)

    # Виклик запису, записаний прозою, скрипт не побачив би зовсім — тому канон
    # один: інструмент запису в trace існує лише рядком `- call:`.
    for i, ln in other:
        m = WRITE_MENTION.search(ln)
        if m:
            errs.append("рядок trace %d: `%s` поза рядком `- call:` — виклик запису фіксується лише як `- call: %s {…}`"
                        % (i + 1, m.group(1), m.group(1)))

    for c in calls:
        tag = "виклик #%d %s" % (c["n"], c["tool"])
        if c["tool"] not in TOOLS:
            errs.append("%s: такого інструмента немає серед дев'яти сервера Metricool (паспорт L4 п. 4)" % tag)
            continue
        if not c["resp"]:
            errs.append("%s: немає цитати відповіді (`  > …`)" % tag)
        if c["tool"] == "createScheduledPost":
            errs.append("%s: прямий розклад без людини, у L4 заборонений завжди (паспорт 4b)" % tag)
            continue
        if c["tool"] not in WRITES:
            continue
        try:
            args = json.loads(c["args_raw"]) if c["args_raw"] else None
        except ValueError:
            args = None
        if not isinstance(args, dict):
            errs.append("%s: аргументи не JSON-об'єкт в одному рядку — передумову не перевірити" % tag)
            continue
        info = args.get("info")
        if not isinstance(info, dict) or info.get("autoPublish") is not False:
            errs.append("%s: немає `info.autoPublish: false` (за замовчуванням True — Metricool публікує сам; паспорт 4b)"
                        % tag)
        if c["tool"] in FOR_REVIEW:
            if args.get("approvalSystem") != "all":
                errs.append("%s: approvalSystem=%s, дозволено лише \"all\" (паспорт 4a)"
                            % (tag, json.dumps(args.get("approvalSystem"), ensure_ascii=False)))
            revs = [r.strip() for r in str(args.get("reviewers") or "").split(",") if r.strip()]
            if reviewer is None or reviewer_idx > c["idx"]:
                errs.append("%s: перед викликом немає `- reviewer: <email>` з company-context (передумова 4a)" % tag)
            elif revs != [reviewer]:
                errs.append("%s: reviewers=%s, а мусить бути рівно email Andrii %s (паспорт 4a)"
                            % (tag, json.dumps(args.get("reviewers"), ensure_ascii=False), reviewer))

    # Передумова 4a: email рев'юера — з company-context, не вигаданий maker'ом.
    if reviewer is not None and any(c["tool"] in FOR_REVIEW for c in calls):
        cc = company_context_path()
        try:
            cc_text = io.open(cc, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            cc_text = None
        if cc_text is None:
            errs.append("company-context не прочитано (%s) — email рев'юера не звірено (передумова 4a; STRW_COMPANY_CONTEXT)"
                        % cc)
        elif reviewer not in cc_text:
            errs.append("reviewer %s відсутній у company-context (%s) — передумова 4a не виконана" % (reviewer, cc))

    # Послідовність (паспорт 4b–4c): після КОЖНОГО запису одразу getScheduledPosts;
    # після updateScheduledPost наступний запис — sendScheduledPostForReview;
    # помилка ForReview — без повтору й з карткою; стан — pending review або доказ plannerUrl.
    for k, c in enumerate(calls):
        if c["tool"] not in WRITES or c["tool"] == "createScheduledPost":
            continue
        tag = "виклик #%d %s" % (c["n"], c["tool"])
        nxt = calls[k + 1] if k + 1 < len(calls) else None
        if nxt is None or nxt["tool"] != "getScheduledPosts":
            errs.append("%s: одразу після нього немає getScheduledPosts (паспорт 4b — стан читається після кожного виклику)"
                        % tag)
            nxt = None
        if c["tool"] == "updateScheduledPost":
            later = [x for x in calls[k + 1:] if x["tool"] != "getScheduledPosts"]
            if not later or later[0]["tool"] != "sendScheduledPostForReview":
                errs.append("%s: наступний запис — не sendScheduledPostForReview (правка скидає review, паспорт 4b)" % tag)
            continue
        resp = " ".join(c["resp"])
        if ERROR_RESP.search(resp):
            if any(x["tool"] == c["tool"] for x in calls[k + 1:]):
                errs.append("%s: відповів помилкою, а виклик повторено (паспорт 4c — без повтору)" % tag)
            if not inbox:
                errs.append("%s: відповів помилкою, а рядка `- inbox: <картка>` немає (паспорт 4c)" % tag)
            continue
        if nxt is None:
            continue
        state = nxt["state"]
        if state is None:
            errs.append("%s: під getScheduledPosts немає рядка `  стан: …` (паспорт 4b)" % tag)
        elif re.fullmatch(r"(?i)pending review\.?", state):
            pass
        elif state.startswith("поле стану не встановлено"):
            if "plannerUrl" not in resp:
                errs.append("%s: «поле стану не встановлено», а у відповіді ForReview немає plannerUrl — доказу «на затвердження» немає (паспорт 4b)"
                            % tag)
        elif not inbox:
            errs.append("%s: стан «%s» — не pending review, а рядка `- inbox: <картка>` немає (паспорт 4c)" % (tag, state))

    # Соцметрики (паспорт п. 5): число по соцмережах — лише з getAnalyticsDataByMetrics
    # при підключеному MCP; «н/д: …» — без жодної цифри в тому ж реченні.
    src = [c for c in calls if c["tool"] == "getAnalyticsDataByMetrics" and c["resp"]]
    for s in sentences(report):
        if "н/д" in s.lower():
            if numbers_in(s):
                errs.append("«н/д» з числом у тому ж реченні — пропуск цифр не має (паспорт п. 5): %s" % s.strip())
            continue
        if SOCIAL.search(s) and numbers_in(s):
            if not src:
                errs.append("число по соцмережах без getAnalyticsDataByMetrics у trace: %s" % s.strip())
            elif not connected:
                errs.append("число по соцмережах, а `- mcp:` не каже connected: %s" % s.strip())

    return errs, len(calls), sum(1 for c in calls if c["tool"] in WRITES)


def main(argv):
    if len(argv) != 2:
        print("Usage: validate-l4-trace.py <growth-report.md>", file=sys.stderr)
        return 2
    path = argv[1]
    try:
        lines = io.open(path, encoding="utf-8").read().splitlines()
    except (OSError, UnicodeDecodeError) as e:
        print("FAIL: l4-trace — файл не прочитано: %s (%s)" % (path, e))
        return 2
    errs, n_calls, n_writes = check(lines)
    if errs:
        print("FAIL: l4-trace (%s)" % path)
        for e in errs:
            print("  " + e)
        return 1
    print("PASS: l4-trace OK (%s, викликів %d, записів %d)" % (path, n_calls, n_writes))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
