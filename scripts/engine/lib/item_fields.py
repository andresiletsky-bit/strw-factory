# -*- coding: utf-8 -*-
"""Форма полів елемента реєстру і «готовність до A» — один код для двох читачів.

validate-items.sh (форма → ERROR) і autonomy-route.sh (готовність → причина B)
мусять міряти ту саму річ: інакше реєстр зелений, а маршрут каже «не готово»
(або навпаки) — клас tri-070. Специфікація: strw-ops
reports/2026-10-20-hybrid-autonomy-spec.md §2–§3; правило — L3 №10 і №11.

Повідомлення — без префікса імені файлу: його додає викликач.
"""
import datetime
import hashlib
import json
import re

AUTONOMY = ("unattended", "with-ceo")
# Принцип 5 company-context: кожне значення робить елемент B (спека §2.4).
TOUCHES = ("money", "release", "prod", "data-deletion", "third-party-data",
           "privacy-behavior", "milestone-scope")
VERDICTS = ("PASS", "PASS-WITH-NOTES", "FAIL")     # шкала review-policy.md
PLAN_KEYS = {"files", "order", "risks", "proof", "risks_none_because"}
TESTS_SPEC_KEYS = {"name", "red_when", "negative_control"}
PLAN_REVIEW_KEYS = {"verdict", "by", "at", "sha"}
BUDGET_KEYS = {"max_cycles", "max_hours"}
SHA_RE = re.compile(r"^sha256:[0-9a-f]{64}$")


def _text(v):
    return isinstance(v, str) and bool(v.strip())


def _num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def plan_sha(plan):
    """Версія плану: sha256 канонічного JSON (ключі відсортовані). Коментарі й
    порядок ключів у YAML версію не міняють; будь-яка зміна значення — міняє."""
    canon = json.dumps(plan, sort_keys=True, ensure_ascii=False,
                       separators=(",", ":"), default=str)
    return "sha256:" + hashlib.sha256(canon.encode("utf-8")).hexdigest()


def plan_errors(plan):
    """Форма `plan` (аудит 2026-09-03 П1.4, L3 правило 10). Порожньо = форма валідна."""
    if not isinstance(plan, dict):
        return [f"`plan` має бути мапою з `files`, `order`, `risks`, `proof`, "
                f"а не {type(plan).__name__}"]
    out = []
    unknown = sorted(set(plan) - PLAN_KEYS)
    if unknown:
        # Закритий словник: одрук у назві ключа інакше мовчки викидає половину
        # плану з-під перевірки.
        out.append(f"plan має непізнані ключі {unknown} — дозволені {sorted(PLAN_KEYS)}")
    for f_ in ("files", "order"):
        v = plan.get(f_)
        if not isinstance(v, list) or not v:
            out.append(f"plan.{f_} мусить бути НЕПОРОЖНІМ списком (отримано {v!r})")
    r = plan.get("risks")
    if not isinstance(r, list):
        out.append("plan.risks мусить бути списком (порожній — лише разом "
                   "із рядком plan.risks_none_because)")
    elif not r and not _text(plan.get("risks_none_because")):
        # «Ризиків немає» без причини — це не вимір, а пропуск поля.
        out.append("plan.risks порожній без plan.risks_none_because — "
                   "«ризиків немає» мусить бути ТВЕРДЖЕННЯМ, а не мовчанням")
    if not _text(plan.get("proof")):
        out.append("plan.proof мусить бути непорожнім рядком — чим саме "
                   "буде доведено, що план виконано")
    return out


def form_errors(it):
    """Форма полів режиму A/B, незалежно від стану й від значення `autonomy`."""
    out = []
    if "autonomy" in it and it.get("autonomy") not in AUTONOMY:
        out.append(f"autonomy = {it.get('autonomy')!r} — дозволені {list(AUTONOMY)} "
                   f"(поля немає = with-ceo)")
    if "touches" in it:
        t = it.get("touches")
        if not isinstance(t, list):
            out.append(f"touches має бути списком (порожній — «нічого з принципу 5»), "
                       f"а не {t!r}")
        else:
            bad = [x for x in t if x not in TOUCHES]
            if bad:
                # Невідоме значення — ERROR, не «нічого»: одрук `mony` інакше
                # вивів би гроші з-під B мовчки.
                out.append(f"touches має невідомі значення {bad} — дозволені {list(TOUCHES)}")
    if "tests_spec" in it:
        ts = it.get("tests_spec")
        if not isinstance(ts, list) or not ts:
            out.append("tests_spec має бути НЕПОРОЖНІМ списком записів "
                       "{name, red_when, negative_control}")
        else:
            for j, e in enumerate(ts):
                if not isinstance(e, dict):
                    out.append(f"tests_spec[{j}] має бути записом {{name, red_when, negative_control}}")
                    continue
                unknown = sorted(set(e) - TESTS_SPEC_KEYS)
                if unknown:
                    out.append(f"tests_spec[{j}] має непізнані ключі {unknown} — "
                               f"дозволені {sorted(TESTS_SPEC_KEYS)}")
                for k in sorted(TESTS_SPEC_KEYS):
                    if not _text(e.get(k)):
                        out.append(f"tests_spec[{j}].{k} — порожньо (назва тесту · що робить "
                                   f"його червоним · на якій підробці він мусить упасти)")
    if "plan_review" in it:
        pr = it.get("plan_review")
        if not isinstance(pr, dict):
            out.append("plan_review має бути мапою {verdict, by, at, sha}")
        else:
            unknown = sorted(set(pr) - PLAN_REVIEW_KEYS)
            if unknown:
                out.append(f"plan_review має непізнані ключі {unknown} — "
                           f"дозволені {sorted(PLAN_REVIEW_KEYS)}")
            if pr.get("verdict") not in VERDICTS:
                out.append(f"plan_review.verdict = {pr.get('verdict')!r} — шкала {list(VERDICTS)}")
            if not _text(pr.get("by")):
                out.append("plan_review.by — порожньо (яка модель рецензувала план)")
            at = pr.get("at")
            if not (isinstance(at, (datetime.date, datetime.datetime)) or
                    (isinstance(at, str) and re.match(r"^\d{4}-\d{2}-\d{2}", at))):
                out.append(f"plan_review.at = {at!r} — не ISO-дата")
            if not (isinstance(pr.get("sha"), str) and SHA_RE.match(pr["sha"])):
                out.append(f"plan_review.sha = {pr.get('sha')!r} — очікується sha256:<64 hex> "
                           f"(autonomy-route.sh --plan-sha <елемент>)")
    if "budget" in it:
        b = it.get("budget")
        if not isinstance(b, dict):
            out.append("budget має бути мапою {max_cycles, max_hours}")
        else:
            unknown = sorted(set(b) - BUDGET_KEYS)
            if unknown:
                out.append(f"budget має непізнані ключі {unknown} — дозволені {sorted(BUDGET_KEYS)}")
            mc, mh = b.get("max_cycles"), b.get("max_hours")
            if not (isinstance(mc, int) and not isinstance(mc, bool) and mc > 0):
                out.append(f"budget.max_cycles = {mc!r} — ціле більше нуля")
            if not (_num(mh) and mh > 0):
                out.append(f"budget.max_hours = {mh!r} — число більше нуля")
    return out


def readiness_gaps(it):
    """«Готовність до A» (спека §3) — для `autonomy: unattended`, і для S теж.
    Порожньо = готово. Кожен рядок — причина простими словами."""
    gaps = []
    if not _text(it.get("acceptance")) and not (isinstance(it.get("acceptance"), list) and it["acceptance"]):
        gaps.append("немає acceptance — критеріїв, що має бути правдою")
    if not _text(it.get("not_in_scope")) and not (isinstance(it.get("not_in_scope"), list) and it["not_in_scope"]):
        gaps.append("немає not_in_scope — що свідомо не робимо")
    plan = it.get("plan")
    if plan is None:
        gaps.append("немає plan — файлів, порядку, ризиків і доказу до першого коміту")
    elif plan_errors(plan):
        gaps.append("plan покручений: " + plan_errors(plan)[0])
    if not (isinstance(it.get("tests_spec"), list) and it["tests_spec"]):
        gaps.append("немає tests_spec — назв тестів до коду, з причиною червоного і негативним контролем")
    pr = it.get("plan_review")
    if not isinstance(pr, dict) or not pr:
        gaps.append("немає plan_review — вердикту чекера по плану")
    else:
        if pr.get("verdict") != "PASS":
            gaps.append(f"план не має PASS від чекера (plan_review.verdict = {pr.get('verdict')!r})")
        elif isinstance(plan, dict) and pr.get("sha") != plan_sha(plan):
            # Вердикт виданий на ІНШИЙ план: план змінили після рев'ю.
            gaps.append("план змінено після рев'ю — plan_review.sha не дорівнює версії поточного plan")
    if not (isinstance(it.get("budget"), dict) and it["budget"]):
        gaps.append("немає budget — стелі циклів і годин")
    return gaps
