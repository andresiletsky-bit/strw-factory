#!/usr/bin/env bash
# toolchain-filter.sh — Step 3a паспорта strw-loop-run: що вміє ЦЕЙ контур і які
# елементи `ready` тут здійсненні. Детермінований механізм замість прози
# (dec-095 §2, tri-053; елемент factory.item-requires-field).
#
#   toolchain-filter.sh <engine-dir>
#
# ЩО МІРЯЄТЬСЯ, НЕ ПРИПУСКАЄТЬСЯ. Кожен інструмент — probe з `lanes.yaml tools:`
# (`command -v …`, код 0 = є), виміряний тут і зараз, один раз на інструмент.
# Елемент здійсненний, якщо доступні ВСІ ресурси його смуги (`resources:`) І
# кожен інструмент із його власного `requires:`. Смуга каже, що треба будь-якому
# елементу в ній; `requires:` звужує окремий елемент (tri-053: гейт фікстур
# називав swiftc в acceptance, а смуга ios-tooling мала `resources: []` — фільтр
# читав прозу і брав елемент у контур без компілятора).
#
# ВИХІД — три слова, які не склеюються (паспорт, Step 3a п.4):
#   взято: <id> · смуга <lane> · підтверджено: a, b     → код 0
#   немає інструмента: N елемент(ів) чекають: swiftc×2  → код 3
#   немає роботи                                          → код 4
# Не поміряти (немає engine/lanes.yaml/tools:, покручена форма) → код 2, не 4:
# «нічого не здійсненне» і «нічим міряти» — різні речі.
set -uo pipefail
ENGINE="${1:?вкажи engine-dir (strw-state/engine)}"
[ -d "$ENGINE" ] || { echo "toolchain-filter: немає $ENGINE (код 2)" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "toolchain-filter: немає python3 (код 2)" >&2; exit 2; }

python3 - "$ENGINE" <<'PY'
import glob, os, subprocess, sys
try:
    import yaml
except ImportError:
    print("toolchain-filter: немає pyyaml — lanes.yaml не прочитати (код 2)", file=sys.stderr); sys.exit(2)

engine = sys.argv[1]
lanes_path = os.path.join(engine, "lanes.yaml")
if not os.path.isfile(lanes_path):
    print(f"toolchain-filter: немає {lanes_path} (код 2)", file=sys.stderr); sys.exit(2)
doc = yaml.safe_load(open(lanes_path, encoding="utf-8")) or {}
tools = doc.get("tools")
if not isinstance(tools, dict) or not tools:
    print("toolchain-filter: у lanes.yaml немає словника `tools:` — інструменти нічим міряти (код 2)", file=sys.stderr); sys.exit(2)
lanes = {l.get("id"): l for l in (doc.get("lanes") or []) if isinstance(l, dict) and l.get("id")}

# Вимір — один раз на інструмент, у тому самому оточенні (PATH), що й цей процес.
measured = {}
def have(tool):
    if tool not in measured:
        spec = tools.get(tool)
        probe = spec.get("probe") if isinstance(spec, dict) else None
        if not probe:
            measured[tool] = None            # у словнику немає — не «немає», а «не поміряти»
        else:
            rc = subprocess.run(["bash", "-c", probe], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
            measured[tool] = (rc == 0)
    return measured[tool]

items = []
for p in sorted(glob.glob(os.path.join(engine, "items", "*.yaml"))):
    try:
        it = yaml.safe_load(open(p, encoding="utf-8")) or {}
    except Exception as e:
        print(f"toolchain-filter: {os.path.basename(p)} не парситься: {e} (код 2)", file=sys.stderr); sys.exit(2)
    if it.get("state") != "ready" or it.get("blocked_by"):
        continue
    items.append(it)

if not items:
    print("немає роботи"); sys.exit(4)

feasible, waiting = [], {}
unmeasurable = set()
for it in items:
    iid = it.get("id", "?"); lane = lanes.get(it.get("lane"), {})
    needs = list(lane.get("resources") or []) + list(it.get("requires") or [])
    missing = []
    for t in needs:
        h = have(t)
        if h is None:
            unmeasurable.add(t)
        elif not h:
            missing.append(t)
    for t in needs:
        print(f"tool {t}: {'ok' if have(t) else ('НЕ В СЛОВНИКУ' if have(t) is None else 'missing')}")
    if unmeasurable & set(needs):
        continue
    if missing:
        print(f"waits {iid} ← {', '.join(missing)}")
        for t in missing:
            waiting[t] = waiting.get(t, 0) + 1
    else:
        print(f"feasible {iid} ({it.get('lane')}; підтверджено: {', '.join(needs) or 'нічого не треба'})")
        feasible.append((iid, it.get("lane"), needs))

if unmeasurable:
    print(f"toolchain-filter: інструмент(и) поза словником tools: {', '.join(sorted(unmeasurable))} — не поміряти (код 2)", file=sys.stderr)
    sys.exit(2)
if feasible:
    iid, lane, needs = feasible[0]
    print(f"взято: {iid} · смуга {lane} · підтверджено: {', '.join(needs) or 'нічого не треба'} · здійсненних: {len(feasible)} із {len(items)}")
    sys.exit(0)
tally = ", ".join(f"{t}×{n}" for t, n in sorted(waiting.items(), key=lambda x: -x[1]))
print(f"немає інструмента: {len(items)} елемент(ів) чекають: {tally}")
sys.exit(3)
PY
