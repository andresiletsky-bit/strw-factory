# -*- coding: utf-8 -*-
"""YAML без дублікатів ключів — один читач для всіх читачів реєстру.

yaml.safe_load бере ОСТАННЄ значення дубльованого ключа мовчки (tri-094:
deck-content мав два `attempts:`, реєстр читав 0). validate-items.sh це ловить
з 11.09 (strw-factory #27), але toolchain-filter.sh, bin/strw-run.sh і
design-emit.py читали ті самі файли через safe_load — «другий контур», названий
у enforcement.yaml (registry.no-duplicate-yaml-keys, note). Цей модуль — щоб
читач був один, і дубль не доживав ані до фільтра в контурі C, ані до раннера.

Правила:
  · merge-ключ `<<` — валідний YAML: пропускаємо його тут, розгортає super()
    через flatten_mapping (конструювати його самим — брехливе «не парситься»);
  · ключі порівнюються разом із типом: `1` і `true` — різні ключі YAML
    (hash(1) == hash(True) у Python);
  · нехешований ключ → ConstructorError з міткою, не сирий TypeError;
  · повідомлення називає ключ і ОБИДВА рядки (1-based).
"""
import yaml

MERGE_TAG = "tag:yaml.org,2002:merge"


class NoDupLoader(yaml.SafeLoader):
    def construct_mapping(self, node, deep=False):
        seen = {}
        for k_node, _ in node.value:
            if k_node.tag == MERGE_TAG:
                continue
            k = self.construct_object(k_node, deep=deep)
            try:
                key = (type(k), k)
                hash(key)
            except TypeError:
                raise yaml.constructor.ConstructorError(
                    "while constructing a mapping", node.start_mark,
                    "found unhashable key (%s)" % type(k).__name__, k_node.start_mark)
            if key in seen:
                raise yaml.YAMLError(
                    "дубльований ключ `%s` (рядки %d і %d) — YAML узяв би останній мовчки (tri-094)"
                    % (k, seen[key], k_node.start_mark.line + 1))
            seen[key] = k_node.start_mark.line + 1
        return super().construct_mapping(node, deep=deep)


def load_nodup(stream):
    """Як yaml.safe_load, але дубль ключа — помилка, не тихий вибір."""
    return yaml.load(stream, Loader=NoDupLoader)
