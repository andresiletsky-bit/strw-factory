#!/usr/bin/env bash
# tool-probe.sh — чи доступний інструмент реєстру ТУТ І ЗАРАЗ (елемент factory.tool-select,
# слова CEO 28.10: «фабрика підбирає найоптимальніші інструменти»). Запис —
# strw-state/engine/tools.yaml (схема v1, шапка файлу); логіка — lib/tool_registry.py, та сама,
# що в tool-select.sh, щоб «доступний» означало одне.
#
#   tool-probe.sh <engine-dir> <tool-id>
#
# Форми проби: shell (cmd у теці cwd, код 0 = доступний) · lanes-tool (проба з lanes.yaml tools,
# як у toolchain-filter) · session (з shell НЕ міряється — читається measured; протух → не доступний).
# stdout — РІВНО ОДИН рядок «<id> · <стан> · <деталь>», стан ∈ available | unavailable | needs-auth |
# stale | timeout. Коди: 0 available · 3 будь-який інший стан · 2 «не поміряти» (немає реєстру чи
# запису, зламане поле, lanes-tool на неіснуючий ключ, немає читача YAML) — причина в stderr.
# Оточення: TOOL_PROBE_TIMEOUT (с, типово 10) · TOOL_MEASURED_MAX_AGE_DAYS (типово 14) ·
# STRW_TOOLS_NOW (ISO, для проб) · STRW_ROOT (корінь репо для cwd, типово ~/Developer/STRW).
set -uo pipefail
[ $# -eq 2 ] || { echo "tool-probe: tool-probe.sh <engine-dir> <tool-id> (код 2)" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -d "$1" ] || { echo "tool-probe: немає $1 (код 2)" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "tool-probe: немає python3 (код 2)" >&2; exit 2; }
ENGINE_LIB=""
for c in "${STRW_ENGINE_LIB:-}" "${HERE}/lib" "${STRW_ROOT:-$HOME/Developer/STRW}/strw-factory/scripts/engine/lib"; do   # явна змінна → поруч → парасолька
  [ -n "$c" ] && [ -f "$c/yaml_nodup.py" ] && [ -f "$c/tool_registry.py" ] && { ENGINE_LIB="$c"; break; }
done
[ -n "$ENGINE_LIB" ] || { echo "tool-probe: немає lib/yaml_nodup.py і lib/tool_registry.py — читач реєстру (ні поруч, ні STRW_ENGINE_LIB, ні STRW_ROOT/strw-factory); не поміряти (код 2)" >&2; exit 2; }
[ -f "${HERE}/repo-dir.sh" ] || { echo "tool-probe: немає repo-dir.sh поруч — cwd проби не резолвити (код 2)" >&2; exit 2; }
. "${HERE}/repo-dir.sh"
REPO_DIRS="$(strw_repo_dirs "${STRW_ROOT:-$HOME/Developer/STRW}")" || { echo "tool-probe: словник репо не резолвиться (код 2)" >&2; exit 2; }
STRW_ENGINE_LIB="$ENGINE_LIB" REPO_DIRS="$REPO_DIRS" python3 - "$1" "$2" <<'PY'
import datetime, os, sys
def die(msg):
    print(f"tool-probe: {msg} (код 2)", file=sys.stderr); sys.exit(2)
try:
    sys.path.insert(0, os.environ["STRW_ENGINE_LIB"])
    from yaml_nodup import load_nodup
    import tool_registry as tr
except ImportError as e:
    die(f"немає читача: {e}")
try:
    engine, tid = sys.argv[1], sys.argv[2]
    now = tr.parse_at(os.environ["STRW_TOOLS_NOW"], "STRW_TOOLS_NOW") if os.environ.get("STRW_TOOLS_NOW") \
        else datetime.datetime.now(datetime.timezone.utc)
    dirs = dict(l.split("=", 1) for l in os.environ["REPO_DIRS"].splitlines() if "=" in l)
    doc = tr.load(engine, load_nodup)
    p = tr.Prober(engine, dirs, float(os.environ.get("TOOL_PROBE_TIMEOUT", "10")), now,
                  int(os.environ.get("TOOL_MEASURED_MAX_AGE_DAYS", "14")), load_nodup)
    st, det = p.probe(tr.find(doc, tid))
except tr.RegistryError as e:
    die(str(e))
except Exception as e:   # необроблений збій — «не поміряти», не 1 і не 0
    die(f"необроблений збій: {type(e).__name__}: {e}")
print(f"{tid} · {st} · {det}")
sys.exit(0 if st == "available" else 3)
PY
