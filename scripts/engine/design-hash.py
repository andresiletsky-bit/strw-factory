#!/usr/bin/env python3
"""Хеш дизайн-одиниці й діф проти index.yaml. Детерміновано, офлайн.

Хешуються РОБОЧІ файли (.dc.html), а не опублікована сторінка: у ній ще ~2 МБ
коду редактора, який до дизайну не має стосунку і змінюється сам по собі.

Файли беруться у відсортованому порядку, і в хеш іде ім'я разом із вмістом —
інакше перейменування файлів усередині одиниці лишалось би невидимим.

Коди виходу:
  0 — усе прочитано; різниці немає (або `--fail-on-change` не заданий)
  1 — щось розійшлося з записаною базовою лінією, і заданий `--fail-on-change`
  2 — індекс не в тій формі, щоб із ним працювати (перед `--write` це тверда
      відмова: писати наосліп у файл, якого не розумієш, гірше, ніж не писати)
  3 — ДЖЕРЕЛО НЕЧИТАНЕ: обірваний файл, відсутній файл, `watched`-одиниця без
      `working_files`. Це НЕ «без змін» і НЕ «змінилось» — читати не було чого,
      і споживач, який розрізняє лише 0/1, прочитав би тишу як відповідь.
"""
import argparse, hashlib, io, json, os, re, sys, yaml

RC_CHANGED   = 1
RC_INDEX     = 2
RC_TRUNCATED = 3

def unit_hash(root, ref, working_files):
    # Порожній список і відсутній ключ давали SHA порожнього рядка
    # (e3b0c442…) і `changed: false`, rc=0 — «без змін» там, де читати не було
    # чого. Плюс колізія: дві РІЗНІ одиниці без файлів отримували один хеш.
    # Це той самий клас, що обрив, тому й код виходу той самий.
    if not working_files:
        print(f"ERROR: {ref}: одиниця `watched`, але `working_files` порожні — "
              f"хешувати нічого. Це НЕ «без змін», це нечитане джерело.",
              file=sys.stderr)
        sys.exit(RC_TRUNCATED)

    h = hashlib.sha256()
    for rel in sorted(working_files):
        path = os.path.join(root, rel)
        # Відсутній файл давав traceback → rc=1, а rc=1 означає «змінилось».
        # Зниклий скретчпад (спека §11.0) читався б як зміна макета.
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError as e:
            print(f"ERROR: {ref}: {rel} не читається ({path}): {e.strerror}. "
                  f"Це НЕ «змінилось» — це нечитане джерело.", file=sys.stderr)
            sys.exit(RC_TRUNCATED)
        # Доказ повноти: обірваний .dc.html не має закриватись мовчки.
        if rel.endswith(".dc.html") and b"</html>" not in data[-4096:]:
            print(f"ERROR: {rel} обірваний — немає </html> у хвості. "
                  f"Це НЕ «без змін», це нечитане джерело.", file=sys.stderr)
            sys.exit(RC_TRUNCATED)
        h.update(os.path.basename(rel).encode("utf-8"))
        h.update(b"\0")
        h.update(data)
    return "sha256:" + h.hexdigest()


def write_hashes(path, computed):
    """Вписати пораховані хеші в index.yaml, не чіпаючи решти файла.

    Свідомо ТЕКСТОВА правка, а не `yaml.safe_dump`: дамп переписав би весь
    файл — порядок ключів, лапки, коментарі, `url`, `project`, `reason`. Тоді
    «запис не псує інших полів» довелося б доводити щоразу; так воно є за
    побудовою, і в діфі видно рівно стільки рядків, скільки хешів змінилось.
    """
    text = io.open(path, encoding="utf-8").read()
    lines = text.split("\n")
    cur, written = None, set()
    for i, line in enumerate(lines):
        m = re.match(r"^\s*-\s+ref:\s*(.+?)\s*$", line)
        if m:
            cur = m.group(1).strip().strip("\"'")
            continue
        m = re.match(r"^(\s*)hash:\s", line)
        if m and cur in computed:
            lines[i] = f'{m.group(1)}hash: "{computed[cur]}"'
            written.add(cur)
    missing = sorted(set(computed) - written)
    if missing:
        # Ключ `hash` обов'язковий для `watched` (validate-design-index.py).
        # Дописувати його самотужки означало б угадувати відступ і місце —
        # краще відмовитись уголос, ніж зіпсувати індекс наполовину.
        print(f"ERROR: {path}: не знайдено рядка `hash:` для одиниць: "
              f"{', '.join(missing)}. Індекс не в тій формі, щоб у нього "
              f"писати — нічого не записано.", file=sys.stderr)
        return False
    io.open(path, "w", encoding="utf-8").write("\n".join(lines))
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("index")
    ap.add_argument("--repo-root", default=".")
    ap.add_argument("--fail-on-change", action="store_true")
    ap.add_argument("--write", action="store_true",
                    help="занести пораховані хеші в index.yaml як нову базову "
                         "лінію. Звіт про різницю друкується ДО запису й лишається "
                         "правдивим: інакше запис стирав би доказ, що зміна була.")
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

    out, changed_any, computed = [], False, {}
    for u in doc.get("units", []):
        if u.get("state") != "watched":
            out.append({"ref": u.get("ref"), "hash": None,
                        "state": u.get("state"), "changed": False})
            continue
        ref = u.get("ref")
        actual = unit_hash(args.repo_root, ref, u.get("working_files") or [])
        stored = u.get("hash")
        changed = stored is not None and stored != actual
        changed_any = changed_any or changed
        computed[ref] = actual
        out.append({"ref": ref, "hash": actual,
                    "state": "watched", "changed": changed})

    # Звіт ПЕРШИЙ, запис ДРУГИЙ, і `changed` рахується проти хеша, який стояв
    # в індексі ДО запису. Порядок тут не косметика: записати базову лінію
    # раніше, ніж прозвітувати, — значить стерти доказ, що зміна була.
    json.dump({"units": out}, sys.stdout, ensure_ascii=False, indent=2)
    print()

    if args.write and computed:
        if not write_hashes(args.index, computed):
            return RC_INDEX

    return RC_CHANGED if (args.fail_on_change and changed_any) else 0

if __name__ == "__main__":
    sys.exit(main())
