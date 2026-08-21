#!/usr/bin/env python3
"""Хеш дизайн-одиниці й діф проти index.yaml. Детерміновано, офлайн.

Хешуються РОБОЧІ файли (.dc.html), а не опублікована сторінка: у ній ще ~2 МБ
коду редактора, який до дизайну не має стосунку і змінюється сам по собі.

Файли беруться у відсортованому порядку, і в хеш іде ім'я разом із вмістом —
інакше перейменування файлів усередині одиниці лишалось би невидимим.

Поряд із хешем пишеться СИГНАТУРА (`tokens:`) — відсортована множина
токеноподібних рядків одиниці. Хеш каже «щось змінилось», сигнатура дозволяє
сказати ЩО: `design-emit.py` віднімає записану сигнатуру від поточної, і лише
те, що з'явилось у різниці, може пояснювати зміну. Без записаної сигнатури
поточний стан не містить цієї відповіді взагалі — токен, що лежить у кіті з
першого дня, «пояснював» би будь-яку зміну.

Шляхи файлів кожної одиниці віддаються у звіті (`working_files`). Споживач їх
НЕ конструює: `ref` — це ідентифікатор в реєстрі, а не шлях на диску, і
`pact-001/design-system/Button` цілком законно лежить у
`pact-ios/design-reference/design-system/Button/`.

Коди виходу:
  0 — усе прочитано; різниці немає (або `--fail-on-change` не заданий)
  1 — щось розійшлося з записаною базовою лінією, і заданий `--fail-on-change`
  2 — індекс не в тій формі, щоб із ним працювати (перед `--write` це тверда
      відмова: писати наосліп у файл, якого не розумієш, гірше, ніж не писати)
  3 — ДЖЕРЕЛО НЕЧИТАНЕ: обірваний файл, відсутній файл, `watched`-одиниця без
      `working_files`. Це НЕ «без змін» і НЕ «змінилось» — читати не було чого,
      і споживач, який розрізняє лише 0/1, прочитав би тишу як відповідь.
  5 — `--verify`: базова лінія неповна (немає `hash` або `tokens`), джерело
      нечитане, або є змінена одиниця без вердикту — пораховний хеш
      розійшовся з базовою лінією, і крок 4 її не оновив
  6 — `--fail-on-figma-stale`: хоч один дублікат у Figma розійшовся з
      пораховним хешем свого джерела (`figma.rendered_from != hash`). Про
      свіжість ДУБЛІКАТА, не про читаність джерела — з `--verify` не змішувати.
"""
import argparse, hashlib, io, json, os, re, sys, yaml

from design_tokens import dc_truncated, tokens_of

RC_CHANGED     = 1
RC_INDEX       = 2
RC_TRUNCATED   = 3
RC_UNVERIFIED  = 5
RC_FIGMA_STALE = 6


def read_unit(root, ref, working_files):
    """(hash, tokens, problem) для одиниці. `problem` не None → джерело нечитане.

    Повертає, а не завершує процес: `--verify` мусить перелічити ВСЕ, чого
    бракує, а не спинитись на першій одиниці. Штатний шлях завершує сам —
    див. `unit_hash`.
    """
    # Порожній список і відсутній ключ давали SHA порожнього рядка
    # (e3b0c442…) і `changed: false`, rc=0 — «без змін» там, де читати не було
    # чого. Плюс колізія: дві РІЗНІ одиниці без файлів отримували один хеш.
    # Це той самий клас, що обрив, тому й код виходу той самий.
    if not working_files:
        return None, None, (f"{ref}: одиниця `watched`, але `working_files` порожні — "
                            f"хешувати нічого. Це НЕ «без змін», це нечитане джерело.")

    h = hashlib.sha256()
    tokens = set()
    for rel in sorted(working_files):
        path = os.path.join(root, rel)
        # Відсутній файл давав traceback → rc=1, а rc=1 означає «змінилось».
        # Зниклий скретчпад (спека §11.0) читався б як зміна макета.
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError as e:
            return None, None, (f"{ref}: {rel} не читається ({path}): {e.strerror}. "
                                f"Це НЕ «змінилось» — це нечитане джерело.")
        # Доказ повноти: обірваний .dc.html не має закриватись мовчки. Умова
        # живе в `design_tokens.py` однією копією на два скрипти — див. там,
        # чому вікно в 4 КіБ хибило в обидва боки.
        if dc_truncated(rel, data):
            return None, None, (f"{ref}: {rel} обірваний — файл не закінчується "
                                f"на </html>. Це НЕ «без змін», це нечитане джерело.")
        h.update(os.path.basename(rel).encode("utf-8"))
        h.update(b"\0")
        h.update(data)
        # Сигнатура береться з ТИХ САМИХ байтів, що й хеш, і з того самого
        # переліку файлів. Розійдись вони — була б зміна хеша з порожньою
        # різницею токенів, тобто «змінилось, і пояснити нічим» за побудовою.
        tokens |= tokens_of(data)
    return "sha256:" + h.hexdigest(), sorted(tokens), None


def unit_hash(root, ref, working_files):
    digest, tokens, problem = read_unit(root, ref, working_files)
    if problem:
        print(f"ERROR: {problem}", file=sys.stderr)
        sys.exit(RC_TRUNCATED)
    return digest, tokens


def write_baseline(path, computed):
    """Вписати пораховані хеші й сигнатури в index.yaml, не чіпаючи решти файла.

    Свідомо ТЕКСТОВА правка, а не `yaml.safe_dump`: дамп переписав би весь
    файл — порядок ключів, лапки, коментарі, `url`, `project`, `reason`. Тоді
    «запис не псує інших полів» довелося б доводити щоразу; так воно є за
    побудовою, і в діфі видно рівно стільки рядків, скільки їх змінилось.

    `hash:` мусить існувати: додавати його самотужки означало б угадувати місце
    в блоці одиниці. `tokens:` угадувати не треба — його місце визначене
    (одразу під `hash:`, той самий відступ), тому відсутній він дописується.
    Інакше жоден чинний індекс не міг би дійти до повної базової лінії без
    ручного редагування, а `--verify` вимагає саме її.
    """
    text = io.open(path, encoding="utf-8").read()
    lines = text.split("\n")
    cur = None
    at_hash, at_tokens, indent = {}, {}, {}
    for i, line in enumerate(lines):
        m = re.match(r"^\s*-\s+ref:\s*(.+?)\s*$", line)
        if m:
            cur = m.group(1).strip().strip("\"'")
            continue
        m = re.match(r"^(\s*)hash:\s", line)
        if m and cur in computed:
            at_hash[cur] = i
            indent[cur] = m.group(1)
            continue
        m = re.match(r"^(\s*)tokens:\s*(.*)$", line)
        if m and cur in computed:
            if not m.group(2).lstrip().startswith("["):
                print(f"ERROR: {path}: `tokens:` одиниці {cur} записано блоковим "
                      f"списком — цей скрипт пише лише плоский, і переписувати "
                      f"чужу форму наосліп не буде. Нічого не записано.",
                      file=sys.stderr)
                return False
            at_tokens[cur] = i

    missing = sorted(set(computed) - set(at_hash))
    if missing:
        # Ключ `hash` обов'язковий для `watched` (validate-design-index.py).
        print(f"ERROR: {path}: не знайдено рядка `hash:` для одиниць: "
              f"{', '.join(missing)}. Індекс не в тій формі, щоб у нього "
              f"писати — нічого не записано.", file=sys.stderr)
        return False

    for ref, (digest, tokens) in computed.items():
        lines[at_hash[ref]] = f'{indent[ref]}hash: "{digest}"'
        flat = f'{indent[ref]}tokens: {json.dumps(tokens, ensure_ascii=False)}'
        if ref in at_tokens:
            lines[at_tokens[ref]] = flat
    # Вставки — знизу вгору, інакше кожна зсувала б індекси наступних.
    for ref in sorted(computed, key=lambda r: at_hash[r], reverse=True):
        if ref not in at_tokens:
            flat = f'{indent[ref]}tokens: {json.dumps(computed[ref][1], ensure_ascii=False)}'
            lines.insert(at_hash[ref] + 1, flat)

    # Запис через сусідній тимчасовий файл і `os.replace` (M3 рев'ю
    # 2026-08-21). Було `io.open(path, "w")` — відкриття вже обрізало продуктовий
    # індекс, тож перерваний запис лишав його недописаним: базова лінія
    # ПОРАХОВАНА, але в файлі половина одиниць. `os.replace` атомарний у межах
    # однієї теки, тому індекс або старий, або новий, третього стану немає.
    # Ім'я з PID: у strw-state пишуть паралельні сесії, і спільний `.tmp`
    # перетворив би гонку на змішаний файл.
    tmp = f"{path}.{os.getpid()}.tmp"
    try:
        with io.open(tmp, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines))
        os.replace(tmp, path)
    except OSError as e:
        # Ціна атомарності названа вголос: тимчасовий файл створюється поруч,
        # отже потрібна запис-права на ТЕКУ, не лише на файл. Немає — це тверда
        # відмова з іменем, а не половина індексу.
        try:
            os.unlink(tmp)
        except OSError:
            pass
        print(f"ERROR: {path}: не вдалося записати через тимчасовий файл {tmp}: "
              f"{e.strerror}. Індекс НЕ змінено.", file=sys.stderr)
        return False
    return True


def verify(doc, root):
    """`--verify`: базова лінія повна, джерела читаються, непереглянутого діфу немає.

    Це та умова, на яку посилається `stop_condition` паспорта L7. Спека §7
    формулює зупинку так: «кожна змінена одиниця має або елемент, або записану
    причину». Перша редакція перевіряла ЛИШЕ повноту базової лінії й нічого про
    зміни — при справжньому дрейфі `--fail-on-change` віддавав rc=1, а
    `--verify` тієї ж миті віддавав 0, тобто петля закривалась над
    непереглянутим діфом (I3 рев'ю 2026-08-21).

    Тому сюди додано третю умову: жодна `watched`-одиниця не має пораховного
    хеша, відмінного від записаного. Межа названа чесно і в паспорті теж:
    ЄДИНИЙ вердикт, який фабрика сьогодні вміє записати, — це оновлена базова
    лінія (крок 4 скіла, і він вимагає, щоб зміну побачили очима). Заведення
    елементів реєстру не робить жоден вузол (обсяг плану 3), тож «має елемент»
    ця умова не перевіряє й не вдає, що перевіряє.
    """
    problems = []
    watched = 0
    for u in doc.get("units", []):
        if u.get("state") != "watched":
            continue
        watched += 1
        ref = u.get("ref")
        stored = u.get("hash")
        if not stored:
            problems.append(f"{ref}: немає записаного `hash` — базової лінії не існує")
        if not u.get("tokens"):
            problems.append(f"{ref}: немає записаної сигнатури `tokens` — "
                            f"різницю токенів рахувати нема від чого")
        actual, _, problem = read_unit(root, ref, u.get("working_files") or [])
        if problem:
            problems.append(problem)
        elif stored and stored != actual:
            problems.append(f"{ref}: змінена одиниця без вердикту — пораховний хеш "
                            f"розійшовся з базовою лінією, а базову лінію не "
                            f"оновлено (крок 4 скіла, ПІСЛЯ перегляду макета). "
                            f"Петля не закривається над непереглянутим діфом.")
    if not watched:
        problems.append("жодної `watched`-одиниці — звіряти нема чого")

    for p in problems:
        print(f"ERROR: {p}", file=sys.stderr)
    if problems:
        return RC_UNVERIFIED
    print(f"OK: базова лінія повна для {watched} watched-одиниць "
          f"(hash + tokens + усі working_files читаються), непереглянутих змін немає")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("index")
    ap.add_argument("--repo-root", default=".")
    ap.add_argument("--fail-on-change", action="store_true")
    ap.add_argument("--write", action="store_true",
                    help="занести пораховані хеші й сигнатури в index.yaml як нову "
                         "базову лінію. Звіт про різницю друкується ДО запису й лишається "
                         "правдивим: інакше запис стирав би доказ, що зміна була.")
    ap.add_argument("--verify", action="store_true",
                    help="не рахувати діф, а перевірити повноту базової лінії: у кожної "
                         "watched-одиниці є hash, є tokens, і всі working_files читаються.")
    ap.add_argument("--fail-on-figma-stale", action="store_true",
                    help="вийти з rc=6 (RC_FIGMA_STALE), якщо хоч у одної watched-одиниці "
                         "з блоком `figma` `rendered_from` розійшовся з пораховним hash. "
                         "Без прапорця — лише звіт (поле figmaStale), як --fail-on-change.")
    args = ap.parse_args()

    try:
        doc = yaml.safe_load(open(args.index)) or {}
    except Exception as e:
        print(f"ERROR: {args.index} не парситься: {e}", file=sys.stderr)
        return RC_INDEX
    if not isinstance(doc, dict):
        print(f"ERROR: {args.index}: корінь не мапа, а {type(doc).__name__}",
              file=sys.stderr)
        return RC_INDEX

    if args.verify:
        return verify(doc, args.repo_root)

    out, changed_any, figma_stale_any, computed = [], False, False, {}
    for u in doc.get("units", []):
        if u.get("state") != "watched":
            out.append({"ref": u.get("ref"), "hash": None,
                        "state": u.get("state"), "changed": False,
                        "working_files": list(u.get("working_files") or []),
                        "stored_tokens": u.get("tokens"),
                        "figmaStale": None})
            continue
        ref = u.get("ref")
        working_files = list(u.get("working_files") or [])
        actual, tokens = unit_hash(args.repo_root, ref, working_files)
        stored = u.get("hash")
        changed = stored is not None and stored != actual
        changed_any = changed_any or changed
        computed[ref] = (actual, tokens)

        # figmaStale: одиниця без блоку `figma` — null, не false. Відсутність
        # дубліката і свіжий дублікат — різні стани, і плутати їх означає
        # брехати про перевірку, якої не було.
        figma = u.get("figma")
        # Покручений `figma:` (рядок замість мапи) давав AttributeError →
        # traceback → rc=1, тобто «змінилось»: та сама підміна причини, проти
        # якої написані rc=2 і rc=3 (I6 рев'ю 2026-08-21). Валідатор схеми це
        # ловить, але з цього шляху його ніхто не кличе, тож форма
        # перевіряється тут — і віддає rc=2, «індекс не в тій формі».
        if figma is not None and not isinstance(figma, dict):
            print(f"ERROR: {args.index}: `figma` одиниці {ref} — "
                  f"{type(figma).__name__}, а не мапа. Індекс не в тій формі; "
                  f"це НЕ «змінилось». Прогнати validate-design-index.py.",
                  file=sys.stderr)
            return RC_INDEX
        figma_stale = figma.get("rendered_from") != actual if figma else None
        if figma_stale:
            figma_stale_any = True

        # `working_files` і `stored_tokens` їдуть у звіт, бо емітер — окремий
        # процес, і єдина альтернатива — щоб він вигадував їх із `ref`. Саме це
        # він і робив: `ref.split("/")[-1]` як ім'я теки. На справжній одиниці
        # такої теки немає, сигнатура виходила порожня, і «пояснень немає»
        # друкувалось як нуль.
        out.append({"ref": ref, "hash": actual,
                    "state": "watched", "changed": changed,
                    "working_files": working_files,
                    "stored_tokens": u.get("tokens"),
                    "figmaStale": figma_stale})

    # Звіт ПЕРШИЙ, запис ДРУГИЙ, і `changed` рахується проти хеша, який стояв
    # в індексі ДО запису. Порядок тут не косметика: записати базову лінію
    # раніше, ніж прозвітувати, — значить стерти доказ, що зміна була.
    json.dump({"units": out}, sys.stdout, ensure_ascii=False, indent=2)
    print()

    if args.write and computed:
        if not write_baseline(args.index, computed):
            return RC_INDEX

    if args.fail_on_change and changed_any:
        return RC_CHANGED
    if args.fail_on_figma_stale and figma_stale_any:
        return RC_FIGMA_STALE
    return 0

if __name__ == "__main__":
    sys.exit(main())
