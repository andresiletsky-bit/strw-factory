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
# (і запис у неканонічній формі — згадку інструмента запису будь-де поза `- call:`
# trace), але не виклик, який у файл не потрапив, і не число, написане словами.
# Стану самого Metricool він не читає.
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
# Згадка шукається в рядку, зведеному до малих літер без `_`: «create_scheduled_post»
# і «CreateScheduledPost» — той самий інструмент (чекер 6a #33 р.1, C3/C4). Межа слова
# вручну: «createscheduledpost» — підрядок «createscheduledpostforreview».
WRITE_MENTION = re.compile(r"(?<![a-z])(createscheduledpostforreview|sendscheduledpostforreview"
                           r"|updatescheduledpost|createscheduledpost)(?![a-z])")
CALL_LINE = re.compile(r"^\s*-\s*call\s*:", re.I)
ERROR_RESP = re.compile(r"error|does not allow|not allowed|forbidden|denied|unauthori|помилк"
                        r"|\"status\"\s*:\s*4\d\d", re.I)
# Мережа (латиниця, кирилиця, абревіатури) і метрика — тригер «число по соцмережах».
# Без метрики число біля назви мережі — не вимір («3 Reels-чернетки», «Reels до 30
# секунд» — хибні червоні р.1, F/F2), окрім чисел зі знаком, відсотком чи скороченням.
SOCIAL = re.compile(r"instagram|tiktok|youtube|facebook|linkedin|threads|pinterest|twitter|соцмереж"
                    r"|інстаграм|тікток|тік-ток|ютуб|фейсбук|лінкедін|reels|shorts|stories|сторіс|metricool"
                    r"|\b(?:IG|TT|YT|FB)\b", re.I)
METRIC = re.compile(r"охоплен|підписник|перегляд|вподобан|лайк|коментар|репост|збереж|показ|залученн"
                    r"|reach|follower|impression|view|like|engagement|\bER\b|CTR|saves|shares", re.I)
# Цифри, що метрикою не є: посилання, дати, час, ідентифікатори (W43, pact-001,
# tri-138), номери PR, нумерація списку, пункти паспорта. Решта цифр речення — число.
NOT_A_NUMBER = [
    re.compile(r"https?://\S+"),
    re.compile(r"\d{4}-\d{2}-\d{2}"),
    re.compile(r"(?<!\d)\d{1,2}:\d{2}(?!\d)"),
    re.compile(r"[A-Za-z]+[-_]?\d+[A-Za-z0-9_-]*"),
    re.compile(r"#\d+"),
    re.compile(r"^\s*-?\s*\d+[.)]\s"),
    # посилання на пункти: «п. 5», «§3», «4a–4c» (лише a–h: «5k»/«5к» — це число)
    re.compile(r"(?:п\.|§)\s*\d+[a-h]?(?!\w)"),
    re.compile(r"(?<![\d.,])\d+[a-h](?!\w)"),
]
# Період вибірки («за 28 днів») — не метрика, у відповіді аналітики його немає.
PERIOD = re.compile(r"\d+\s*(?:дн|день|тиж|міс|рок|day|week|month)", re.I)
NUM = re.compile(r"(?<![\d.,])(\d{1,3}(?:[   ]\d{3})+(?:[.,]\d+)?|\d+(?:[.,]\d+)?)(?![\d])"
                 r"(\s*(?:k|к|тис|млн|m|м)(?![a-zа-яіїєґ]))?", re.I)
HEADING = re.compile(r"^(#{1,6})\s+(.*)$")
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")


def strip_not_numbers(text, period=False):
    for rx in NOT_A_NUMBER + ([PERIOD] if period else []):
        text = rx.sub(" ", text)
    return text


def numbers_in(text):
    return re.findall(r"\d", strip_not_numbers(text))


def sentences(line):
    return [s for s in re.split(r"(?<=[.!?;])\s+", line) if s.strip()]


def split_trace(lines):
    """→ (trace, report, found). Trace — від заголовка «Trace (L4)» до НАСТУПНОГО
    заголовка будь-якого рівня: підсекція під trace — уже звіт (чекер р.1, B5)."""
    trace, report, inside, found = [], [], False, False
    for ln in lines:
        m = HEADING.match(ln)
        if m:
            inside = "Trace (L4)" in m.group(2)
            found = found or inside
            if inside:
                continue
        (trace if inside else report).append(ln)
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


def as_json(text):
    try:
        return json.loads(text)
    except ValueError:
        return None


def to_float(tok):
    return float(re.sub(r"[   ]", "", tok).replace(",", "."))


def company_context_path():
    p = os.environ.get("STRW_COMPANY_CONTEXT")
    if p:
        return p
    root = os.environ.get("STRW_ROOT") or os.path.join(os.path.expanduser("~"), "Developer", "STRW")
    return os.path.join(root, "strw-state", "company-context.md")


def write_mentions(where, lines):
    out = []
    for i, ln in lines:
        m = WRITE_MENTION.search(ln.replace("_", "").lower())
        if m:
            out.append("%s рядок %d: згадка інструмента запису `%s` поза рядком `- call:` trace — виклик запису"
                       " фіксується лише як `- call: <інструмент> {…}` у «Trace (L4)»" % (where, i + 1, m.group(1)))
    return out


def check(lines):
    trace, report, found = split_trace(lines)
    if not found:
        return ["немає секції «Trace (L4)» — артефакт без trace не приймається (loop-passport §3)"], 0, 0
    errs = []
    calls, other = parse_calls(trace)
    text = [ln for _, ln in other]

    # Виклик поза trace (додаток, підсекція) скрипт не розібрав би — тому FAIL, а не тиша
    # (чекер р.1, Blocker 1: `- call: createScheduledPost` у «## Додаток» давав PASS).
    for i, ln in enumerate(report):
        if CALL_LINE.match(ln):
            errs.append("звіт рядок %d: `- call:` поза «Trace (L4)» — виклики Metricool живуть лише в trace" % (i + 1))
    errs += write_mentions("звіт", [(i, ln) for i, ln in enumerate(report) if not CALL_LINE.match(ln)])
    errs += write_mentions("trace", other)

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
    inbox_lines = [ln for ln in text if re.match(r"^- inbox:\s*\S", ln)]

    def card_for(n):
        # Картка — про ЦЕЙ виклик: рядок `- inbox:` називає його номер (`#n`), а не будь-яка
        # картка trace (чекер р.1, Nit G: помилка #2 «закривалась» карткою про TikTok).
        return any(re.search(r"#%d(?!\d)" % n, ln) for ln in inbox_lines)

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
        args = as_json(c["args_raw"]) if c["args_raw"] else None
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

    # Передумова 4a: email рев'юера — РІВНО email з рядка Andrii у company-context, не
    # підрядок файлу (чекер р.1: «o@strw.exam» проходив як входження «ceo@strw.example»).
    if reviewer is not None and any(c["tool"] in FOR_REVIEW for c in calls):
        cc = company_context_path()
        try:
            cc_text = io.open(cc, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            cc_text = None
        if cc_text is None:
            errs.append("company-context не прочитано (%s) — email рев'юера не звірено (передумова 4a; STRW_COMPANY_CONTEXT)"
                        % cc)
        else:
            andrii = {e for ln in cc_text.splitlines() if re.search(r"andrii|андрій", ln, re.I)
                      for e in EMAIL.findall(ln)}
            if reviewer not in andrii:
                errs.append("reviewer %s — не email Andrii з company-context (%s; там: %s) — передумова 4a не виконана"
                            % (reviewer, cc, ", ".join(sorted(andrii)) or "email Andrii немає"))

    # Послідовність (паспорт 4b–4c): після КОЖНОГО запису одразу getScheduledPosts, і пост
    # запису в ньому є; після updateScheduledPost наступний запис — sendScheduledPostForReview;
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
        resp = " ".join(c["resp"])
        if c["tool"] in FOR_REVIEW and ERROR_RESP.search(resp):
            if any(x["tool"] == c["tool"] for x in calls[k + 1:]):
                errs.append("%s: відповів помилкою, а виклик повторено (паспорт 4c — без повтору)" % tag)
            if not card_for(c["n"]):
                errs.append("%s: відповів помилкою, а рядка `- inbox: … #%d …` про цей виклик немає (паспорт 4c)"
                            % (tag, c["n"]))
            continue
        if nxt is None:
            continue
        # Пост запису мусить бути в наступному getScheduledPosts (паспорт 4c: «пост відсутній» —
        # теж зупинка). Ключ — uuid (не змінюється між викликами), інакше id.
        rj = as_json(resp)
        key = None
        if isinstance(rj, dict):
            if isinstance(rj.get("uuid"), str) and rj["uuid"]:
                key = '"%s"' % rj["uuid"]
            elif isinstance(rj.get("id"), int):
                key = rj["id"]
        nresp = " ".join(nxt["resp"])
        if key is None:
            errs.append("%s: у відповіді немає uuid/id поста — getScheduledPosts не звірити (паспорт 4b)" % tag)
            continue
        present = (key in nresp) if isinstance(key, str) else bool(re.search(r'"id"\s*:\s*%d(?!\d)' % key, nresp))
        if not present and not card_for(c["n"]):
            errs.append("%s: поста немає у відповіді getScheduledPosts, а рядка `- inbox: … #%d …` немає (паспорт 4c)"
                        % (tag, c["n"]))
        if c["tool"] == "updateScheduledPost":
            continue   # правка скидає review — стан «на затвердження» дає наступний send
        state = nxt["state"]
        planner = rj.get("plannerUrl") if isinstance(rj, dict) else None
        if state is None:
            errs.append("%s: під getScheduledPosts немає рядка `  стан: …` (паспорт 4b)" % tag)
        elif re.fullmatch(r"(?i)pending review\.?", state):
            pass
        elif state.startswith("поле стану не встановлено"):
            if not (isinstance(planner, str) and re.match(r"https?://\S", planner)):
                errs.append("%s: «поле стану не встановлено», а у відповіді ForReview немає plannerUrl-посилання —"
                            " доказу «на затвердження» немає (паспорт 4b)" % tag)
        elif not card_for(c["n"]):
            errs.append("%s: стан «%s» — не pending review, а рядка `- inbox: … #%d …` немає (паспорт 4c)"
                        % (tag, state, c["n"]))

    # Соцметрики (паспорт п. 5): «н/д: …» — без жодної цифри в тому ж реченні; число по
    # соцмережах — лише те, що ДОСЛІВНО є у відповіді getAnalyticsDataByMetrics, при
    # підключеному MCP (чекер р.1, Blocker 2: наявності виклику замало — TikTok 48 000
    # проходив, бо аналітику питали лише про Instagram).
    src_nums = set()
    for c in calls:
        if c["tool"] == "getAnalyticsDataByMetrics":
            for tok in re.findall(r"-?\d+(?:\.\d+)?", " ".join(c["resp"])):
                src_nums.add(float(tok))
    for i, ln in enumerate(report):
        if CALL_LINE.match(ln):
            continue
        rest = []
        for s in sentences(ln):
            if "н/д" in s.lower():
                if numbers_in(s):
                    errs.append("«н/д» з числом у тому ж реченні — пропуск цифр не має (паспорт п. 5): %s" % s.strip())
            else:
                rest.append(s)
        body = " ".join(rest)
        if not SOCIAL.search(body):
            continue
        toks = list(NUM.finditer(strip_not_numbers(body, period=True)))
        flagged = [t for t in toks if t.group(2) or re.search(r"[+−%]", body)] if not METRIC.search(body) else toks
        for t in flagged:
            if t.group(2):
                errs.append("звіт рядок %d: число «%s» зі скороченням по соцмережах — пиши так, як у відповіді"
                            " getAnalyticsDataByMetrics, інакше його не звірити (паспорт п. 5)" % (i + 1, t.group(0).strip()))
            elif not connected:
                errs.append("звіт рядок %d: число по соцмережах «%s», а `- mcp:` не каже connected (паспорт п. 5)"
                            % (i + 1, t.group(1)))
            elif to_float(t.group(1)) not in src_nums:
                errs.append("звіт рядок %d: число по соцмережах «%s» відсутнє у відповіді getAnalyticsDataByMetrics"
                            " у trace (паспорт п. 5)" % (i + 1, t.group(1)))

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
