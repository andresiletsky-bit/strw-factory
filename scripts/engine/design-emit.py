#!/usr/bin/env python3
"""Пояснення дизайн-діфу і гвардія потопу.

Чому не плоский лічильник змінених одиниць: у дизайн-системі 16 компонентів, і
один рядовий токен чіпає від 3 до 13 із них (вимір 2026-08-20: borderDefault —
13, textPrimary — 10, primary і danger — по 7). Поріг на кількість спрацьовував
би на кожній рядовій правці, і гвардію б вимкнули.

Тому спершу ПОЯСНЕННЯ: якщо зміни в багатьох одиницях зводяться до того самого
рядка-причини, це ОДНА логічна зміна, скільки б компонентів не зачепила.
Потоп — коли одиниці змінились незалежно і спільної причини не видно.

Дві речі, на яких перша редакція мовчки не працювала:

1. **Шляхи приходять зі звіту, тут вони НЕ конструюються.** Було
   `os.path.join(root, ref.split("/")[-1])`. Але `ref` — ідентифікатор реєстру,
   а не шлях: справжня одиниця `pact-001/design-system/Button` лежить у
   `pact-ios/design-reference/design-system/Button/`. Теки з іменем «Button»
   у корені репо немає, отже сигнатура виходила порожня, «спільної причини не
   знайдено» і rc=0 — зелено й ні про що. Плюс колізія: `…/design-system/Button`
   і `…/screens/Button` вказували на одну теку.

2. **Причина — це те, що З'ЯВИЛОСЬ, а не те, що є.** Було: спільний токен =
   присутній у кожній зміненій одиниці ЗАРАЗ. Один брендовий hex, який лежить у
   кіті з першого дня, присутній усюди — і «пояснював» будь-які шість
   незалежних змін, тож гвардія потопу не спрацювала б ніколи. Тепер причина
   шукається в РІЗНИЦІ `поточна сигнатура − записана в index.yaml`. Токен,
   присутній в обох знімках, причиною бути не може за побудовою.

**`--write-elements` — тут різниця стає роботою.** Доти емітер лише друкував
групи, і хребет був інертний за побудовою: жоден із 63 елементів реєстру не
називав дизайн-джерела, бо взятись йому не було звідки. Режим заводить по
елементу на ГРУПУ (тобто на логічну зміну, не на зачеплений компонент) з
обов'язковим `acceptance_basis.design_sources` — і саме це поле дає валідаторові
другу гілку протухання: макет поїде — елемент почервоніє.

Три правила, на яких цей режим тримається:

1. **`why_registry` називає ПРИЧИНУ фактами.** «Заведено емітером» — не причина.
   Причина — які саме токени з'явились і в яких одиницях; це те єдине, що
   емітер справді знає, і рівно те він і пише.
2. **`acceptance` не вигадується.** Він складається з фактичної різниці й
   ЧЕСНО заявляє, що критерії потребують людини: емітер не знає, як зміна має
   виглядати в коді й чи потрібна вона взагалі.
3. **Смуга ВИВОДИТЬСЯ, а не вгадується.** Немає правила для простору імен
   `ref` — це rc=6, а не «хай буде ios-ui». Елемент із вгаданою смугою ламає
   ізоляцію рушія тихо.

Коди виходу:
  0 — пояснено (або непояснених груп не більше порога)
  2 — звіт не читається / не в тій формі
  3 — ДЖЕРЕЛО НЕЧИТАНЕ: зниклий чи обірваний working-файл, змінена одиниця без
      записаної сигнатури. Той самий клас і той самий сенс, що rc=3 у
      `design-hash.py`: читати не було чого. Мовчазне «пояснень немає» тут
      перетворювало зниклу теку однієї одиниці на потоп із тринадцяти.
  4 — ПОТОП: непояснених груп більше порога. Під `--write-elements` це ще й
      ВІДМОВА писати: потоп іде до CEO питанням, а не шістьма елементами в
      чергу — інакше гвардія потопу гасила б сама себе.
  5 — У ЗВІТІ НЕМАЄ ЖОДНОЇ ЗМІНЕНОЇ ОДИНИЦІ: пояснювати нічого. Окремий код
      саме тому, що rc=0 тут читався б як «діф чистий», а найчастіша причина
      порожнього входу — звіт, знятий ПІСЛЯ `design-hash.py --write`.
  6 — `--write-elements`: СМУГУ ЕЛЕМЕНТА ВИВЕСТИ НЕ ВДАЛОСЯ (немає правила для
      простору імен `ref`, або виведена смуга не оголошена в `lanes.yaml`).
      Помилка, не здогад: нічого не записано.
  7 — `--write-elements`: реєстр не в тій формі, щоб у нього писати (немає теки
      елементів, немає чи не парситься `lanes.yaml`, група змішує продукти).
"""
import argparse, datetime, glob, io, json, os, re, sys

import yaml

from design_tokens import dc_truncated, tokens_of

RC_REPORT = 2
RC_SOURCE = 3
RC_FLOOD = 4
RC_EMPTY = 5
RC_LANE = 6
RC_REGISTRY = 7
FLOOD_THRESHOLD = 5

# Простір імен `ref` → смуга, у якій зміну РЕАЛІЗОВУВАТИМУТЬ.
#
# Чому таблиця, а не звірка `working_files` із глобами `owns` у lanes.yaml (це
# була перша спроба): робочі файли канвасів лежать у
# `pact-ios/design-reference/`, і ця тека НЕ належить жодній смузі — свідомо,
# бо вона довідник, а не продуктовий код. Звірка по глобах віддавала б «смуги
# немає» на кожній дизайн-одиниці, тобто ніколи не працювала б.
#
# Смуга елемента — це місце, де робиться РОБОТА, а не місце, де лежить макет.
# Зміна компонента дизайн-системи реалізується в кіті й екранах, тобто в
# `ios-ui`. Для простору імен, якого тут немає, відповіді немає — і це rc=6,
# а не мовчазний ios-ui: `pact-001/screens/Canvas` цілком міг би виявитись
# роботою іншої смуги, і вгадати за нього означало б зламати ізоляцію тихо.
NAMESPACE_LANE = {
    "design-system": "ios-ui",
}


def signature(root, ref, working_files):
    """Поточна сигнатура одиниці за ШЛЯХАМИ ЗІ ЗВІТУ. (tokens, problem)."""
    if not working_files:
        return None, (f"{ref}: у звіті немає `working_files` — сигнатуру рахувати "
                      f"нема з чого. Це НЕ «нічого не змінилось».")
    found = set()
    for rel in sorted(working_files):
        path = os.path.join(root, rel)
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError as e:
            return None, (f"{ref}: {rel} не читається ({path}): {e.strerror}. "
                          f"Це НЕ «пояснень немає» — це нечитане джерело.")
        # Емітер — ДРУГИЙ читач тих самих файлів, і між прогоном хешера і його
        # власним прогоном файл міг обірватись. Обрубок дає обрізану сигнатуру,
        # тобто хибну різницю — доказ повноти той самий, що в design-hash.py,
        # і буквально той самий: одна функція на два скрипти.
        if dc_truncated(rel, data):
            return None, (f"{ref}: {rel} обірваний — файл не закінчується на "
                          f"</html>. Сигнатура з обрубка була б хибною різницею.")
        found |= tokens_of(data)
    return found, None


def _slug(s):
    """Рядок → шматок ідентифікатора. Hex дістає префікс, інакше `#B5502E` і
    `b5502e` дали б однаковий слаг, а це різні речі в різних місцях."""
    s = ("hex-" + s[1:]) if s.startswith("#") else s
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def _cap(parts, limit=3):
    """Не більше `limit` шматків в імені, решта — числом. Ідентифікатор мусить
    лишатись читаним людиною: `…-and-10-more` каже те саме, що десять слагів,
    але не робить з імені файлу абзац."""
    if len(parts) <= limit:
        return list(parts)
    return list(parts[:limit]) + [f"and-{len(parts) - limit}-more"]


def element_id(product, refs, tokens):
    """Ідентифікатор елемента — ФУНКЦІЯ ВІД ЗМІСТУ ГРУПИ, і в цьому вся
    ідемпотентність: повторний прогін на тій самій різниці рахує те саме ім'я,
    бачить готовий файл і не заводить дубля.

    Наслідок, названий вголос: два різні прогони з ОДНАКОВИМИ токенами й
    одиницями вважаються однією логічною зміною. Так і задумано — саме це
    означає «та сама різниця». Якщо ті самі токени поїхали вдруге, елемент уже
    існує, і другий раз про це скаже не дубль, а протухання: `design_sources`
    старого елемента розійдеться з новою базовою лінією.
    """
    units = _cap([_slug(r.rsplit("/", 1)[-1]) for r in refs])
    toks = _cap([_slug(t) for t in tokens]) if tokens else ["no-token-diff"]
    return f"{product}.design.{'-'.join(units)}-{'-'.join(toks)}"


def read_lanes(items_dir):
    """(lanes, problem). `lanes.yaml` лежить ПОРУЧ із текою елементів — тим
    самим правилом, що й журнал рішень у validate-items.sh: інакше аргумент
    `--write-elements` бреше на worktree (елементи звідти, смуги зі спільної
    копії)."""
    path = os.path.join(os.path.dirname(os.path.normpath(items_dir)), "lanes.yaml")
    if not os.path.isfile(path):
        return None, f"немає {path} — смугу елемента вивести нема з чого"
    try:
        doc = yaml.safe_load(open(path, encoding="utf-8")) or {}
    except Exception as e:
        return None, f"{path} не парситься: {e}"
    lanes = {l.get("id"): l for l in (doc.get("lanes") or []) if l.get("id")}
    if not lanes:
        return None, f"{path} не оголошує жодної смуги"
    return lanes, None


def count_decisions(items_dir):
    """Скільки датованих записів у журналі рішень ЗАРАЗ.

    Рахується так само, як у `validate-items.sh` (директорія `decisions/`
    головна, моноліт — фасад), і навмисно тим самим правилом: розійдись вони,
    елемент одразу почервоніє в валідаторі — вище лічильник дасть ERROR
    «лічильник вигаданий», нижче дасть STALE. Тихого розходження тут немає, і
    саме тому копія умови прийнятна.

    Повертає None, якщо журналу не видно взагалі: краще лишити поле порожнім
    (валідатор дасть WARN), ніж вписати вигадане число.
    """
    root = os.path.dirname(os.path.dirname(os.path.normpath(items_dir)))
    nodes = sorted(glob.glob(os.path.join(root, "decisions", "*", "*.md")))
    rx = re.compile(r"^##\s+(\d{4}-\d{2}-\d{2})\b")
    if nodes:
        n = 0
        for path in nodes:
            with io.open(path, encoding="utf-8") as fh:
                for line in fh:
                    if rx.match(line):
                        n += 1
                        break
        return n
    mono = os.path.join(root, "decisions-log.md")
    if os.path.isfile(mono):
        with io.open(mono, encoding="utf-8") as fh:
            return sum(1 for line in fh if rx.match(line))
    return None


def _block(text, indent="  "):
    """Текст у блоковий скаляр YAML. Порожні рядки лишаються порожніми, інакше
    відступ перетворює їх на рядки з пробілами, і `yaml.safe_load` це переживе,
    а людина в діфі побачить сміття."""
    return "\n".join((indent + l) if l else "" for l in text.split("\n"))


def _yaml_str(s):
    return json.dumps(s, ensure_ascii=False)


def render_element(*, iid, product, lane, repo, refs, tokens, unit_files,
                   unit_hashes, now, decisions_count, explained):
    """Текст item-файлу. Свідомо ТЕКСТ, а не `yaml.safe_dump`, з тієї ж причини,
    що й у `design-hash.py --write`: дамп зробив би з абзаців один рядок із
    `\\n`, і елемент, який має читати ЛЮДИНА, став би нечитаним."""
    if tokens:
        what = "з'явились токени: " + ", ".join(f"`{t}`" for t in tokens)
        crit = "\n".join(
            f"- Прийняти або відхилити зміну токена `{t}` "
            f"{'в одиницях' if len(refs) > 1 else 'в одиниці'} " +
            ", ".join(f"`{r}`" for r in refs) + "."
            for t in tokens)
    else:
        # Порожня різниця токенів — законний стан: хеш розійшовся, а токени ті
        # самі (змінилась верстка або проза). Збрехати тут найлегше, тому
        # текст говорить рівно те, що є.
        what = ("НЕ з'явилось жодного нового токена — хеш розійшовся, а "
                "токенова частина та сама")
        crit = ("- З'ясувати, ЩО саме змінилось: емітер бачить лише токени, а "
                "тут змінилась не токенова частина (верстка, проза, розмітка). "
                "Дивитись діф робочих файлів очима.")
    listed = "\n".join(
        f"- `{r}` — {what}.\n"
        f"  Робочі файли: " + ", ".join(f"`{f}`" for f in unit_files[r]) + "."
        for r in refs)

    group_why = (
        "**Чому це ОДИН елемент, а не по одному на кожну одиницю:** зміна в "
        f"{len(refs)} одиницях зводиться до спільної причини — "
        + ", ".join(f"`{t}`" for t in tokens) +
        ". Один рядовий токен чіпає від 3 до 13 компонентів кіта (вимір "
        "2026-08-20), і елемент на кожен зачеплений компонент був би шумом, "
        "а не роботою.\n\n"
    ) if explained and len(refs) > 1 else ""

    sources = [
        f"дизайн-діф L7 {now}: " + "; ".join(
            f"одиниця {r}, пораховний хеш {unit_hashes[r]}" for r in refs) +
        " — хеш пораховано в цьому ж прогоні (design-hash.py), не взято з індексу",
        "ЖУРНАЛ РІШЕНЬ ЦИМ ЕЛЕМЕНТОМ НЕ ЧИТАВСЯ. Поле `decisions_log_entries` "
        "цього ж блоку — водяний знак: стільки датованих записів було в журналі "
        "в мить заведення. "
        "Він НЕ означає, що `acceptance` із ними звірено; він означає, що будь-який "
        "допис ПІСЛЯ цієї миті протухлить елемент і змусить людину звірити.",
    ]
    src_lines = "\n".join(f"    - {_yaml_str(s)}" for s in sources)
    ds_lines = "\n".join(
        f"    - ref: {r}\n"
        f"      hash: \"{unit_hashes[r]}\"\n"
        f"      verified_at: {now}"
        for r in refs)
    counter = (f"  decisions_log_entries: {decisions_count}\n"
               if decisions_count is not None else "")

    why = (
        f"Заведено емітером L7 (`design-emit.py --write-elements`) {now} на "
        f"ФАКТИЧНІЙ різниці дизайну, порахованій у тому ж прогоні.\n\n"
        f"**Що змінилось:**\n\n{listed}\n\n"
        f"{group_why}"
        f"**Чому це елемент реєстру, а не рядок у звіті:** макет поїхав, а код "
        f"за ним не пішов. Доки різницю не прийнято й не відхилено, вона живе "
        f"лише в `design/index.yaml` — тобто ніде з погляду роботи. Елемент — "
        f"це те місце, де різницю видно черзі.\n\n"
        f"**Хто це читатиме:** людина, перед тим як брати елемент у роботу. "
        f"Тому `acceptance` нижче називає межу свого знання вголос."
    )

    acceptance = (
        "**Джерело критеріїв — фактична різниця макета, не задум.** Нижче рівно "
        "те, що побачив емітер, і нічого понад те.\n\n"
        f"{crit}\n\n"
        "**Ці критерії НЕ повні, і елемент цього не приховує.** Емітер знає "
        "єдине: які токеноподібні рядки з'явились у робочих файлах одиниці. Він "
        "не знає, як зміна має виглядати в коді, які гейти її стережуть, що з "
        "нею робить VoiceOver і чи вона взагалі потрібна. **Перш ніж брати "
        "елемент у роботу, людина мусить переглянути макет і дописати критерії "
        "приймання сюди** — інакше цикл закриється проти критерію, якого ніхто "
        "не формулював.\n\n"
        "**Реалізація — L3.** L7 доводить різницю до черги й на тому спиняється "
        "(спека §2: «позначити і завести», не «зробити»)."
    )

    return (
        "schema_version: 1\n"
        f"id: {iid}\n"
        f"product: {product}\n"
        "loop: L3-build\n"
        f"lane: {lane}\n"
        "state: ready\n"
        "lease: {run_id: null, epoch: 0, heartbeat: null}\n"
        f"repo: {repo}\n"
        f"branch: cycle/{iid.split('.', 1)[1].replace('.', '-')}\n"
        "why_registry: |\n" + _block(why) + "\n"
        "acceptance: |\n" + _block(acceptance) + "\n"
        "acceptance_basis:\n"
        f"  verified_against_decisions_log_at: {now}\n"
        f"{counter}"
        "  sources:\n" + src_lines + "\n"
        "  design_sources:\n" + ds_lines + "\n"
        "attempts: 0\n"
        "evidence: {run_id: null, commit_sha: null, cwd: null, pr: null, merged_at: null}\n"
    )


def write_elements(groups, changed_by_ref, items_dir):
    """(список записаних/пропущених, rc). Нічого не пише, доки не з'ясовано ВСЕ:
    смуги виводяться для всіх груп наперед, і перша ж невиведена спиняє запис
    цілком. Інакше половина груп лягла б у реєстр, а половина — ні, і другий
    прогін дав би різницю там, де її не було."""
    if not os.path.isdir(items_dir):
        print(f"ERROR: теки елементів немає: {items_dir}. Нічого не записано.",
              file=sys.stderr)
        return [], RC_REGISTRY
    lanes, problem = read_lanes(items_dir)
    if problem:
        print(f"ERROR: {problem}. Нічого не записано.", file=sys.stderr)
        return [], RC_REGISTRY

    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
    decisions_count = count_decisions(items_dir)

    planned, problems = [], []
    for g in groups:
        refs = list(g["refs"])
        tokens = list(g["causes"]) or list(g.get("unexplained_tokens") or [])
        products = {r.split("/", 1)[0] for r in refs}
        if len(products) != 1:
            problems.append(f"група змішує продукти {sorted(products)} — "
                            f"елемент належить одному продукту")
            continue
        product = products.pop()
        derived = set()
        for r in refs:
            parts = r.split("/")
            ns = parts[1] if len(parts) > 2 else None
            if ns not in NAMESPACE_LANE:
                problems.append(
                    f"{r}: смугу вивести НЕ ВДАЛОСЯ — простір імен "
                    f"{ns!r} не має правила в NAMESPACE_LANE. Це помилка, а не "
                    f"привід угадати: елемент із вгаданою смугою ламає ізоляцію "
                    f"рушія тихо.")
            else:
                derived.add(NAMESPACE_LANE[ns])
        if len(derived) != 1:
            if derived:
                problems.append(f"група дає {len(derived)} різних смуг "
                                f"{sorted(derived)} — це не одна робота")
            continue
        lane = derived.pop()
        if lane not in lanes:
            problems.append(f"виведена смуга {lane!r} не оголошена в lanes.yaml")
            continue
        planned.append({
            "id": element_id(product, refs, tokens),
            "product": product, "lane": lane,
            "repo": lanes[lane].get("repo"), "refs": refs, "tokens": tokens,
            "explained": bool(g["causes"]),
        })

    if problems:
        for p in problems:
            print(f"ERROR: {p}", file=sys.stderr)
        return [], RC_LANE

    written = []
    for p in planned:
        path = os.path.join(items_dir, f"{p['id']}.yaml")
        if os.path.exists(path):
            # Ідемпотентність. Свідомо НЕ перезаписуємо: елемент, який людина
            # вже дописала руками, важливіший за згенерований текст.
            written.append({"id": p["id"], "path": path, "created": False,
                            "reason": "уже заведений — той самий діф"})
            continue
        text = render_element(
            iid=p["id"], product=p["product"], lane=p["lane"], repo=p["repo"],
            refs=p["refs"], tokens=p["tokens"],
            unit_files={r: changed_by_ref[r].get("working_files") or []
                        for r in p["refs"]},
            unit_hashes={r: changed_by_ref[r].get("hash") for r in p["refs"]},
            now=now, decisions_count=decisions_count, explained=p["explained"])
        tmp = f"{path}.{os.getpid()}.tmp"
        try:
            with io.open(tmp, "w", encoding="utf-8") as fh:
                fh.write(text)
            os.replace(tmp, path)
        except OSError as e:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            print(f"ERROR: не вдалося записати {path}: {e.strerror}",
                  file=sys.stderr)
            return written, RC_REGISTRY
        written.append({"id": p["id"], "path": path, "created": True})
    return written, 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--explain", required=True, help="JSON-звіт від design-hash.py")
    ap.add_argument("--repo-root", default=".")
    ap.add_argument("--write-elements", metavar="ТЕКА-ЕЛЕМЕНТІВ",
                    help="завести по елементу реєстру на кожну ГРУПУ, з "
                         "acceptance_basis.design_sources. Ідемпотентно: "
                         "повторний прогін на тій самій різниці дубля не робить.")
    args = ap.parse_args()

    try:
        doc = json.load(open(args.explain))
    except (OSError, ValueError) as e:
        print(f"ERROR: не читається звіт {args.explain}: {e}", file=sys.stderr)
        return RC_REPORT

    changed = [u for u in doc.get("units", []) if u.get("changed")]

    # Порожній вхід — окремий стан, не «чисто» (I2 рев'ю 2026-08-21). rc=0
    # означав три різні речі одразу: «пояснено», «непояснених ≤5» і «у звіті
    # змінених одиниць узагалі немає». Останнє трапляється рівно тоді, коли
    # оператор переганяє хешер ПІСЛЯ `--write` — базова лінія вже переписана,
    # діф зник, і найгучніший результат петлі виглядає як найчистіший.
    if not changed:
        print("ERROR: у звіті немає жодної зміненої одиниці — пояснювати нічого. "
              "Це НЕ «діф чистий»: найчастіша причина — звіт знято ПІСЛЯ "
              "`design-hash.py --write`, який уже стер різницю.", file=sys.stderr)
        return RC_EMPTY

    # РІЗНИЦЯ сигнатур, по одиниці. Порожня різниця — законний результат
    # (змінилась проза, не токени), і тоді одиниця нічим не пояснена.
    diffs, problems = {}, []
    for u in changed:
        ref = u.get("ref")
        stored = u.get("stored_tokens")
        if stored is None:
            # Не «нічого не змінилось»: базової лінії просто немає, і різницю
            # рахувати нема від чого. Мовчки взяти всю поточну сигнатуру за
            # різницю означало б, що перша ж одиниця без `tokens` пояснює
            # будь-що своїм найпоширенішим токеном.
            problems.append(f"{ref}: немає записаної сигнатури `tokens` в index.yaml — "
                            f"різницю рахувати нема від чого. Це нечитане джерело, "
                            f"а не «нічого не змінилось».")
            continue
        current, problem = signature(args.repo_root, ref, u.get("working_files") or [])
        if problem:
            problems.append(problem)
            continue
        diffs[ref] = current - set(stored)

    if problems:
        for p in problems:
            print(f"ERROR: {p}", file=sys.stderr)
        return RC_SOURCE

    # Спільна причина = токен, що З'ЯВИВСЯ в КОЖНІЙ зміненій одиниці. Саме
    # «у кожній», не «у більшості»: часткове перекриття не є однією зміною.
    causes = []
    if diffs:
        common = set.intersection(*diffs.values())
        # Усі спільні токени, а не `sorted(...)[0]`: алфавіт ставив би hex
        # попереду імен і називав причиною «#B5502F» там, де змістовна назва
        # `color.brand.primary` лежала поруч.
        causes = sorted(common)

    # Групування НЕ все-або-нічого (I1 рев'ю 2026-08-21). Було: є спільна
    # причина → одна група з усіма `refs` і `unexplained: 0`. Залишок
    # `diff − causes` по одиниці не рахувався ніде, тож власна зміна одиниці
    # зникала у спільній причині: `color.text.disabled` чіпає 13 компонентів, і
    # доданий у той самий прохід `border.focus` на Button — «перший кандидат на
    # елемент» зі спеки §12 — не отримав би елемента ніколи.
    #
    # Пояснена одиниця — та, чия різниця НЕПОРОЖНЯ і вся зводиться до спільних
    # причин. Порожня різниця (змінилась проза, не токени) поясненням не є:
    # хеш розійшовся, а сказати чому нічим.
    common = set(causes)
    explained = [r for r in sorted(diffs) if diffs[r] and not (diffs[r] - common)]
    leftover = [r for r in sorted(diffs) if r not in explained]

    groups = []
    if causes and explained:
        groups.append({"causes": causes, "refs": explained})
    for ref in leftover:
        groups.append({"causes": [], "refs": [ref],
                       "unexplained_tokens": sorted(diffs[ref] - common)})
    unexplained = len(leftover)

    result = {"groups": groups, "unexplained": unexplained,
              "changed_tokens": {r: sorted(t) for r, t in sorted(diffs.items())}}

    rc = RC_FLOOD if unexplained > FLOOD_THRESHOLD else 0

    if args.write_elements is not None:
        if rc == RC_FLOOD:
            # Потоп іде до CEO ПИТАННЯМ (паспорт L7), а не шістьма елементами в
            # чергу. Писати тут означало б, що гвардія потопу гасить сама себе:
            # ескалація лишається на папері, а робота вже роздана.
            print(f"ERROR: потоп — {unexplained} непояснених груп (поріг "
                  f"{FLOOD_THRESHOLD}). Елементів НЕ заведено: непояснений діф "
                  f"іде питанням до CEO, а не роботою в чергу.", file=sys.stderr)
            result["elements"] = []
        else:
            elements, wrc = write_elements(
                groups, {u.get("ref"): u for u in changed}, args.write_elements)
            result["elements"] = elements
            rc = wrc or rc

    # Звіт друкується В БУДЬ-ЯКОМУ разі, навіть коли запис відмовився: пояснення
    # діфу — самостійний доказ, і ховати його за кодом виходу означало б, що
    # невиведена смуга стирає ще й те, що вже було з'ясовано.
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    print()
    return rc

if __name__ == "__main__":
    sys.exit(main())
