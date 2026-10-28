#!/usr/bin/env bash
# tool-select.sh — який інструмент реєстру взяти під (тип задачі, роль, контур) — ранжований
# список із причинами (елемент factory.tool-select, слова CEO 28.10: «фабрика підбирає
# найоптимальніші інструменти для тої чи іншої задачі»). Детермінований механізм замість
# «я пам'ятаю, що codex є»: реєстр — strw-state/engine/tools.yaml (схема v1), доступність —
# та сама проба, що tool-probe.sh (lib/tool_registry.py).
#
#   tool-select.sh <engine-dir> <тип-задачі> <роль> <контур> [--loop <петля>] [--kind <вид>]
#
# Роль — vocab.session_roles (hub|master|child) або `name:` із закритого frontmatter agents/**/*.md плагіна;
# петля — `id:` паспорта loops/*.md плагіна; вид — vocab.kinds (L3 6a: `--kind cli` — зовнішній рев'юер
# окремим процесом, а не внутрішній агент тієї ж задачі code-review-6a).
# Відбір: тип задачі ∈ tasks · [kind = вид] · роль ∈ roles ([] = будь-яка) · контур ∈ contours · петля ∈ loops
# ([] = будь-яка; запис із петлями без --loop не пропонується). forbidden НІКОЛИ не в списку
# (лише рядок «відкинуто» в stderr). Кожного відібраного проба міряє один раз.
# Порядок: доступні вище недоступних · active вище candidate · менший rank · id.
# «Обрано» — перший active І доступний; candidate не обирається ніколи (не ввімкнено), лише видно.
#
# ВИХІД. stdout: рядок 1 — вердикт, далі нумерований список «N. <id> · <позначка> · <status> ·
# rank R · <проба> · cost · user_data»; stderr — відкинуті з причиною. Коди:
#   обрано: <id> (<назва>) · задача … · rank R · <проба>                          → 0
#   немає доступного: N кандидат(ів) · …: <id> — <стан>; …                          → 3
#   немає інструмента в реєстрі: задача … · роль … · контур …                       → 4
# «Не поміряти» → 2, stdout порожній: невідомий тип задачі, роль, контур, петля чи вид (не порожній
# успіх), немає/зламаний реєстр, lanes-tool на неіснуючий ключ, немає читача.
# Оточення — як у tool-probe.sh; плюс STRW_AGENTS_DIR і STRW_LOOPS_DIR (типово agents/ і loops/ цього плагіна).
set -uo pipefail
usage() { echo "tool-select: tool-select.sh <engine-dir> <тип-задачі> <роль> <контур> [--loop <петля>] [--kind <вид>] (код 2)" >&2; exit 2; }
[ $# -ge 4 ] || usage
ENGINE="$1"; TASK="$2"; ROLE="$3"; CONTOUR="$4"; shift 4
LOOP=""; KIND=""; SEEN=""
while [ $# -gt 0 ]; do   # кожна опція — не більше разу, зі значенням
  case "$1" in --loop|--kind) ;; *) usage ;; esac
  [ $# -ge 2 ] && [ -n "$2" ] || usage
  case " ${SEEN} " in *" $1 "*) usage ;; esac
  SEEN="${SEEN} $1"
  if [ "$1" = "--loop" ]; then LOOP="$2"; else KIND="$2"; fi
  shift 2
done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -d "${ENGINE}" ] || { echo "tool-select: немає ${ENGINE} (код 2)" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "tool-select: немає python3 (код 2)" >&2; exit 2; }
ENGINE_LIB=""
for c in "${STRW_ENGINE_LIB:-}" "${HERE}/lib" "${STRW_ROOT:-$HOME/Developer/STRW}/strw-factory/scripts/engine/lib"; do   # явна змінна → поруч → парасолька
  [ -n "$c" ] && [ -f "$c/yaml_nodup.py" ] && [ -f "$c/tool_registry.py" ] && { ENGINE_LIB="$c"; break; }
done
[ -n "$ENGINE_LIB" ] || { echo "tool-select: немає lib/yaml_nodup.py і lib/tool_registry.py — читач реєстру (ні поруч, ні STRW_ENGINE_LIB, ні STRW_ROOT/strw-factory); не поміряти (код 2)" >&2; exit 2; }
[ -f "${HERE}/repo-dir.sh" ] || { echo "tool-select: немає repo-dir.sh поруч — cwd проби не резолвити (код 2)" >&2; exit 2; }
. "${HERE}/repo-dir.sh"
REPO_DIRS="$(strw_repo_dirs "${STRW_ROOT:-$HOME/Developer/STRW}")" || { echo "tool-select: словник репо не резолвиться (код 2)" >&2; exit 2; }
AGENTS="${STRW_AGENTS_DIR:-${HERE}/../../agents}"
LOOPS="${STRW_LOOPS_DIR:-${HERE}/../../loops}"
STRW_ENGINE_LIB="$ENGINE_LIB" REPO_DIRS="$REPO_DIRS" AGENTS="$AGENTS" LOOPS="$LOOPS" python3 - "${ENGINE}" "${TASK}" "${ROLE}" "${CONTOUR}" "${LOOP}" "${KIND}" <<'PY'
import datetime, os, sys
def die(msg):
    print(f"tool-select: {msg} (код 2)", file=sys.stderr); sys.exit(2)
try:
    sys.path.insert(0, os.environ["STRW_ENGINE_LIB"])
    from yaml_nodup import load_nodup
    import tool_registry as tr
except ImportError as e:
    die(f"немає читача: {e}")
try:
    engine, task, role, contour, loop, kind = sys.argv[1:7]
    now = tr.parse_at(os.environ["STRW_TOOLS_NOW"], "STRW_TOOLS_NOW") if os.environ.get("STRW_TOOLS_NOW") \
        else datetime.datetime.now(datetime.timezone.utc)
    dirs = dict(l.split("=", 1) for l in os.environ["REPO_DIRS"].splitlines() if "=" in l)
    doc = tr.load(engine, load_nodup)
    p = tr.Prober(engine, dirs, float(os.environ.get("TOOL_PROBE_TIMEOUT", "10")), now,
                  int(os.environ.get("TOOL_MEASURED_MAX_AGE_DAYS", "14")), load_nodup)
    rc, out, diag = tr.select(doc, task, role, contour, loop or None, kind or None,
                              tr.agent_names(os.environ["AGENTS"]), tr.loop_ids(os.environ["LOOPS"]), p)
except tr.RegistryError as e:
    die(str(e))
except Exception as e:   # необроблений збій — «не поміряти», не 1 і не 0
    die(f"необроблений збій: {type(e).__name__}: {e}")
for l in diag:
    print(l, file=sys.stderr)
print("\n".join(out))
sys.exit(rc)
PY
