#!/usr/bin/env bash
# autonomy-route.sh — режим елемента реєстру: A (без людини) чи B (з CEO). БЕЗ моделі.
# Специфікація: strw-ops reports/2026-10-20-hybrid-autonomy-spec.md §2 (правило вибору) і
# §3 («готовність до A»); правило 11 паспорта L3; пояснення — references/autonomy-modes.md.
#
# Usage: bash autonomy-route.sh <item-file> [--engine-dir D] [--state-dir S]
#        bash autonomy-route.sh --plan-sha <item-file>   # версія поточного plan для plan_review.sha
#   --engine-dir — тека реєстру (strw-state/engine); за замовчуванням — батько теки items/,
#                  де лежить елемент, інакше $STRW_ROOT/strw-state/engine.
#   --state-dir  — корінь strw-state (products/, decisions/, triage/); за замовчуванням — батько engine-dir.
#
# Вихід — РІВНО ОДИН рядок у stdout (його читає раннер strw-ops bin/strw-run.sh):
#   unattended                 rc 0 — усі умови §2 і §3 виконані
#   with-ceo: <перша причина>  rc 1 — простими словами, яка умова перевела елемент у B
#   не поміряно: <що саме>     rc 2 — немає файла, читача або стадії продукту: це НЕ «B», це
#                                     «інструмент сліпий», і раннер мусить зупинитись, а не гадати
# Порядок умов фіксований (перша, що не виконана, — і є причина): autonomy · форма полів ·
# стадія · розмір · touches · blocked_by/ceo · відкрита картка тріажу · свіжість підстави ·
# готовність §3 · «великий» за 6a (за plan.files — тому після готовності, де plan уже є).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRW_ROOT="${STRW_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

unmeasured() { printf 'не поміряно: %s\n' "$1"; exit 2; }

ITEM=""; ENGINE_DIR=""; STATE_DIR=""; MODE=route
while [ "$#" -gt 0 ]; do
  case "$1" in
    --engine-dir) [ "$#" -ge 2 ] || unmeasured "--engine-dir без значення"; ENGINE_DIR="$2"; shift 2 ;;
    --state-dir)  [ "$#" -ge 2 ] || unmeasured "--state-dir без значення"; STATE_DIR="$2"; shift 2 ;;
    --plan-sha)   MODE=plan-sha; shift ;;
    -h|--help)    sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           unmeasured "невідомий ключ $1" ;;
    *)            [ -z "${ITEM}" ] || unmeasured "зайвий аргумент $1 (елемент один)"; ITEM="$1"; shift ;;
  esac
done
[ -n "${ITEM}" ] || unmeasured "не вказано файл елемента (usage: autonomy-route.sh <item-file>)"
[ -f "${ITEM}" ] || unmeasured "немає файла елемента ${ITEM}"
ITEM="$(cd "$(dirname "${ITEM}")" && pwd)/$(basename "${ITEM}")"

if [ -z "${ENGINE_DIR}" ]; then
  if [ "$(basename "$(dirname "${ITEM}")")" = items ]; then ENGINE_DIR="$(dirname "$(dirname "${ITEM}")")"
  else ENGINE_DIR="${STRW_ROOT}/strw-state/engine"; fi
fi
[ -n "${STATE_DIR}" ] || STATE_DIR="$(cd "${ENGINE_DIR}/.." 2>/dev/null && pwd)"
[ -n "${STATE_DIR}" ] && [ -d "${STATE_DIR}" ] || unmeasured "немає теки стану (engine-dir ${ENGINE_DIR})"

command -v python3 >/dev/null 2>&1 || unmeasured "немає python3"
# Читач — та сама повна lib/, що у validate-items.sh: поруч → STRW_ENGINE_LIB → парасолька.
ENGINE_LIB=""
for c in "${STRW_ENGINE_LIB:-}" "${SCRIPT_DIR}/lib" "${STRW_ROOT}/strw-factory/scripts/engine/lib"; do
  [ -n "$c" ] && [ -f "$c/yaml_nodup.py" ] && [ -f "$c/decisions_basis.py" ] && [ -f "$c/item_fields.py" ] && { ENGINE_LIB="$c"; break; }
done
[ -n "${ENGINE_LIB}" ] || unmeasured "немає повної lib/ (yaml_nodup.py · decisions_basis.py · item_fields.py) — ні поруч, ні в STRW_ENGINE_LIB, ні в ${STRW_ROOT}/strw-factory"

# Вихід python — ОДИН рядок; код — його. Трейсбек замість рядка — теж «не поміряно» (нижче).
OUT="$(STRW_ENGINE_LIB="${ENGINE_LIB}" python3 - "${MODE}" "${ITEM}" "${STATE_DIR}" <<'PY' 2>&1
import os, re, sys, fnmatch
mode, item_path, state_dir = sys.argv[1:4]
sys.path.insert(0, os.environ["STRW_ENGINE_LIB"])
try:
    import yaml  # noqa: F401  (yaml_nodup на ньому)
    from yaml_nodup import load_nodup
    from decisions_basis import load_decisions, freshness
    from item_fields import form_errors, readiness_gaps, plan_sha, TOUCHES
except ImportError as e:
    print(f"не поміряно: читач не імпортується ({e})"); sys.exit(2)

def b(reason):   print(f"with-ceo: {reason}"); sys.exit(1)
def na(reason):  print(f"не поміряно: {reason}"); sys.exit(2)

try:
    it = load_nodup(open(item_path, encoding="utf-8"))
except Exception as e:
    na(f"елемент не читається: {' '.join(str(e).split())}")
if not isinstance(it, dict):
    na(f"елемент — не мапа, а {type(it).__name__}")

if mode == "plan-sha":
    if it.get("plan") is None:
        na("в елементі немає plan — версії нема з чого рахувати")
    print(plan_sha(it["plan"])); sys.exit(0)

# 0. Режим заявлено. Поля немає = with-ceo (спека §1); з B в A — лише заявою + цим скриптом.
if it.get("autonomy") == "with-ceo":
    b("елемент переведено в режим з CEO вручну (autonomy: with-ceo)")
if it.get("autonomy") is None:
    b("елемент не позначено autonomy: unattended (без позначки — з CEO)")
if it.get("autonomy") != "unattended":
    b(f"autonomy = {it.get('autonomy')!r} — невідоме значення")

# 1. Форма полів — та сама, що у validate-items.sh. Покручене поле не читається як «порожнє».
fe = form_errors(it)
if fe:
    b(f"поле елемента покручене: {fe[0]}")

# 2. Фаза продукту — 5-Build (§2.1). Елементи фабрики — без стадії.
product = it.get("product")
if product != "factory":
    if not product:
        na("в елементі немає product — стадію нема де шукати")
    sp = os.path.join(state_dir, "products", str(product), "state.md")
    if not os.path.isfile(sp):
        na(f"немає {sp} — стадія продукту невідома")
    head = []
    with open(sp, encoding="utf-8") as f:
        first = f.readline()
        if first.strip() == "---":
            for line in f:
                if line.strip() == "---":
                    break
                head.append(line)
    try:
        fm = load_nodup("".join(head)) if head else None
    except Exception as e:
        na(f"frontmatter {sp} не читається: {' '.join(str(e).split())}")
    stage = fm.get("stage") if isinstance(fm, dict) else None
    if not stage:
        na(f"у {sp} немає поля stage — стадія продукту невідома")
    if str(stage).strip().lower() != "5-build":
        b(f"стадія продукту {stage} — без людини працюємо лише у 5-Build (рішення, реліз і ріст — з CEO)")

# 3. Складність (§2.2).
size = it.get("size")
if size not in ("S", "M"):
    b("розмір L — завжди з CEO" if size == "L" else
      ("розмір не вказано" if size is None else f"розмір {size!r}") + " — режим A лише для S або M")

# 4. Принцип 5 (§2.4): гроші, реліз, прод, видалення даних, треті сторони, приватність, обсяг віхи.
touches = it.get("touches") or []
if touches:
    b(f"торкається того, що вирішує CEO: {', '.join(str(x) for x in touches)}")

# 5. Відкрите питання (§2.5): blocked_by, рішення CEO, картка тріажу, протухла підстава.
blocked = it.get("blocked_by") or []
ceo = [str(x) for x in blocked if str(x).startswith("ceo:")]
if ceo:
    b(f"чекає рішення CEO ({ceo[0]})")
if blocked:
    b(f"заблоковано іншим ({blocked[0]})")
iid = str(it.get("id") or "")
open_dir = os.path.join(state_dir, "triage", "open")
if not os.path.isdir(open_dir):
    na(f"немає {open_dir} — відкриті картки тріажу не перевірити")
if iid:
    # Межі слова — щоб `factory.x` не збігався з `factory.x-two`.
    rx = re.compile(r"(?<![\w.-])" + re.escape(iid) + r"(?![\w-])")
    for fn in sorted(os.listdir(open_dir)):
        if fn.endswith(".md"):
            with open(os.path.join(open_dir, fn), encoding="utf-8") as f:
                if rx.search(f.read()):
                    b(f"на елемент посилається відкрита картка тріажу {fn}")
ab = it.get("acceptance_basis")
ver = ab.get("verified_against_decisions_log_at") if isinstance(ab, dict) else None
if not ver or not re.match(r"^\d{4}-\d{2}-\d{2}$", str(ver)[:10]):
    b("acceptance_basis не звірено з журналом рішень (немає дати звірки)")
dec = load_decisions(os.path.join(state_dir, "decisions-log.md"), load_nodup)
if not dec["found"]:
    na(dec["errors"][0])
kind, detail = freshness(it, dec)
if kind == "stale-count":
    b(f"підстава застаріла: після звірки дописано {len(detail[2])} рішень, що стосуються елемента")
if kind == "stale-date":
    b(f"підстава застаріла: у журналі є новіші рішення ({detail[1][-1]})")
if kind in ("vanished", "bad-counter"):
    b("лічильник звірки з журналом рішень неправдивий (decisions_log_entries)")

# 6. Готовність §3 — та сама функція, що у validate-items.sh.
gaps = readiness_gaps(it)
if gaps:
    b(gaps[0])

# 7. «Великий» за 6a — за plan.files (§2.3). Маска чи тека в плані — не перелік: що під нею, не
# видно, а plan_drift раннера розгорне її на будь-що (fnmatch) — тож «не великий» не доведено.
SENSITIVE = [
    ("контракт", lambda p, s, n: "contract" in s),
    ("міграцію бази даних", lambda p, s, n: "migrations" in s or "migration" in s),
    ("крипто або ключі", lambda p, s, n: re.search(r"crypto|keychain|key[-_]?exchange|space[-_]?key|secret", p)),
    ("вимірювальний інструмент (гейт, чек, хук, CI)", lambda p, s, n: (
        fnmatch.fnmatch(n, "*-check.sh") or fnmatch.fnmatch(n, "*-guard.sh")
        or fnmatch.fnmatch(n, "gates*.json") or fnmatch.fnmatch(n, "validate-*")
        or n in ("dep-allowlist.txt", "autonomy-route.sh", "strw-run.sh")
        or p.startswith((".claude/hooks/", "hooks/", ".githooks/", ".github/workflows/", "scripts/engine/lib/"))
        or fnmatch.fnmatch(p, ".claude/settings*.json"))),
]
files = it["plan"]["files"]
for raw in files:
    f = str(raw).strip()
    p = (f[2:] if f.startswith("./") else f).lower()
    segs = set(p.split("/")[:-1])
    name = p.rsplit("/", 1)[-1]
    for label, hit in SENSITIVE:
        if hit(p, segs, name):
            b(f"великий за правилом 6a: план чіпає {label} ({f})")
    if re.search(r"[*?\[]", f) or f.endswith("/") or "." not in name:
        b(f"plan.files містить маску або теку ({f}) — для режиму A потрібен перелік файлів")
if len(files) > 15:
    b(f"великий за правилом 6a: у плані {len(files)} файлів (межа 15)")

print("unattended"); sys.exit(0)
PY
)"
RC=$?
LINES="$(printf '%s\n' "${OUT}" | /usr/bin/grep -c .)"
# Контракт — один рядок і код 0/1/2. Трейсбек чи інший код — сліпий інструмент, не «B».
if [ "${RC}" -gt 2 ] || [ "${LINES}" -ne 1 ]; then
  printf 'не поміряно: маршрутизатор упав (rc=%s): %s\n' "${RC}" "$(printf '%s' "${OUT}" | tail -1)"
  exit 2
fi
printf '%s\n' "${OUT}"
exit "${RC}"
