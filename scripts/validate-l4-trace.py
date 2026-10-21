#!/usr/bin/env python3
# validate-l4-trace.py — рівень 0 для trace L4 (тип `l4-trace` у validate-artifact.sh).
# Usage: validate-l4-trace.py <growth-report.md>   → 0 PASS · 1 FAIL · 2 помилка виклику
#
# ЧОМУ МЕХАНІЗМ, А НЕ ПРОЗА. Шість раундів чекера 6a на #29/#23 (19.10) стерегли
# безпеку черги Metricool пінами на ключові слова в паспорті L4 — і кожен раунд
# знаходив новий синонім того самого класу. Тут стережеться не текст паспорта, а те,
# що maker ЗРОБИВ: виклики в trace (паспорт L4 п. 4a–4c, 5; контракт —
# references/artifact-contracts.md §growth-report).
#
# ЧИСЛА — ТЕГОМ, НЕ ВГАДУВАННЯМ. Три раунди чекера на #33 показали, що регулярка
# «чи є у вільному реченні число по соцмережах» (словник метрик → словник мереж →
# білий список «не метрик») — той самий пін на прозу, лише в коді. Рішення CEO 21.10
# (варіант A): КОЖНЕ число growth-report несе тег джерела одразу після себе. Тег
# Metricool `[#N ПОЛЕ]` скрипт звіряє з викликом і відповіддю; `[metrics.md]`, `[PRD]`,
# `[план]`, `[не метрика]` — оголошення, які звіряє LLM-чекер (brand-reviewer, п. 5).
# Скрипт не вирішує, про що число, — лише що джерело оголошене і, для Metricool, правдиве.
#
# Межа: trace пише сам maker. Скрипт ловить записане (і запис у неканонічній формі —
# згадку інструмента запису будь-де поза `- call:` trace), але не виклик, якого у
# файлі немає, не число словами і не хибно оголошене джерело. Стану Metricool не читає.
#
# Лише stdlib: python3 є і на Mac (3.9), і в хмарі.
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
# і «CreateScheduledPost» — той самий інструмент (р.1, C3/C4). Межа слова вручну:
# «createscheduledpost» — підрядок «createscheduledpostforreview».
WRITE_MENTION = re.compile(r"(?<![a-z])(createscheduledpostforreview|sendscheduledpostforreview"
                           r"|updatescheduledpost|createscheduledpost)(?![a-z])")
CALL_LINE = re.compile(r"^\s*-\s*call\s*:", re.I)
ERROR_TEXT = re.compile(r"error|does not allow|not allowed|forbidden|denied|unauthori|помилк", re.I)
# Тег джерела числа. Metricool: `[#N ПОЛЕ]`, ПОЛЕ — Data Studio field ID
# (network+connector+index, live-check 19.10 §4.3). Інші — оголошення без звірки.
SOURCE_TAG = re.compile(r"\[(?:#(\d+)\s+([A-Z]{4}\d{2})|(metrics\.md|PRD)(?::[^\]]*)?|(план|не метрика))\]")
# Конектори, чиї поля ВИМІРЯНО (live-check 19.10 §1.2: IGRE01–IGRE29 = Instagram Reels).
# Поле іншого конектора — FAIL «не виміряно», а не здогад про його зміст.
MEASURED_CONNECTORS = {"IGRE"}
# Цифри, що числом-твердженням не є: посилання, дати, час, ідентифікатори (pact-001,
# tri-138, L4, G1, W43, l4-trace), номери PR, нумерація списку, пункти паспорта.
# «x48000» — не id: одна літера + понад дві цифри — число (р.2, N11).
NOT_A_NUMBER = [
    re.compile(r"https?://\S+"),
    re.compile(r"\d{4}-\d{2}-\d{2}(?:T[\d:+-]+)?"),
    re.compile(r"(?<!\d)\d{1,2}:\d{2}(?!\d)"),
    re.compile(r"(?:[A-Za-z]{2,}|[A-Za-z]+[-_])\d+[A-Za-z0-9_-]*"),
    re.compile(r"(?<!\w)[A-Za-z]\d{1,2}(?!\d)"),
    re.compile(r"#\d+"),
    re.compile(r"^\s*-?\s*\d+[.)]\s"),
    re.compile(r"(?:п\.|§)\s*\d+[a-h]?(?!\w)"),
    re.compile(r"(?<![\d.,])\d+[a-h](?!\w)"),
]
NUM = re.compile(r"(?<![\d.,])(\d{1,3}(?:[   ]\d{3})+(?:[.,]\d+)?|\d+(?:[.,]\d+)?)(?![\d])"
                 r"(\s*(?:k|к|тис|млн|m|м)(?![a-zа-яіїєґ]))?(\s*%)?", re.I)
HEADING = re.compile(r"^(#{1,6})\s+(.*)$")
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
# Стан «на затвердження» — лише явні значення поля, не «що завгодно з review» (р.3, S5).
PENDING_VALUE = re.compile(r"(?i)^(?:pending(?:[_ ](?:review|approval))?|in[_ ]review|waiting[_ ]for[_ ]approval)$")


def strip_not_numbers(text):
    for rx in NOT_A_NUMBER:
        text = rx.sub(" ", text)
    return text


def numbers_in(text):
    return re.findall(r"\d", strip_not_numbers(text))


def sentences(line):
    return [s for s in re.split(r"(?<=[.!?;])\s+", line) if s.strip()]


def split_trace(lines):
    """→ (trace, report, found). Trace — рівно заголовок «Trace (L4)» (будь-якого рівня,
    без іншого тексту: р.3, P02 — «## Метрики (з Trace (L4))» ставав trace) до НАСТУПНОГО
    заголовка будь-якого рівня: підсекція під trace — уже звіт (р.1, B5)."""
    trace, report, inside, found = [], [], False, False
    for ln in lines:
        m = HEADING.match(ln)
        if m:
            inside = m.group(2).strip() == "Trace (L4)"
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
    if isinstance(text, (dict, list)):
        return text
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        return None


def walk(node):
    """Обхід JSON, включно з `info`, записаним рядком із JSON (live-check §4)."""
    if isinstance(node, str) and node.lstrip()[:1] in "{[":
        inner = as_json(node)
        if inner is not None:
            node = inner
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from walk(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk(v)


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def field_values(resp, field):
    """Значення поля — СКАЛЯР під ключем == field або `value`/`total`/`sum` в об'єкті з
    fieldId == field. Ряд (денні значення) підсумком не є — його не звіряємо (р.3, S6)."""
    out = set()
    for d in walk(resp):
        if field in d and is_num(d[field]):
            out.add(float(d[field]))
        if field in [v for v in d.values() if isinstance(v, str)]:
            for k in ("value", "total", "sum"):
                if is_num(d.get(k)):
                    out.add(float(d[k]))
    return out


def shown_values(tok):
    """Число з тексту → можливі значення: «1 240» → 1240; «4,5» → 4.5; «1,240» — і
    1240 (англійський роздільник тисяч), і 1.24 (р.3, F17). Плюс кількість знаків."""
    t = re.sub(r"[   ]", "", tok)
    cands = set()
    if re.fullmatch(r"\d{1,3}(?:,\d{3})+", t):
        cands.add((float(t.replace(",", "")), 0))
    dec = t.replace(",", ".")
    places = len(dec.split(".")[1]) if "." in dec else 0
    cands.add((float(dec), places))
    return cands


def matches(tok, pct, vals):
    """Показане число дорівнює значенню з точністю до показаних знаків (р.3, F16: AVG-поля
    неокруглені); «%» — і саме значення, і частка ×100."""
    for v, places in shown_values(tok):
        for x in vals:
            for y in ((x, x * 100) if pct else (x,)):
                if round(y, places) == round(v, places):
                    return True
    return False


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


def is_error(resp_text):
    """Помилка — за ВЕРХНІМ рівнем відповіді, не за ехом тексту поста (р.3, F19)."""
    rj = as_json(resp_text)
    if isinstance(rj, dict):
        if rj.get("error") or rj.get("errors"):
            return True
        if re.match(r"4\d\d$", str(rj.get("status") or rj.get("statusCode") or "")):
            return True
        return bool(ERROR_TEXT.search(str(rj.get("message") or "")))
    return bool(ERROR_TEXT.search(resp_text))


def check(lines):
    trace, report, found = split_trace(lines)
    if not found:
        return ["немає секції «Trace (L4)» — артефакт без trace не приймається (loop-passport §3)"], 0, 0
    errs = []
    calls, other = parse_calls(trace)
    text = [ln for _, ln in other]

    # Виклик поза trace (додаток, підсекція) скрипт не розібрав би — тому FAIL (р.1, Blocker 1).
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
        # Картка — про ЦЕЙ виклик: рядок `- inbox:` називає його номер (`#n`) (р.1, Nit G).
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
        if isinstance(info, str):
            # live-check 19.10 §4: у схемах `info` — рядок із JSON; дослівний виклик не червоний.
            info = as_json(info)
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

    # Передумова 4a: email рев'юера — РІВНО email рядка `- Andrii:` розділу «Рев'юер черги
    # Metricool» у company-context (р.1 E — не підрядок; р.2 E2 — не інший розділ; р.3 Q2 —
    # не інший рядок того ж розділу).
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
            andrii, sect = set(), False
            for ln in cc_text.splitlines():
                hm = HEADING.match(ln)
                if hm:
                    sect = bool(re.search(r"Рев.юер черги Metricool", hm.group(2)))
                    continue
                if sect and re.match(r"^\s*-\s*(?:Andrii|Андрій)\s*:", ln):
                    andrii |= set(EMAIL.findall(ln))
            if reviewer not in andrii:
                errs.append("reviewer %s — не email Andrii з company-context (%s; там: %s) — передумова 4a не виконана"
                            % (reviewer, cc, ", ".join(sorted(andrii)) or
                               "у розділі «Рев'юер черги Metricool» рядка `- Andrii: <email>` немає"))

    # Послідовність (паспорт 4b–4c): після КОЖНОГО запису одразу getScheduledPosts, і пост
    # запису в ньому рівно один; після updateScheduledPost наступний запис — send; помилка
    # ForReview — без повтору й з карткою; стан — pending review або доказ plannerUrl.
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
        if c["tool"] in FOR_REVIEW and is_error(resp):
            if any(x["tool"] == c["tool"] for x in calls[k + 1:]):
                errs.append("%s: відповів помилкою, а виклик повторено (паспорт 4c — без повтору)" % tag)
            if not card_for(c["n"]):
                errs.append("%s: відповів помилкою, а рядка `- inbox: … #%d …` про цей виклик немає (паспорт 4c)"
                            % (tag, c["n"]))
            continue
        if nxt is None:
            continue
        # Ключ — uuid (не змінюється між викликами), інакше id (рядок чи число — р.3, F20).
        rj = as_json(resp)
        key = None
        if isinstance(rj, dict):
            if isinstance(rj.get("uuid"), str) and rj["uuid"]:
                key = ("uuid", rj["uuid"])
            elif isinstance(rj.get("id"), (int, str)) and not isinstance(rj.get("id"), bool) and str(rj["id"]):
                key = ("id", str(rj["id"]))
        if key is None:
            errs.append("%s: у відповіді немає uuid/id поста — getScheduledPosts не звірити (паспорт 4b)" % tag)
            continue
        posts = [d for d in walk(as_json(" ".join(nxt["resp"])))
                 if key[1] == (str(d.get(key[0])) if d.get(key[0]) is not None else None)]
        if not posts:
            if not card_for(c["n"]):
                errs.append("%s: поста немає у відповіді getScheduledPosts, а рядка `- inbox: … #%d …` немає (паспорт 4c)"
                            % (tag, c["n"]))
            continue
        if len(posts) > 1:
            errs.append("%s: у getScheduledPosts %d постів із %s=%s — який перевіряти, не визначено (р.3, S4)"
                        % (tag, len(posts), key[0], key[1]))
            continue
        # У пості — рекурсивно, включно з `info` рядком: autoPublish і поле стану (р.3, S3).
        auto_true, status = False, []
        for d in walk(posts[0]):
            if d.get("autoPublish") is True:
                auto_true = True
            for k2, v2 in d.items():
                if re.search(r"status|state", k2, re.I) and isinstance(v2, str):
                    status.append(v2)
        if auto_true:
            errs.append("%s: у getScheduledPosts пост з autoPublish: true — Metricool опублікує сам (паспорт 4b)" % tag)
        if c["tool"] == "updateScheduledPost":
            continue   # правка скидає review — стан «на затвердження» дає наступний send
        state = nxt["state"]
        planner = rj.get("plannerUrl") if isinstance(rj, dict) else None
        if state is None:
            errs.append("%s: під getScheduledPosts немає рядка `  стан: …` (паспорт 4b)" % tag)
        elif re.fullmatch(r"(?i)pending review\.?", state):
            if status and not all(PENDING_VALUE.match(v) for v in status):
                errs.append("%s: «стан: pending review», а у відповіді стан %s (паспорт 4b–4c)" % (tag, ", ".join(status)))
        elif state.startswith("поле стану не встановлено"):
            if status:
                errs.append("%s: «поле стану не встановлено», а у відповіді поле є: %s (паспорт 4b)" % (tag, ", ".join(status)))
            if not (isinstance(planner, str) and re.match(r"https?://\S", planner)):
                errs.append("%s: «поле стану не встановлено», а у відповіді ForReview немає plannerUrl-посилання —"
                            " доказу «на затвердження» немає (паспорт 4b)" % tag)
        elif not card_for(c["n"]):
            errs.append("%s: стан «%s» — не pending review, а рядка `- inbox: … #%d …` немає (паспорт 4c)"
                        % (tag, state, c["n"]))

    # Числа (паспорт п. 3, 5): кожне число звіту І вільного тексту trace несе тег джерела
    # одразу після себе — один тег на одне число; «н/д» — без жодної цифри в реченні.
    def verify_metricool(t, n, field, ln_no):
        shown = t.group(0).strip()
        if t.group(2):
            return "%s: «%s» зі скороченням біля тегу Metricool — пиши як у відповіді" % (ln_no, shown)
        if not connected:
            return "%s: тег [#%d %s], а `- mcp:` не каже connected (паспорт п. 5)" % (ln_no, n, field)
        c = calls[n - 1] if 1 <= n <= len(calls) else None
        if c is None or c["tool"] != "getAnalyticsDataByMetrics":
            return "%s: тег [#%d %s] — виклик #%d не getAnalyticsDataByMetrics (паспорт п. 5)" % (ln_no, n, field, n)
        args = as_json(c["args_raw"]) if c["args_raw"] else None
        if not (isinstance(args, dict) and isinstance(args.get("metrics"), list) and field in args["metrics"]):
            return "%s: поля %s немає в `metrics` виклику #%d" % (ln_no, field, n)
        if field[:4] not in MEASURED_CONNECTORS:
            return ("%s: поле %s — конектор %s не виміряно (виміряно: %s) — зміст поля не встановлено"
                    % (ln_no, field, field[:4], ", ".join(sorted(MEASURED_CONNECTORS))))
        vals = field_values(as_json(" ".join(c["resp"])), field)
        if not vals:
            return "%s: у відповіді виклику #%d немає скалярного значення поля %s" % (ln_no, n, field)
        if not matches(t.group(1), bool(t.group(3)), vals):
            return "%s: «%s» ≠ значенню %s у відповіді #%d (%s)" % (
                ln_no, shown, field, n, ", ".join("%g" % x for x in sorted(vals)))
        return None

    def number_errors(where, ln_no, line):
        # Тег у бектиках — назва тегу в тексті, не тег; цифри в бектиках при цьому лишаються.
        line = re.sub(r"`[^`]*`", lambda m: SOURCE_TAG.sub(" ", m.group(0)), line)
        out, body = [], []
        for snt in sentences(line):
            if "н/д" in snt.lower():
                if numbers_in(SOURCE_TAG.sub(" ", snt)):
                    out.append("«н/д» з числом у тому ж реченні — пропуск цифр не має (паспорт п. 5): %s" % snt.strip())
            else:
                body.append(snt)
        body = " ".join(body)
        loc = "%s рядок %d" % (where, ln_no)
        last = 0
        for tm in SOURCE_TAG.finditer(body):
            nums = list(NUM.finditer(strip_not_numbers(body[last:tm.start()])))
            if not nums:
                out.append("%s: тег %s без числа перед ним" % (loc, tm.group(0)))
            else:
                for t in nums[:-1]:
                    out.append("%s: число «%s» без тегу джерела (один тег — одне число)" % (loc, t.group(0).strip()))
                if tm.group(1):
                    e = verify_metricool(nums[-1], int(tm.group(1)), tm.group(2), loc)
                    if e:
                        out.append(e)
            last = tm.end()
        for t in NUM.finditer(strip_not_numbers(body[last:])):
            out.append("%s: число «%s» без тегу джерела ([#N ПОЛЕ] · [metrics.md] · [PRD] · [план] · [не метрика])"
                       % (loc, t.group(0).strip()))
        return out

    for i, ln in enumerate(report):
        if not CALL_LINE.match(ln):
            errs += number_errors("звіт", i + 1, ln)
    for i, ln in other:
        if not re.match(r"^- (?:mcp|reviewer):", ln):   # вивід команди й email — дослівні
            errs += number_errors("trace", i + 1, ln)

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
