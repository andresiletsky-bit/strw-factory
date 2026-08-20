#!/usr/bin/env python3
"""Пояснення дизайн-діфу і гвардія потопу.

Чому не плоский лічильник змінених одиниць: у дизайн-системі 16 компонентів, і
один рядовий токен чіпає від 3 до 13 із них (вимір 2026-08-20: borderDefault —
13, textPrimary — 10, primary і danger — по 7). Поріг на кількість спрацьовував
би на кожній рядовій правці, і гвардію б вимкнули.

Тому спершу ПОЯСНЕННЯ: якщо зміни в багатьох одиницях зводяться до того самого
рядка-причини, це ОДНА логічна зміна, скільки б компонентів не зачепила.
Потоп — коли одиниці змінились незалежно і спільної причини не видно.
"""
import argparse, json, os, re, sys
from collections import Counter

RC_FLOOD = 4
FLOOD_THRESHOLD = 5

# Токеноподібні рядки: hex-кольори і `token.path` — саме те, що змінюється
# наскрізно й пояснює багато одиниць одразу.
TOKENISH = re.compile(r"#[0-9A-Fa-f]{6}\b|\b[a-z]+(?:\.[a-z-]+){1,3}\b")

def signature(root, ref):
    """Множина токеноподібних рядків одиниці. Порожня — пояснення не буде."""
    stem = ref.split("/")[-1]
    base = os.path.join(root, stem)
    if not os.path.isdir(base):
        return set()
    found = set()
    for name in sorted(os.listdir(base)):
        if not name.endswith(".dc.html"):
            continue
        with open(os.path.join(base, name), "rb") as fh:
            found |= set(TOKENISH.findall(fh.read().decode("utf-8", "replace")))
    return found

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--explain", required=True, help="JSON-звіт від design-hash.py")
    ap.add_argument("--repo-root", default=".")
    args = ap.parse_args()

    try:
        doc = json.load(open(args.explain))
    except (OSError, ValueError) as e:
        print(f"ERROR: не читається звіт {args.explain}: {e}", file=sys.stderr)
        return 2

    changed = [u for u in doc.get("units", []) if u.get("changed")]
    sigs = {u["ref"]: signature(args.repo_root, u["ref"]) for u in changed}

    # Спільна причина = токен, присутній у КОЖНІЙ зміненій одиниці. Саме
    # «у кожній», не «у більшості»: часткове перекриття не є однією зміною.
    common = None
    if changed:
        counts = Counter()
        for s in sigs.values():
            counts.update(s)
        shared = [tok for tok, n in counts.items() if n == len(changed)]
        common = sorted(shared)[0] if shared else None

    if common is not None:
        groups = [{"cause": common, "refs": sorted(sigs)}]
        unexplained = 0
    else:
        groups = [{"cause": None, "refs": [r]} for r in sorted(sigs)]
        unexplained = len(groups)

    json.dump({"groups": groups, "unexplained": unexplained},
              sys.stdout, ensure_ascii=False, indent=2)
    print()
    return RC_FLOOD if unexplained > FLOOD_THRESHOLD else 0

if __name__ == "__main__":
    sys.exit(main())
