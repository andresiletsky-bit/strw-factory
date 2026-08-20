#!/usr/bin/env python3
"""Хеш дизайн-одиниці й діф проти index.yaml. Детерміновано, офлайн.

Хешуються РОБОЧІ файли (.dc.html), а не опублікована сторінка: у ній ще ~2 МБ
коду редактора, який до дизайну не має стосунку і змінюється сам по собі.

Файли беруться у відсортованому порядку, і в хеш іде ім'я разом із вмістом —
інакше перейменування файлів усередині одиниці лишалось би невидимим.
"""
import argparse, hashlib, json, os, sys, yaml

RC_TRUNCATED = 3

def unit_hash(root, working_files):
    h = hashlib.sha256()
    for rel in sorted(working_files):
        path = os.path.join(root, rel)
        with open(path, "rb") as fh:
            data = fh.read()
        # Доказ повноти: обірваний .dc.html не має закриватись мовчки.
        if rel.endswith(".dc.html") and b"</html>" not in data[-4096:]:
            print(f"ERROR: {rel} обірваний — немає </html> у хвості. "
                  f"Це НЕ «без змін», це нечитане джерело.", file=sys.stderr)
            sys.exit(RC_TRUNCATED)
        h.update(os.path.basename(rel).encode("utf-8"))
        h.update(b"\0")
        h.update(data)
    return "sha256:" + h.hexdigest()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("index")
    ap.add_argument("--repo-root", default=".")
    ap.add_argument("--fail-on-change", action="store_true")
    args = ap.parse_args()

    doc = yaml.safe_load(open(args.index)) or {}
    out, changed_any = [], False
    for u in doc.get("units", []):
        if u.get("state") != "watched":
            out.append({"ref": u.get("ref"), "hash": None,
                        "state": u.get("state"), "changed": False})
            continue
        actual = unit_hash(args.repo_root, u.get("working_files", []))
        stored = u.get("hash")
        changed = stored is not None and stored != actual
        changed_any = changed_any or changed
        out.append({"ref": u.get("ref"), "hash": actual,
                    "state": "watched", "changed": changed})

    json.dump({"units": out}, sys.stdout, ensure_ascii=False, indent=2)
    print()
    return 1 if (args.fail_on_change and changed_any) else 0

if __name__ == "__main__":
    sys.exit(main())
