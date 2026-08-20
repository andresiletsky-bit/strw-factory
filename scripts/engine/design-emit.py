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
"""
import argparse, json, os, sys

from design_tokens import tokens_of

RC_REPORT = 2
RC_SOURCE = 3
RC_FLOOD = 4
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
        # тобто хибну різницю — доказ повноти той самий, що в design-hash.py.
        if rel.endswith(".dc.html") and b"</html>" not in data[-4096:]:
            return None, (f"{ref}: {rel} обірваний — немає </html> у хвості. "
                          f"Сигнатура з обрубка була б хибною різницею.")
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

    if causes:
        groups = [{"causes": causes, "refs": sorted(diffs)}]
        unexplained = 0
    else:
        groups = [{"causes": [], "refs": [r]} for r in sorted(diffs)]
        unexplained = len(groups)

    json.dump({"groups": groups, "unexplained": unexplained,
               "changed_tokens": {r: sorted(t) for r, t in sorted(diffs.items())}},
              sys.stdout, ensure_ascii=False, indent=2)
    print()
    return RC_FLOOD if unexplained > FLOOD_THRESHOLD else 0

if __name__ == "__main__":
    sys.exit(main())
