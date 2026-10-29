#!/usr/bin/env python3
"""human-checklist-check.py — чи відповідає чекліст ручної перевірки CEO стандарту фабрики.

Стандарт: references/human-test-checklist.md (слова CEO 29.10: «ти готуєш покрокові чеклісти, як
мені потрібно пройти»). Куплено інцидентом: чотири запити human_smoke 04–06.09 казали лише «перевір X
руками», ніхто їх не пройшов, один мало не закрили як пройдений.

    human-checklist-check.py <чекліст.md> [--repo <корінь репо продукту>] [--item <id елемента>]

--repo — корінь, від якого читається «Джерело підписів»; типово найближча тека з .git над файлом.
--item — id елемента, заради якого CEO отримує чекліст; мусить бути в **Покриває:**.

Коди: 0 — відповідає · 1 — порушення (кожне рядком `FAIL [правило] …`) · 2 — не поміряно (немає
файла, не читається джерело підписів). «Не зміг перевірити» ≠ «чисто»: 2 ніколи не зливається з 0.

Правила (назви в дужках — у виводі; набір human-checklist-check.test.sh має червоний випадок на кожне):
  [preconditions] перший розділ `## 0. Передумови` ДО першого кроку, з непорожніми полями
                  **Збірка:**, **Пристрої:**, **Акаунти:**;
  [covers]        у передумовах непорожнє **Покриває:** — id елементів у `…`; з --item id мусить бути серед них
                  (інцидент: запит «перевір X» отримав би загальний прохід, у якому X немає);
  [report]        до першого кроку — рядок **Як звітувати:** з ✅ і ❌;
  [steps]         хоч один крок `**N.M …**`, номери не повторюються;
  [actor]         у кожному кроці в дужках той, хто діє: телефон-літера (A, B, «A і B»);
  [checkbox]      під кожним кроком хоч один очікуваний результат `- [ ] …` (порожній, не [x]);
  [lang]          кроки й очікування українською (кирилиця ≥ 60% літер);
  [label]         кожен жирний підпис **«…»** з літерами є в джерелі підписів дослівно (формат %@/%lld —
                  шаблон, не «будь-що»); жирні підписи без **Джерело підписів:** — порушення;
  [destructive]   крок, що стирає дані (видалити/стерти/скинути/очистити), — в останній частині, або
                  з позначкою «не зачіпає наступних кроків»;
  [scope]         розділ `## Не входить` хоч з одним пунктом, і в кожному пункті є причина.
"""
import json
import os
import re
import sys

STEP = re.compile(r"^\*\*(\d+\.\d+)\b([^*\n]*)\*\*")
ACTOR = re.compile(r"\(([^()]*)\)")
PHONE = re.compile(r"^[A-ZА-ЯІЇЄҐ](?:\s*(?:,|і|та|й)\s*[A-ZА-ЯІЇЄҐ])*$")
CHECKBOX_OPEN = re.compile(r"^\s*- \[ \] \S")
CHECKBOX_ANY = re.compile(r"^\s*- \[[^\]]\]")
H2 = re.compile(r"^## (.*)$")
LABEL = re.compile(r"\*\*«([^»\n]+)»\*\*")
DESTROY = re.compile(r"(?i)видал(и|іть|яє|яю|ити)|стер(ти|іть)|стира|скин(ути|ьте)|очист(ити|іть)")
# Назви й цитати в «» без жирного (назва договору «Тест видалення», текст на екрані) — не дія кроку.
QUOTE = re.compile(r"«[^»\n]*»")
SAFE_MARK = "не зачіпає наступних кроків"
FORMAT = re.compile(r"%(?:\d+\$)?(?:@|l{0,2}[duif]|lld|s)")


def fail_measure(msg):
    print("⬜ не поміряно: " + msg)
    print("human-checklist-check: 2")
    sys.exit(2)


def find_repo(path):
    d = os.path.dirname(os.path.abspath(path))
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            return d
        up = os.path.dirname(d)
        if up == d:
            return os.path.dirname(os.path.abspath(path))
        d = up


def load_strings(path):
    """Усі ключі й значення джерела підписів: .xcstrings (JSON) або .strings (ключ = значення)."""
    vals = set()
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as e:
        fail_measure("джерело підписів %s не читається: %s" % (path, e))
    if path.endswith(".xcstrings"):
        try:
            data = json.loads(text)
        except ValueError as e:
            fail_measure("джерело підписів %s — не JSON: %s" % (path, e))

        def walk(node):
            if isinstance(node, dict):
                su = node.get("stringUnit")
                if isinstance(su, dict) and isinstance(su.get("value"), str):
                    vals.add(su["value"])
                for v in node.values():
                    walk(v)
            elif isinstance(node, list):
                for v in node:
                    walk(v)

        strings = data.get("strings") if isinstance(data, dict) else None
        if not isinstance(strings, dict):
            fail_measure("джерело підписів %s без ключа strings" % path)
        for k, v in strings.items():
            vals.add(k)
            walk(v)
    else:
        for k, v in re.findall(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', text):
            vals.add(k)
            vals.add(v)
    return vals


def label_known(label, vals):
    if label in vals:
        return True
    for v in vals:
        if "%" not in v or not FORMAT.search(v):
            continue
        parts = FORMAT.split(v)
        rx = "^" + ".+".join(re.escape(p) for p in parts) + "$"
        if re.match(rx, label):
            return True
    return False


def main(argv):
    args = list(argv)
    opts = {}
    for flag in ("--repo", "--item"):
        if flag in args:
            i = args.index(flag)
            if i + 1 >= len(args):
                fail_measure("%s без значення" % flag)
            opts[flag] = args[i + 1]
            del args[i:i + 2]
    repo, item = opts.get("--repo"), opts.get("--item")
    if len(args) != 1:
        print(__doc__.split("\n\n")[1])
        sys.exit(2)
    path = args[0]
    try:
        lines = open(path, encoding="utf-8").read().split("\n")
    except OSError as e:
        fail_measure("чекліст %s не читається: %s" % (path, e))
    repo = repo or find_repo(path)
    bad = []

    def err(rule, msg):
        bad.append("FAIL [%s] %s" % (rule, msg))

    # ── розділи і кроки ─────────────────────────────────────────────────────
    sections = []          # (назва, рядок)
    steps = []             # dict: num, line, idx, section, body (рядки до наступного кроку/розділу)
    cur = None
    for idx, line in enumerate(lines):
        h = H2.match(line)
        if h:
            sections.append((h.group(1).strip(), idx))
            cur = None
            continue
        m = STEP.match(line)
        if m:
            cur = {"num": m.group(1), "head": m.group(2), "line": line, "idx": idx,
                   "section": len(sections) - 1, "body": []}
            steps.append(cur)
            continue
        if cur is not None:
            cur["body"].append(line)

    first_step = steps[0]["idx"] if steps else len(lines)
    before = lines[:first_step]

    # [preconditions]
    pre = [s for s in sections if re.match(r"^0\.?\s+Передумови\b", s[0])]
    if not sections or not re.match(r"^0\.?\s+Передумови\b", sections[0][0]):
        err("preconditions", "перший розділ мусить бути `## 0. Передумови` (зараз: %s)"
            % (sections[0][0] if sections else "розділів немає"))
    if pre and pre[0][1] > first_step:
        err("preconditions", "передумови стоять після першого кроку (рядок %d)" % (pre[0][1] + 1))
    if pre:
        start = pre[0][1]
        nxt = [s[1] for s in sections if s[1] > start]
        block = lines[start:(nxt[0] if nxt else len(lines))]
        for field in ("Збірка", "Пристрої", "Акаунти"):
            hit = [l for l in block if re.match(r"^\s*-?\s*\*\*%s:\*\*" % field, l)]
            if not hit:
                err("preconditions", "у передумовах немає поля **%s:**" % field)
            elif not re.sub(r"^\s*-?\s*\*\*%s:\*\*" % field, "", hit[0]).strip(" .\t"):
                err("preconditions", "поле **%s:** порожнє" % field)
        # Поле — пункт списку разом із рядками-продовженнями (відступ), доки не почнеться наступний пункт.
        ci = [i for i, l in enumerate(block) if re.match(r"^\s*-?\s*\*\*Покриває:\*\*", l)]
        cov = ""
        if ci:
            cov = block[ci[0]]
            for l in block[ci[0] + 1:]:
                if not l.startswith("  ") or not l.strip():
                    break
                cov += " " + l.strip()
        # `id` → 4.1, 4.2: номери між цим id і наступним. Заява без кроків — не покриття (рев'ю плану р.2, R4).
        found = list(re.finditer(r"`([^`\s]+)`", cov))
        covered = {}
        for k, m in enumerate(found):
            tail = cov[m.end():(found[k + 1].start() if k + 1 < len(found) else len(cov))]
            covered[m.group(1)] = re.findall(r"\b\d+\.\d+\b", tail)
        if not ci:
            err("covers", "у передумовах немає **Покриває:** — які елементи цей прохід перевіряє")
        elif not covered:
            err("covers", "**Покриває:** без жодного id у `…`")
        else:
            nums = {st["num"] for st in steps}
            for cid, cnums in covered.items():
                if not cnums:
                    err("covers", "**Покриває:** `%s` без номерів кроків (`%s` → 4.1, 4.2)" % (cid, cid))
                for n in cnums:
                    if n not in nums:
                        err("covers", "**Покриває:** `%s` → %s, а кроку %s у файлі немає" % (cid, n, n))
            if item and item not in covered:
                err("covers", "елемент %s не названо в **Покриває:** (%s) — чекліст не про цю зміну"
                    % (item, ", ".join(covered)))
    elif item:
        err("covers", "елемент %s: передумов немає, тож і **Покриває:**" % item)

    # [report]
    rep = [l for l in before if "**Як звітувати:**" in l]
    if not rep:
        err("report", "до першого кроку немає рядка **Як звітувати:** (CEO відповідає лише ✅ / ❌ + що побачив)")
    else:
        i = before.index(rep[0])
        para = []
        for l in before[i:]:
            if not l.strip():
                break
            para.append(l)
        para = " ".join(para)
        if "✅" not in para or "❌" not in para:
            err("report", "**Як звітувати:** без обох знаків ✅ і ❌")

    # [steps]
    if not steps:
        err("steps", "жодного нумерованого кроку `**N.M (A)** …`")
    seen = {}
    for st in steps:
        if st["num"] in seen:
            err("steps", "крок %s двічі (рядки %d і %d)" % (st["num"], seen[st["num"]] + 1, st["idx"] + 1))
        seen.setdefault(st["num"], st["idx"])

    scope_idx = [s[1] for s in sections if re.match(r"^Не входить\b", s[0])]
    step_sections = sorted({st["section"] for st in steps})
    last_section = step_sections[-1] if step_sections else None

    for st in steps:
        n = st["num"]
        # Тіло кроку — до наступного кроку або розділу; «---» і порожні рядки не рахуються.
        body = [l for l in st["body"] if l.strip() and l.strip() != "---"]
        # [actor]
        actors = ACTOR.findall(st["head"])
        if not actors:
            err("actor", "крок %s: у дужках не названо, хто діє (A, B, «A і B»)" % n)
        elif not any(PHONE.match(a.strip()) for a in actors):
            err("actor", "крок %s: «%s» — не телефон-літера (A, B, «A і B»)" % (n, actors[-1]))
        # [checkbox]
        if any(CHECKBOX_ANY.match(l) and not CHECKBOX_OPEN.match(l) for l in body):
            err("checkbox", "крок %s: відмічений чекбокс — очікування пише агент порожнім `- [ ]`" % n)
        if not any(CHECKBOX_OPEN.match(l) for l in body):
            err("checkbox", "крок %s: немає очікуваного результату `- [ ] …`" % n)
        # [destructive] — дія кроку: рядок кроку і рядки тіла, що не є очікуваннями
        action = " ".join([st["line"]] + [l for l in body if not CHECKBOX_ANY.match(l)])
        if DESTROY.search(QUOTE.sub("", LABEL.sub(lambda m: m.group(1), action))) and SAFE_MARK not in action \
                and st["section"] != last_section:
            err("destructive", "крок %s стирає дані не в останній частині — перенеси наостанок або "
                "познач «%s» з поясненням" % (n, SAFE_MARK))

    # [lang] — кроки й очікування; підписи в «» і код у `` не рахуються
    text = []
    for st in steps:
        text.append(st["line"])
        text.extend(st["body"])
    blob = re.sub(r"`[^`]*`|«[^»]*»", "", "\n".join(text))
    letters = [c for c in blob if c.isalpha()]
    cyr = [c for c in letters if "\u0400" <= c <= "\u04ff"]
    if letters and len(cyr) / len(letters) < 0.6:
        err("lang", "кроки не українською: кирилиці %d%% літер (поріг 60%%)" % (100 * len(cyr) // len(letters)))

    # [label]
    labels = []
    for idx, line in enumerate(lines):
        for lab in LABEL.findall(line):
            if any(c.isalpha() for c in lab):
                labels.append((idx, lab))
    src_line = [l for l in lines if re.match(r"^\s*-?\s*\*\*Джерело підписів:\*\*", l)]
    if labels and not src_line:
        err("label", "є жирні підписи «…», а **Джерело підписів:** не названо — звірити нема з чим")
    elif labels:
        m = re.search(r"`([^`]+)`", src_line[0])
        if not m:
            err("label", "**Джерело підписів:** без шляху в `…`")
        else:
            src = os.path.normpath(os.path.join(repo, m.group(1)))
            if not os.path.isfile(src):
                fail_measure("джерело підписів %s не знайдено (корінь %s)" % (src, repo))
            vals = load_strings(src)
            for idx, lab in labels:
                if not label_known(lab, vals):
                    err("label", "рядок %d: підпис «%s» не знайдено в %s дослівно" % (idx + 1, lab, m.group(1)))

    # [scope]
    if not scope_idx:
        err("scope", "немає розділу `## Не входить` (що свідомо не перевіряється і чому)")
    else:
        start = scope_idx[0]
        nxt = [s[1] for s in sections if s[1] > start]
        items = [l for l in lines[start + 1:(nxt[0] if nxt else len(lines))] if re.match(r"^- \S", l)]
        if not items:
            err("scope", "розділ «Не входить» без жодного пункту")
        for it in items:
            reason = re.sub(r"^- (\*\*[^*]+\*\*)?", "", it).strip(" .")
            if len(reason) < 10:
                err("scope", "пункт «%s» без причини" % it[2:].strip())

    for b in bad:
        print(b)
    print("не міряється: рядок verdict: зі слів CEO, а не агента; правдивість позначки «%s»; "
          "чи кроки справді покривають зміну — це чекер і CEO, не валідатор" % SAFE_MARK)
    if bad:
        print("human-checklist-check: 1 · порушень %d · %s" % (len(bad), path))
        return 1
    print("human-checklist-check: 0 · кроків %d · підписів звірено %d · %s" % (len(steps), len(labels), path))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
