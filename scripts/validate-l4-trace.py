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
from decimal import Decimal, ROUND_HALF_UP
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
# Аргументи — лише ключі схеми інструмента (live-check 19.10 §4). Невідомий ключ — FAIL:
# інакше аргументи ставали б місцем для чисел без тегу (р.4, A14 `{"note": "TikTok 48000"}`).
ARG_KEYS = {
    "getBrandSettings": set(),
    "getAnalyticsAvailableMetrics": {"network", "connector"},
    "getAnalyticsDataByMetrics": {"brandId", "from", "to", "metrics"},
    "getScheduledPosts": {"brandId", "fromDate", "toDate", "timezone", "extendedRange"},
    "getBestTimeToPostByNetwork": {"brandId", "fromDate", "toDate", "timezone", "socialNetwork"},
    "createScheduledPost": {"blogId", "date", "info", "mediaFiles"},
    "updateScheduledPost": {"id", "uuid", "blogId", "info", "mediaFiles"},
    "createScheduledPostForReview": {"date", "blogId", "info", "reviewers", "approvalSystem", "notify"},
    "sendScheduledPostForReview": {"id", "uuid", "blogId", "info", "reviewers", "approvalSystem", "notify"},
}
# Згадка шукається в рядку, зведеному до малих літер без `_`: «create_scheduled_post»
# і «CreateScheduledPost» — той самий інструмент (р.1, C3/C4). Межа слова вручну:
# «createscheduledpost» — підрядок «createscheduledpostforreview».
# Роздільник між частинами назви — `_`, `-` чи пробіл (р.5 B18 «create-scheduled-post»); між
# назвою і наступним словом — ні (р.6 S04: «createScheduledPost done» не злипається в одне слово).
_S = r"[\s_-]*"
WRITE_MENTION = re.compile(r"(?<![a-z])((?:create|send)" + _S + "scheduled" + _S + "post" + _S + "for" + _S + "review"
                           r"|update" + _S + "scheduled" + _S + "post|create" + _S + "scheduled" + _S + "post)(?![a-z])")
CALL_LINE = re.compile(r"^\s*-\s*call\s*:", re.I)
ERROR_TEXT = re.compile(r"error|does not allow|not allowed|forbidden|denied|unauthori|помилк", re.I)
MCP_LINE = re.compile(r"^- mcp: `claude mcp get metricool` → «[^»]*»\s*$")
# Тег джерела числа. Metricool: `[#N ПОЛЕ]`, ПОЛЕ — Data Studio field ID
# (network+connector+index, live-check 19.10 §4.3). Інші — оголошення без звірки.
SOURCE_TAG = re.compile(r"\[(?:#(\d+)\s+([A-Z]{4}\d{2})|(metrics\.md|PRD)(?::[^\]]*)?|(план|не метрика))\]")
# Конектори, чиї поля ВИМІРЯНО (live-check 19.10 §1.2: IGRE01–IGRE29 = Instagram Reels).
# Поле іншого конектора — FAIL «не виміряно», а не здогад про його зміст.
MEASURED_CONNECTORS = {"IGRE"}
# Цифри, що числом-твердженням не є, — ЗАКРИТИЙ перелік точних форм контракту (р.4–р.5,
# Blocker: кожен «широкий» виняток — `[A-Za-z]+-\d+`, `слово #N`, `HH:MM`, «N. » — вирізав
# вигадане число сусідньою формою: «TikTok-48000», «ER-45», «Top-3», «for-you #3», «0:45»,
# «48. Стільки…»). Усе поза переліком — число, і новий синонім дає хибний червоний, не обхід.
REPOS = r"(?:strw-factory|strw-ops|strw-state|pact-ios|pact-backend)"
NOT_A_NUMBER = [
    re.compile(r"https?://\S+"),
    # шлях до файла з «/» і розширенням: loops/L4-growth.md (р.6, F02)
    re.compile(r"(?<![\w.-])[\w-]+(?:/[\w.-]+)+\.(?:md|sh|py|yaml|json)\b"),
    # дата ISO з реальним місяцем/днем, з часом через «T» або пробіл (р.6, N07: «4800-00-00»)
    re.compile(r"(?<![\w.,])20\d{2}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])"
               r"(?:[T ](?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?(?:[+-]\d{2}:\d{2}|Z)?)?(?!\d|[.,]\d)"),
    re.compile(r"\bv\d+\.\d+\.\d+\b"),
    # id — лише відомі префікси реєстру (р.6, N04/N06: «top-100», «views-480»)
    re.compile(r"(?<![\w.,-])(?:pact|tea|aqua|tri|dec)-\d{3}(?![\w%-]|[.,]\d)"),
    # L1–L8, G1–G4, M1–M9, W1–W53 (р.6, N17: «M48»)
    re.compile(r"(?<![\w.,-])(?:L[1-8]|G[1-4]|M[1-9]|W(?:[1-9]|[1-4]\d|5[0-3]))(?![\w%-]|[.,]\d)"),
    re.compile(r"\bl4-trace\b"),
    # номер PR — лише з назвою репо (р.6, N08: «PR #1 тижня»)
    re.compile(r"(?:\b" + REPOS + r"\s*|\bandresiletsky-bit/[\w.-]+)#\d+\b"),
    # пункт паспорта: 1–2 цифри (р.6, N19/N20: «§48000», «п. 48»… — п. ≤ 19 у паспортах)
    re.compile(r"(?<!\w)п\.\s*(?:1?\d)[a-h]?(?:\s*[–-]\s*(?:1?\d)[a-h]?)?(?!\w|[.,]\d|%)"),
    re.compile(r"§\s*(?:1?\d)(?!\w|[.,]\d|%)"),
]
# Час — лише «о/об HH:MM» з реальною годиною (р.6, Blocker: «до 00:45», «з 00:30», «на 00:12» —
# тривалість, тобто число). «До 18:00» — з тегом `[не метрика]`: хибний червоний на безпечному боці.
TIME_AFTER_PREP = re.compile(r"(?i)(\b(?:о|об)\s+)(?:[01]?\d|2[0-3]):[0-5]\d(?!\d|[.,]\d)")
# Посилання на виклик — лише в рядку `- inbox:` і `стан:`, і лише на існуючий номер (р.6, N05).
CALL_REF = re.compile(r"\bвиклик\w*\s+#(\d+)\b")
# Токен числа: складений «9:16», «1080×1920» (один тег на токен), групи тисяч, десяткові.
NUM = re.compile(r"(?<![\d.,])(\d+(?:[:×–]\d+)+|\d{1,3}(?:[   ]\d{3})+(?:[.,]\d+)?|\d+(?:[.,]\d+)?)(?![\d])"
                 r"(\s*(?:k|к|тис|млн|m|м)(?![a-zа-яіїєґ]))?(\s*%)?", re.I)
# Одиниця після тегу Metricool — FAIL до виміру одиниць (р.5: «45,2 [#1 IGRE08]%», «…відсотка»).
UNIT_AFTER_TAG = re.compile(r"^\s*(?:%|％|﹪|‰|відсот|процент|percent|per\s*cent|pct|тис|тисяч|млн|мільйон|млрд|мільярд"
                            r"|thousand|million|billion|k(?![a-zа-яіїєґ])|к(?![a-zа-яіїєґ])|m(?![a-zа-яіїєґ])|м(?![a-zа-яіїєґ])|bn\b)", re.I)
# Відповідь, що не JSON, — лише текст помилки сервера (live-check §1.2: «The result exceeds…»).
PLAIN_ERROR = re.compile(r"^\s*(?:error\b|the result exceeds|\w+ error\b)", re.I)   # р.6, N12b: «(limit)» не перепустка
PCT_ANY = re.compile(r"%|％|﹪|‰|відсот|процент|percent|pct", re.I)
SOCIAL_NETWORKS = {"twitter", "facebook", "instagram", "linkedin", "youtube", "tiktok"}          # §4.5
NETWORKS = {"bluesky", "googleBusinessProfile", "metaAds", "googleAds", "threads", "facebookAds", "facebook",
            "instagram", "linkedin", "pinterest", "tiktok", "tiktokAds", "twitter", "twitch", "youtube",
            "brandInfo", "website", "brandSummary", "smartLinks"}                                   # §4.2
ISO_DT = re.compile(r"^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?(?:[+-]\d{2}:\d{2}|Z)?)?$")
HEADING = re.compile(r"^(#{1,6})\s+(.*)$")
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
# Стан «на затвердження» — лише явні значення поля, не «що завгодно з review» (р.3, S5).
PENDING_VALUE = re.compile(r"(?i)^(?:pending(?:[_ ](?:review|approval))?|in[_ ]review|waiting[_ ]for[_ ]approval)$")


FIELD_TOKEN = re.compile(r"(?<![\w.,-])[A-Z]{4}\d{2}(?![\w%-]|[.,]\d)")


def strip_not_numbers(text, fields=frozenset()):
    for rx in NOT_A_NUMBER:
        text = rx.sub(" ", text)
    # Поле Data Studio — «не число» лише якщо його справді запитали в `metrics` (р.7, FLD «VIEW48»).
    text = FIELD_TOKEN.sub(lambda m: " " if m.group(0) in fields else m.group(0), text)
    return TIME_AFTER_PREP.sub(lambda m: m.group(1) + " ", text)


def numbers_in(text, fields=frozenset()):
    return re.findall(r"\d", strip_not_numbers(text, fields))


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
    """→ (значення, ряд?). Значення поля — СКАЛЯР під ключем == field або `value`/`total`/`sum`
    в об'єкті з fieldId == field. Ряд — поле трапляється більше одного разу, або поруч із
    `date`/`day`, або значення — список (р.3 S6, р.4 M29, р.5 B13): підсумком він не є."""
    out, hits, series = set(), 0, False
    for d in walk(resp):
        dated = any(k in d for k in ("date", "day", "timestamp"))
        if field in d:
            hits += 1
            series = series or dated or isinstance(d[field], list)
            if is_num(d[field]):
                out.add(float(d[field]))
        if field in [v for v in d.values() if isinstance(v, str)]:
            hits += 1
            series = series or dated
            for k in ("value", "total", "sum"):
                if is_num(d.get(k)):
                    out.add(float(d[k]))
    return out, series or hits > 1


def shown_values(tok):
    """Число з тексту → можливі значення: «1 240» → 1240; «4,5» → 4.5; «1,240» — і
    1240 (англійський роздільник тисяч), і 1.24 (р.3, F17). Плюс кількість знаків."""
    t = re.sub(r"[   ]", "", tok)
    cands = set()
    if re.fullmatch(r"\d{1,3}(?:,\d{3})+", t):
        return {(float(t.replace(",", "")), 0)}   # «48,000» — лише роздільник тисяч (р.6, N16)
    dec = t.replace(",", ".")
    places = len(dec.split(".")[1]) if "." in dec else 0
    cands.add((float(dec), places))
    return cands


def matches(tok, vals):
    """Показане число дорівнює значенню з точністю до показаних знаків, округлення —
    звичайне (half-up; р.3 F16, р.4 L07/L08: AVG-поля неокруглені)."""
    for v, places in shown_values(tok):
        q = Decimal(1).scaleb(-places)
        for x in vals:
            if Decimal(repr(x)).quantize(q, rounding=ROUND_HALF_UP) == Decimal(repr(v)).quantize(q, rounding=ROUND_HALF_UP):
                return True
    return False


def arg_value_errors(tool, args):
    """Значення аргументів — за типом і переліком схеми (live-check §4.2–§4.9): інакше вільний
    текст із числами ховався б у значенні (р.5, B10 `{"socialNetwork": "TikTok — 48 000…"}`)."""
    out = []
    for k, v in args.items():
        ok = True
        if k in ("from", "to", "fromDate", "toDate", "date"):
            ok = isinstance(v, str) and bool(ISO_DT.match(v))
        elif k in ("brandId", "blogId", "id"):
            ok = (isinstance(v, int) and not isinstance(v, bool)) or (isinstance(v, str) and v.isdigit())
        elif k == "uuid":
            ok = isinstance(v, str) and bool(re.fullmatch(r"[\w-]+", v))
        elif k == "timezone":
            ok = isinstance(v, str) and bool(re.fullmatch(r"[A-Za-z_]+(?:/[A-Za-z_]+)+|UTC", v))
        elif k == "socialNetwork":
            ok = v in SOCIAL_NETWORKS
        elif k == "network":
            ok = v in NETWORKS
        elif k == "connector":
            ok = isinstance(v, str) and bool(re.fullmatch(r"[a-z &]+", v))
        elif k == "metrics":
            ok = isinstance(v, list) and all(isinstance(x, str) and re.fullmatch(r"[A-Z]{4}\d{2}", x) for x in v)
        elif k in ("notify", "extendedRange"):
            ok = isinstance(v, bool)
        elif k == "approvalSystem":
            ok = isinstance(v, str)
        elif k == "reviewers":
            ok = isinstance(v, str)
        elif k == "info":
            ok = isinstance(v, (str, dict))
        elif k == "mediaFiles":
            ok = isinstance(v, list)
        if not ok:
            out.append("%s=%s" % (k, json.dumps(v, ensure_ascii=False)[:60]))
    return out


def company_context_path():
    p = os.environ.get("STRW_COMPANY_CONTEXT")
    if p:
        return p
    root = os.environ.get("STRW_ROOT") or os.path.join(os.path.expanduser("~"), "Developer", "STRW")
    return os.path.join(root, "strw-state", "company-context.md")


def write_mentions(where, lines):
    out = []
    for i, ln in lines:
        m = WRITE_MENTION.search(ln.lower())
        if m:
            name = re.sub(r"[\s_-]", "", m.group(1))
            out.append("%s рядок %d: згадка інструмента запису `%s` поза рядком `- call:` trace — виклик запису"
                       " фіксується лише як `- call: <інструмент> {…}` у «Trace (L4)»" % (where, i + 1, name))
    return out


def is_error(resp_text):
    """Помилка — за ВЕРХНІМ рівнем відповіді, не за ехом тексту поста (р.3, F19)."""
    rj = as_json(resp_text)
    if isinstance(rj, dict):
        # Лише ключі помилки і 4xx: «Sent for review without errors» у `message` — не помилка
        # (р.4, Blocker 2: такий текст вимикав перевірку поста з autoPublish: true).
        if rj.get("error") or rj.get("errors"):
            return True
        return bool(re.match(r"4\d\d$", str(rj.get("status") or rj.get("statusCode") or "")))
    return bool(ERROR_TEXT.search(resp_text))


def check(lines):
    trace, report, found = split_trace(lines)
    if not found:
        return ["немає секції «Trace (L4)» — артефакт без trace не приймається (loop-passport §3)"], 0, 0
    errs = []
    calls, other = parse_calls(trace)
    text = [ln for _, ln in other]
    fields = frozenset(f for c in calls if c["tool"] == "getAnalyticsDataByMetrics"
                       for f in ((as_json(c["args_raw"]) or {}).get("metrics") or [] if c["args_raw"] else [])
                       if isinstance(f, str))

    # Виклик поза trace (додаток, підсекція) скрипт не розібрав би — тому FAIL (р.1, Blocker 1).
    for i, ln in enumerate(report):
        if CALL_LINE.match(ln):
            errs.append("звіт рядок %d: `- call:` поза «Trace (L4)» — виклики Metricool живуть лише в trace" % (i + 1))
    errs += write_mentions("звіт", [(i, ln) for i, ln in enumerate(report) if not CALL_LINE.match(ln)])
    # Усі рядки trace, крім самого `- call:`: і відповіді `  > …`, і `  стан: …` (р.6, S04/S05).
    # Рядок, схожий на виклик, але не канонічний `- call:` (регістр, пробіли, відступ), parse_calls
    # не розбирає — і він не мусить ставати невидимим (р.7, Blocker: `- Call: createScheduledPost…`).
    parsed = {c["idx"] for c in calls}
    for i, ln in enumerate(trace):
        if i not in parsed and re.search(r"(?i)^\s*-\s*call\s*:", ln):
            errs.append("trace рядок %d: неканонічний рядок виклику — лише «- call: <інструмент> {…}»: %s" % (i + 1, ln.strip()[:60]))
    # Усі рядки trace, крім розібраних викликів: і `  > …`, і `  стан: …` (р.6, S04/S05).
    errs += write_mentions("trace", [(i, ln) for i, ln in enumerate(trace) if i not in parsed])

    mcp_lines = [ln for ln in text if re.match(r"^- mcp:", ln)]
    mcp = " ".join(mcp_lines)
    if not mcp:
        errs.append("немає рядка `- mcp:` — вивід `claude mcp get metricool` дослівно (паспорт L4 п. 5)")
    for ln in mcp_lines:
        # Рядок mcp — лише команда і вивід у «…», нічого після (р.4, A01: число після виводу).
        if not MCP_LINE.match(ln):
            errs.append("рядок `- mcp:` — лише «- mcp: `claude mcp get metricool` → «<вивід>»», без іншого тексту")
        elif re.search(r"\d", re.sub(r"https?://\S+", " ", re.search(r"«([^»]*)»", ln).group(1))):
            # Вивід команди — статус і URL; цифра поза URL — не вивід (р.5, B08).
            errs.append("у виводі `- mcp:` цифра поза URL — вивід команди чисел не має, звір дослівність")
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
        return any(re.search(r"\bвиклик\w*\s+#%d(?!\d)" % n, ln) for ln in inbox_lines)

    for c in calls:
        tag = "виклик #%d %s" % (c["n"], c["tool"])
        if c["tool"] not in TOOLS:
            errs.append("%s: такого інструмента немає серед дев'яти сервера Metricool (паспорт L4 п. 4)" % tag)
            continue
        if not c["resp"]:
            errs.append("%s: немає цитати відповіді (`  > …`)" % tag)
        elif as_json(" ".join(c["resp"])) is None and not PLAIN_ERROR.search(" ".join(c["resp"])):
            # Відповідь — JSON або текст помилки сервера; вільний текст тут не перевірявся б (р.5, B09).
            errs.append("%s: відповідь не JSON і не текст помилки — дослівність не звірити" % tag)
        args = as_json(c["args_raw"]) if c["args_raw"] else {}
        if not isinstance(args, dict):
            errs.append("%s: аргументи не JSON-об'єкт в одному рядку — передумову не перевірити" % tag)
            continue
        extra = sorted(set(args) - ARG_KEYS[c["tool"]])
        if extra:
            errs.append("%s: аргументи поза схемою інструмента: %s (live-check §4)" % (tag, ", ".join(extra)))
        bad_vals = arg_value_errors(c["tool"], args)
        if bad_vals:
            errs.append("%s: значення аргументів поза типом/переліком схеми: %s (live-check §4)" % (tag, "; ".join(bad_vals)))
        if c["tool"] == "createScheduledPost":
            errs.append("%s: прямий розклад без людини, у L4 заборонений завжди (паспорт 4b)" % tag)
            continue
        if c["tool"] not in WRITES:
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
            else:
                # Надіслати треба ТОЙ САМИЙ пост: uuid не змінюється між викликами (р.6, S02).
                ua = (as_json(c["args_raw"]) or {}).get("uuid") if c["args_raw"] else None
                sa = (as_json(later[0]["args_raw"]) or {}).get("uuid") if later[0]["args_raw"] else None
                if not ua or ua != sa:
                    errs.append("%s: send після правки — інший пост (uuid %s ≠ %s); правку не перенадіслано (паспорт 4b)"
                                % (tag, sa, ua))
                # id після правки змінюється (live-check §4.7): send — з НОВИМ id з відповіді update (р.7, S02id).
                ur = as_json(" ".join(c["resp"]))
                if isinstance(ur, dict) and isinstance(ur.get("data"), dict):
                    ur = ur["data"]
                sid = (as_json(later[0]["args_raw"]) or {}).get("id") if later[0]["args_raw"] else None
                if isinstance(ur, dict) and ur.get("id") is not None and str(sid) != str(ur.get("id")):
                    errs.append("%s: send після правки з id %s, а правка повернула id %s (паспорт 4b)" % (tag, sid, ur.get("id")))
        resp = " ".join(c["resp"])
        failed = c["tool"] in FOR_REVIEW and is_error(resp)
        if failed:
            # Після відмови ForReview у чергу не йде НІЧОГО — жоден запис, не лише той самий
            # інструмент (паспорт 4a/4c; р.4, A12: update+send після «plan does not allow»).
            if any(x["tool"] in WRITES for x in calls[k + 1:]):
                errs.append("%s: відповів помилкою, а після нього є запис (паспорт 4a/4c — без повтору, у чергу нічого)" % tag)
            if not card_for(c["n"]):
                errs.append("%s: відповів помилкою, а рядка `- inbox: … #%d …` про цей виклик немає (паспорт 4c)"
                            % (tag, c["n"]))
        if nxt is None:
            continue
        # Ключ — uuid (не змінюється між викликами), інакше id (рядок чи число — р.3, F20).
        rj = as_json(resp)
        if isinstance(rj, dict) and isinstance(rj.get("data"), dict):
            rj = rj["data"]                          # живі відповіді загорнуто в {"data": …} (live-check §1.3–§1.4)
        key = None
        if isinstance(rj, dict):
            if isinstance(rj.get("uuid"), str) and rj["uuid"]:
                key = ("uuid", rj["uuid"])
            elif isinstance(rj.get("id"), (int, str)) and not isinstance(rj.get("id"), bool) and str(rj["id"]):
                key = ("id", str(rj["id"]))
        if key is None:
            if not failed:
                errs.append("%s: у відповіді немає uuid/id поста — getScheduledPosts не звірити (паспорт 4b)" % tag)
                continue
            # Справжня помилка ForReview — текст без id (live-check §4.8): пост шукається за текстом
            # виклику; якщо він таки в черзі з autoPublish ≠ «ні» — публікація без людини (р.6, S01).
            info = (as_json(c["args_raw"]) or {}).get("info") if c["args_raw"] else None
            info = as_json(info) if isinstance(info, str) else info
            text_ = info.get("text") if isinstance(info, dict) else None
            nj = as_json(" ".join(nxt["resp"]))
            if isinstance(nj, dict) and isinstance(nj.get("data"), list):
                nj = nj["data"]
            # Будь-який пост у черзі з autoPublish ≠ «ні» після помилки — FAIL, незалежно від тексту
            # (р.7: пост без тексту, текст з іншим пробілом, інша обгортка).
            if any("autoPublish" in d and d["autoPublish"] not in (False, 0, "false", "0") for d in walk(nj)):
                errs.append("%s: після помилки в getScheduledPosts є пост з autoPublish ≠ «ні»%s — Metricool опублікує"
                            " сам (паспорт 4b–4c)" % (tag, " (той самий текст)" if text_ else ""))
            continue
        # Пост — ЕЛЕМЕНТ списку відповіді (зокрема в {"data": […]}), у якому є цей uuid/id; прапори
        # шукаються в усьому елементі, разом з обгорткою (р.5, B17 `{"post": {…}, "autoPublish": true}`).
        nj = as_json(" ".join(nxt["resp"]))
        if isinstance(nj, dict) and isinstance(nj.get("data"), list):
            nj = nj["data"]
        items = nj if isinstance(nj, list) else ([nj] if isinstance(nj, dict) else [])
        posts = [it for it in items
                 if any(key[1] == (str(d.get(key[0])) if d.get(key[0]) is not None else None) for d in walk(it))]
        if not posts:
            if not failed and not card_for(c["n"]):
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
            # Будь-яке значення, крім явного «ні», — публікація без людини (р.5, B16 `1`).
            if "autoPublish" in d and d["autoPublish"] not in (False, 0, "false", "0"):
                auto_true = True
            for k2, v2 in d.items():
                if re.search(r"status|state", k2, re.I):
                    # Поле стану будь-якого типу — «поле є» (р.5, B14/B15: 2, {"name": …}).
                    status.append(v2 if isinstance(v2, str) else json.dumps(v2, ensure_ascii=False))
        if auto_true:
            errs.append("%s: у getScheduledPosts пост з autoPublish: true — Metricool опублікує сам (паспорт 4b)" % tag)
        if c["tool"] == "updateScheduledPost":
            continue   # правка скидає review — стан «на затвердження» дає наступний send
        state = nxt["state"]
        planner = rj.get("plannerUrl") if isinstance(rj, dict) else None
        if state is None:
            errs.append("%s: під getScheduledPosts немає рядка `  стан: …` (паспорт 4b)" % tag)
        elif re.fullmatch(r"(?i)pending review\.?", state):
            # «pending review» — твердження, якому потрібне поле стану у відповіді (р.4, A10).
            if not status:
                errs.append("%s: «стан: pending review», а поля стану у відповіді немає — пиши «поле стану не"
                            " встановлено» з plannerUrl (паспорт 4b)" % tag)
            elif not all(PENDING_VALUE.match(v) for v in status):   # не рядок (`2`, `{…}`) — теж не pending
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
    def verify_metricool(t, n, field, ln_no, gap, after, neg=False):
        shown = t.group(0).strip()
        if re.search(r"[:×–]", t.group(1)):
            return "%s: «%s» — складене число біля тегу Metricool, у відповіді такого немає" % (ln_no, shown)
        if gap.strip():
            # Між числом і тегом Metricool — лише пробіл (р.5, B12: «45,2 відсотка [#1 IGRE08]»).
            return "%s: між «%s» і тегом [#%d %s] — «%s»; тег Metricool стоїть одразу після числа" % (
                ln_no, shown, n, field, gap.strip())
        if UNIT_AFTER_TAG.match(after):
            return "%s: одиниця після тегу [#%d %s] — одиниць полів не виміряно, пиши як у відповіді" % (ln_no, n, field)
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
        vals, series = field_values(as_json(" ".join(c["resp"])), field)
        if series:
            return "%s: поле %s у відповіді #%d — ряд (кілька значень або з датою), не підсумок" % (ln_no, field, n)
        if not vals:
            return "%s: у відповіді виклику #%d немає скалярного значення поля %s" % (ln_no, n, field)
        if t.group(3):
            # Одиниці полів не виміряно (IGRE08 — взаємодії на 1000 охоплених, не частка; р.4 A13):
            # «%» біля тегу Metricool не звірити — пиши число як у відповіді.
            return "%s: «%s» з «%%» біля тегу Metricool — одиницю поля %s не виміряно, пиши як у відповіді" % (
                ln_no, shown, field)
        if neg and all(x >= 0 for x in vals):
            # «−1 240» біля невід'ємного значення — знак читач бачить (р.7, NEG).
            return "%s: «−%s» зі знаком мінус, а значення %s у відповіді #%d невід'ємне" % (ln_no, shown, field, n)
        if not matches(t.group(1), vals):
            return "%s: «%s» ≠ значенню %s у відповіді #%d (%s)" % (
                ln_no, shown, field, n, ", ".join("%g" % x for x in sorted(vals)))
        return None

    def number_errors(where, ln_no, line, call_refs=False):
        # Тег у бектиках — назва тегу в тексті, не тег; цифри в бектиках при цьому лишаються.
        line = re.sub(r"`[^`]*`", lambda m: SOURCE_TAG.sub(" ", m.group(0)), line)
        if call_refs:   # «виклик #N» — лише в inbox/стан і лише на існуючий виклик (р.6, N05)
            line = CALL_REF.sub(lambda m: " " if 1 <= int(m.group(1)) <= len(calls) else m.group(0), line)
        out, body = [], []
        # «%»/«відсот…»/«процент» будь-де в РЯДКУ з тегом Metricool — одиниць не виміряно (р.6 N09–N11;
        # р.7 P1–P3: синоніми, повноширинний знак, друге речення того ж рядка).
        if any(t.group(1) for t in SOURCE_TAG.finditer(line)) and PCT_ANY.search(SOURCE_TAG.sub(" ", line)):
            out.append("%s рядок %d: «%%»/«відсот…» у рядку з тегом Metricool — одиниць полів не виміряно, пиши як"
                       " у відповіді: %s" % (where, ln_no, line.strip()[:120]))
        for snt in sentences(line):
            if "н/д" in snt.lower():
                if numbers_in(SOURCE_TAG.sub(" ", snt), fields):
                    out.append("«н/д» з числом у тому ж реченні — пропуск цифр не має (паспорт п. 5): %s" % snt.strip())
            else:
                body.append(snt)
        body = " ".join(body)
        loc = "%s рядок %d" % (where, ln_no)
        last = 0
        for tm in SOURCE_TAG.finditer(body):
            seg = strip_not_numbers(body[last:tm.start()], fields)
            nums = list(NUM.finditer(seg))
            if not nums:
                out.append("%s: тег %s без числа перед ним" % (loc, tm.group(0)))
            else:
                for t in nums[:-1]:
                    out.append("%s: число «%s» без тегу джерела (один тег — одне число)" % (loc, t.group(0).strip()))
                if tm.group(1):
                    e = verify_metricool(nums[-1], int(tm.group(1)), tm.group(2), loc,
                                         seg[nums[-1].end():], body[tm.end():],
                                         neg=bool(re.search(r"[−-]$", seg[:nums[-1].start()])))
                    if e:
                        out.append(e)
            last = tm.end()
        for t in NUM.finditer(strip_not_numbers(body[last:], fields)):
            out.append("%s: число «%s» без тегу джерела ([#N ПОЛЕ] · [metrics.md] · [PRD] · [план] · [не метрика])"
                       % (loc, t.group(0).strip()))
        return out

    for i, ln in enumerate(report):
        if not CALL_LINE.match(ln):
            errs += number_errors("звіт", i + 1, ln)
    for i, ln in other:
        if re.match(r"^- mcp:", ln):
            ln = re.sub(r"«[^»]*»", " ", ln)       # дослівний вивід команди — у «…» (формат — вище)
        elif re.match(r"^- reviewer:", ln):
            ln = EMAIL.sub(" ", ln)                 # email — не число; хвіст рядка — вільний текст
        errs += number_errors("trace", i + 1, ln, call_refs=bool(re.match(r"^- inbox:", ln)))
    for c in calls:
        if c["state"] is not None:                  # хвіст `стан:` — теж вільний текст (р.4, A03)
            errs += number_errors("trace стан виклику #%d" % c["n"], 0, c["state"], call_refs=True)

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
