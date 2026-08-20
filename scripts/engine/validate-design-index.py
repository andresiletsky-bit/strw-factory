#!/usr/bin/env python3
"""Схема index.yaml дизайн-одиниць. Детермінована, без моделі.

`unwatched` БЕЗ `reason` — помилка навмисно: сенс цього стану в тому, що
система вголос каже, ЧОМУ вона за одиницею не стежить. Без причини це вже не
чесна заява, а тиха діра.

`surface: code` — одиниця, чиє джерело лежить у репозиторії коду (наприклад
`tokens.json`), а не в канвас-артефакті чи claude.ai/design. Хешується тією
самою машинерією: `watched`, `working_files`, `hash`, `tokens`.

Необов'язковий блок `figma` на будь-якій одиниці описує дублікат у Figma —
`file_key` (обов'язково), `node_id` (необов'язково), `rendered_from` (хеш, з
якого малювався дублікат; обов'язково, `sha256:…`). `figma` на `unwatched`-
одиниці — помилка: за `unwatched` хеш не рахується, тож `rendered_from` буде
НІ З ЧИМ звіряти, і блок мовчки не працював би. Мовчазна непрацездатність
гірша за відмову.
"""
import sys, yaml

ALLOWED_STATE = {"watched", "unwatched"}
ALLOWED_SURFACE = {"canvas-artifact", "claude-design", "code"}
ALLOWED_FIGMA_KEYS = {"file_key", "node_id", "rendered_from"}

def main(path):
    # try/except — той самий клас, що Critical 3 у validate-items.sh: гейт, що
    # падає traceback'ом, не друкує ЖОДНОГО рядка `ERROR:`, а споживач (крок 2
    # strw-design-sync) саме їх і читає.
    try:
        doc = yaml.safe_load(open(path)) or {}
    except Exception as e:
        print(f"ERROR: {path} не парситься: {e}", file=sys.stderr)
        return 1
    if not isinstance(doc, dict):
        print(f"ERROR: {path}: корінь не мапа, а {type(doc).__name__}",
              file=sys.stderr)
        return 1
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

        figma = u.get("figma")
        if figma is not None:
            if not isinstance(figma, dict):
                errors.append(f"{where}: figma має бути мапою")
            else:
                unknown = sorted(set(figma) - ALLOWED_FIGMA_KEYS)
                if unknown:
                    errors.append(f"{where}: figma містить невідомі ключі: "
                                  f"{', '.join(unknown)} — друкарська помилка тут не мала б "
                                  f"проходити тихо")
                if not figma.get("file_key"):
                    errors.append(f"{where}: figma.file_key обов'язковий і непорожній")
                rendered_from = figma.get("rendered_from")
                if not rendered_from or not str(rendered_from).startswith("sha256:"):
                    errors.append(f"{where}: figma.rendered_from обов'язковий і мусить "
                                  f"починатись із sha256:")
            if state == "unwatched":
                errors.append(f"{where}: figma на unwatched-одиниці — помилка: за "
                              f"unwatched хеш не рахується, rendered_from буде НІ З ЧИМ "
                              f"звіряти, і блок мовчки не працював би")

    for e in errors:
        print(f"ERROR: {e}", file=sys.stderr)
    return 1 if errors else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
