#!/usr/bin/env python3
"""Схема index.yaml дизайн-одиниць. Детермінована, без моделі.

`unwatched` БЕЗ `reason` — помилка навмисно: сенс цього стану в тому, що
система вголос каже, ЧОМУ вона за одиницею не стежить. Без причини це вже не
чесна заява, а тиха діра.
"""
import sys, yaml

ALLOWED_STATE = {"watched", "unwatched"}
ALLOWED_SURFACE = {"canvas-artifact", "claude-design"}

def main(path):
    doc = yaml.safe_load(open(path)) or {}
    errors = []
    if doc.get("schema_version") != 1:
        errors.append("schema_version має бути 1")
    units = doc.get("units")
    if not isinstance(units, list) or not units:
        errors.append("units має бути непорожнім списком")
        units = []

    seen = set()
    for i, u in enumerate(units):
        where = u.get("ref") or f"units[{i}]"
        if not u.get("ref"):
            errors.append(f"{where}: немає ref")
        elif u["ref"] in seen:
            errors.append(f"{where}: ref повторюється")
        else:
            seen.add(u["ref"])

        if u.get("surface") not in ALLOWED_SURFACE:
            errors.append(f"{where}: surface={u.get('surface')!r}, "
                          f"дозволені {sorted(ALLOWED_SURFACE)}")

        state = u.get("state")
        if state not in ALLOWED_STATE:
            errors.append(f"{where}: state={state!r}, дозволені {sorted(ALLOWED_STATE)}")
        elif state == "unwatched" and not u.get("reason"):
            errors.append(f"{where}: unwatched без reason — стан існує саме щоб "
                          f"назвати причину вголос")
        elif state == "watched":
            if not u.get("working_files"):
                errors.append(f"{where}: watched без working_files")
            if "hash" not in u:
                errors.append(f"{where}: watched без ключа hash (null допустимий)")

    for e in errors:
        print(f"ERROR: {e}", file=sys.stderr)
    return 1 if errors else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
