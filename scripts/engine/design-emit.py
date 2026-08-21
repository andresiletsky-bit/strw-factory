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

Коди виходу:
  0 — пояснено (або непояснених груп не більше порога)
  2 — звіт не читається / не в тій формі
  3 — ДЖЕРЕЛО НЕЧИТАНЕ: зниклий чи обірваний working-файл, змінена одиниця без
      записаної сигнатури. Той самий клас і той самий сенс, що rc=3 у
      `design-hash.py`: читати не було чого. Мовчазне «пояснень немає» тут
      перетворювало зниклу теку однієї одиниці на потоп із тринадцяти.
  4 — ПОТОП: непояснених груп більше порога
  5 — У ЗВІТІ НЕМАЄ ЖОДНОЇ ЗМІНЕНОЇ ОДИНИЦІ: пояснювати нічого. Окремий код
      саме тому, що rc=0 тут читався б як «діф чистий», а найчастіша причина
      порожнього входу — звіт, знятий ПІСЛЯ `design-hash.py --write`.
"""
import argparse, json, os, sys

from design_tokens import dc_truncated, tokens_of

RC_REPORT = 2
RC_SOURCE = 3
RC_FLOOD = 4
RC_EMPTY = 5
FLOOD_THRESHOLD = 5


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--explain", required=True, help="JSON-звіт від design-hash.py")
    ap.add_argument("--repo-root", default=".")
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

    json.dump({"groups": groups, "unexplained": unexplained,
               "changed_tokens": {r: sorted(t) for r, t in sorted(diffs.items())}},
              sys.stdout, ensure_ascii=False, indent=2)
    print()
    return RC_FLOOD if unexplained > FLOOD_THRESHOLD else 0

if __name__ == "__main__":
    sys.exit(main())
