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
# Мережа (латиниця, кирилиця, абревіатури, формати) — контекст «число по соцмережах».
# Словника метрик немає навмисно (чекер #33 р.2, Blocker): він пропускав «кліки», «людей»,
# таблицю. Тут за замовчуванням БУДЬ-ЯКЕ число в контексті мережі — метрика і мусить
# нести тег-цитату; «не метрика» — лише явні форми NON_METRIC нижче. Новий синонім дає
# хибний червоний (видно), а не обхід (невидимо).
SOCIAL = re.compile(r"instagram|tiktok|youtube|facebook|linkedin|threads|pinterest|twitter|соцмереж"
                    r"|інстаграм|тікток|тік-ток|ютуб|фейсбук|лінкедін|reels|shorts|stories|сторіс|metricool"
                    r"|\b(?:IG|TT|YT|FB)\b", re.I)
# Тег-цитата числа: `[#N ПОЛЕ]` — виклик #N getAnalyticsDataByMetrics, ПОЛЕ — Data Studio
# field ID (network+connector+index, напр. IGPO01; live-check 19.10 §4.3).
TAG = re.compile(r"\[#(\d+)\s+([A-Z]{4}\d{2})\]")
# Префікс поля → мережа. ВИМІРЯНО лише IG (live-check 19.10 §1.2: IGRE01 = Instagram Reels);
# решту не вгадуємо — поле з невиміряним префіксом дає FAIL, а не «схоже на TikTok».
FIELD_NETWORK = {"IG": re.compile(r"instagram|інстаграм|\bIG\b|reels|stories|сторіс", re.I)}
# Цифри, що метрикою не є: посилання, дати, час, ідентифікатори (pact-001, tri-138, IGPO01),
# номери PR, нумерація списку, пункти паспорта. Одна літера + цифри («x48000», «W43») —
# не id: у контексті мережі це число (р.2, N11).
NOT_A_NUMBER = [
    re.compile(r"https?://\S+"),
    re.compile(r"\d{4}-\d{2}-\d{2}"),
    re.compile(r"(?<!\d)\d{1,2}:\d{2}(?!\d)"),
    re.compile(r"(?:[A-Za-z]{2,}|[A-Za-z]+[-_])\d+[A-Za-z0-9_-]*"),
    re.compile(r"(?<!\w)[A-Z]\d{1,2}(?!\w)"),   # L4, G1, W43 — велика літера + 1–2 цифри
    re.compile(r"#\d+"),
    re.compile(r"^\s*-?\s*\d+[.)]\s"),
    # посилання на пункти: «п. 5», «§3», «4a–4c» (лише a–h: «5k»/«5к» — це число)
    re.compile(r"(?:п\.|§)\s*\d+[a-h]?(?!\w)"),
    re.compile(r"(?<![\d.,])\d+[a-h](?!\w)"),
]
# «Не метрика» в контексті мережі — ЛИШЕ ці форми: період вибірки з «за»/«last»,
# тривалість ролика, кількість власних чернеток/постів, «топ-N». Голе «N тижнево» — число.
NON_METRIC = [
    re.compile(r"(?:\bза|last|past)\s+\d+\s*(?:дн|день|тиж|міс|рок|day|week|month)\w*", re.I),
    re.compile(r"\d+\s*(?:секунд\w*|сек\b|хв\b|хвилин\w*|sec\w*|min\w*)", re.I),
    re.compile(r"\d+\s*(?:reels-)?(?:чернетк\w*|пост(?:и|ів)?|допис\w*|ролик\w*|публікаці\w*|шт\b\.?)(?![\w-])", re.I),
    re.compile(r"топ-?\s*\d+", re.I),
    re.compile(r"\d+\s+з\s+них", re.I),
]
NUM = re.compile(r"(?<![\d.,])(\d{1,3}(?:[   ]\d{3})+(?:[.,]\d+)?|\d+(?:[.,]\d+)?)(?![\d])"
                 r"(\s*(?:k|к|тис|млн|m|м)(?![a-zа-яіїєґ]))?(\s*%)?", re.I)
HEADING = re.compile(r"^(#{1,6})\s+(.*)$")
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")


def strip_not_numbers(text, social=False):
    for rx in NOT_A_NUMBER + (NON_METRIC if social else []):
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


def field_values(node, field, inside=False):
    """Числа, що належать полю: під ключем == field або в об'єкті, де якесь значення == field."""
    out = set()
    if isinstance(node, dict):
        here = inside or field in node.values()
        for k, v in node.items():
            out |= field_values(v, field, inside or here or k == field)
    elif isinstance(node, list):
        for v in node:
            out |= field_values(v, field, inside)
    elif inside and isinstance(node, (int, float)) and not isinstance(node, bool):
        out.add(float(node))
    return out


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
            # Лише розділ «Рев'юер черги Metricool» і рядок Andrii в ньому (р.2: «погоджено з
            # Andrii» у розділі підрядників робило рев'юером підрядника).
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
        # Пост у відповіді: його поле стану (якщо є) і autoPublish звіряються з рядком `стан:`
        # (р.2, S1/S2: «не встановлено» над `"status": "PUBLISHED"` проходило).
        post = None
        nj = as_json(nresp)
        for cand in (nj if isinstance(nj, list) else [nj]):
            if isinstance(cand, dict) and ((isinstance(key, str) and '"%s"' % cand.get("uuid") == key)
                                           or (isinstance(key, int) and cand.get("id") == key)):
                post = cand
                break
        status = None
        if post is not None:
            if post.get("autoPublish") is True:
                errs.append("%s: у getScheduledPosts пост з autoPublish: true — Metricool опублікує сам (паспорт 4b)" % tag)
            for k2, v2 in post.items():
                if re.search(r"status|state", k2, re.I):
                    status = "%s=%s" % (k2, v2)
        if state is None:
            errs.append("%s: під getScheduledPosts немає рядка `  стан: …` (паспорт 4b)" % tag)
        elif re.fullmatch(r"(?i)pending review\.?", state):
            if status is not None and not re.search(r"pending|review", status, re.I):
                errs.append("%s: «стан: pending review», а у відповіді %s (паспорт 4b–4c)" % (tag, status))
        elif state.startswith("поле стану не встановлено"):
            if status is not None:
                errs.append("%s: «поле стану не встановлено», а у відповіді поле є: %s (паспорт 4b)" % (tag, status))
            if not (isinstance(planner, str) and re.match(r"https?://\S", planner)):
                errs.append("%s: «поле стану не встановлено», а у відповіді ForReview немає plannerUrl-посилання —"
                            " доказу «на затвердження» немає (паспорт 4b)" % tag)
        elif not card_for(c["n"]):
            errs.append("%s: стан «%s» — не pending review, а рядка `- inbox: … #%d …` немає (паспорт 4c)"
                        % (tag, state, c["n"]))

    # Соцметрики (паспорт п. 5). «н/д: …» — без жодної цифри в тому ж реченні. Будь-яке
    # число в контексті мережі (рядок, попередній рядок при переносі, заголовок секції) —
    # метрика, якщо не NON_METRIC, і несе тег `[#N ПОЛЕ]`: виклик #N — getAnalyticsDataByMetrics
    # з ПОЛЕМ в `metrics`, префікс поля — мережа рядка, число — значення поля у відповіді.
    # (р.1: наявності виклику замало; р.2: «будь-яке число відповіді» пускало чуже 1 240 у TikTok.)
    def verify(t, tm, ctx, ln_no):
        shown = t.group(0).strip()
        if t.group(2):
            return "звіт рядок %d: «%s» зі скороченням — пиши як у відповіді, інакше не звірити (паспорт п. 5)" % (ln_no, shown)
        if not connected:
            return "звіт рядок %d: число по соцмережах «%s», а `- mcp:` не каже connected (паспорт п. 5)" % (ln_no, shown)
        n, field = int(tm.group(1)), tm.group(2)
        c = calls[n - 1] if 1 <= n <= len(calls) else None
        if c is None or c["tool"] != "getAnalyticsDataByMetrics":
            return "звіт рядок %d: тег [#%d %s] — виклик #%d не getAnalyticsDataByMetrics (паспорт п. 5)" % (ln_no, n, field, n)
        args = as_json(c["args_raw"]) if c["args_raw"] else None
        if not (isinstance(args, dict) and isinstance(args.get("metrics"), list) and field in args["metrics"]):
            return "звіт рядок %d: поля %s немає в `metrics` виклику #%d" % (ln_no, field, n)
        net = FIELD_NETWORK.get(field[:2])
        if net is None:
            return ("звіт рядок %d: префікс поля %s не виміряно (відомо: %s) — мережу числа не звірити"
                    % (ln_no, field, ", ".join(sorted(FIELD_NETWORK))))
        if not net.search(ctx):
            return "звіт рядок %d: поле %s — іншої мережі, ніж рядок: %s" % (ln_no, field, ctx.strip()[:80])
        vals = field_values(as_json(" ".join(c["resp"])), field)
        v = to_float(t.group(1))
        want = {v, v / 100} if t.group(3) else {v}
        if not vals:
            return "звіт рядок %d: у відповіді виклику #%d немає значення поля %s" % (ln_no, n, field)
        if not any(abs(w - x) < 1e-9 for w in want for x in vals):
            return "звіт рядок %d: «%s» ≠ значенню %s у відповіді #%d (%s)" % (
                ln_no, shown, field, n, ", ".join("%g" % x for x in sorted(vals)))
        return None

    heading_ctx, prev = "", ""
    for i, ln in enumerate(report):
        hm = HEADING.match(ln)
        if hm:
            heading_ctx = hm.group(2)
        if CALL_LINE.match(ln):
            prev = ""
            continue
        rest = []
        for snt in sentences(ln):
            if "н/д" in snt.lower():
                if numbers_in(snt):
                    errs.append("«н/д» з числом у тому ж реченні — пропуск цифр не має (паспорт п. 5): %s" % snt.strip())
            else:
                rest.append(snt)
        body = " ".join(rest)
        cont = prev if (ln.strip() and not re.match(r"^\s*(?:[-*|#>]|\d+[.)]\s)", ln)) else ""
        ctx = " ".join([heading_ctx if not hm else "", cont, body])
        prev = ln if ln.strip() else ""
        if not SOCIAL.search(ctx):
            continue
        untagged, last = [], 0
        for tm in TAG.finditer(body):
            nums = list(NUM.finditer(strip_not_numbers(body[last:tm.start()], social=True)))
            if not nums:
                errs.append("звіт рядок %d: тег [#%s %s] без числа перед ним" % (i + 1, tm.group(1), tm.group(2)))
            else:
                untagged += nums[:-1]
                e = verify(nums[-1], tm, ctx, i + 1)
                if e:
                    errs.append(e)
            last = tm.end()
        untagged += list(NUM.finditer(strip_not_numbers(body[last:], social=True)))
        for t in untagged:
            if t.group(2):
                errs.append("звіт рядок %d: «%s» зі скороченням — пиши як у відповіді, інакше не звірити (паспорт п. 5)"
                            % (i + 1, t.group(0).strip()))
            else:
                errs.append("звіт рядок %d: число по соцмережах «%s» без тегу [#N ПОЛЕ] з getAnalyticsDataByMetrics"
                            " (паспорт п. 5)" % (i + 1, t.group(0).strip()))

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
