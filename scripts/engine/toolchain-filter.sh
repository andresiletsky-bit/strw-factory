#!/usr/bin/env bash
# toolchain-filter.sh — Step 3a паспорта strw-loop-run: що вміє ЦЕЙ контур і які
# елементи `ready` тут здійсненні. Детермінований механізм замість прози
# (dec-095 §2, tri-053; елемент factory.item-requires-field).
#
#   toolchain-filter.sh <engine-dir>
#
# ЩО МІРЯЄТЬСЯ, НЕ ПРИПУСКАЄТЬСЯ. Кожен інструмент — probe з `lanes.yaml tools:`,
# виконаний тут і зараз, один раз на інструмент, з таймаутом. КОНТРАКТ PROBE:
# він мусить ВИКОНАТИ інструмент (`swiftc -version`, `xcodebuild -version`), а
# не лише знайти його в PATH: на Mac без Xcode `/usr/bin/swiftc` і `/usr/bin/xcrun`
# — шими xcode-select, `command -v` дає 0, а виклик падає. Код 0 = інструмент є.
# Елемент здійсненний, якщо доступні ВСІ ресурси його смуги (`resources:`) І
# кожен інструмент із його власного `requires:`. Смуга каже, що треба будь-якому
# елементу в ній; `requires:` звужує окремий елемент (tri-053: гейт фікстур
# називав swiftc в acceptance, а смуга ios-tooling мала `resources: []`).
#
# ВИХІД. stdout — РІВНО ОДИН рядок вердикту; уся діагностика (виміри інструментів,
# по-елементні рядки) — stderr. Три слова вердикту не склеюються:
#   взято: <id> · смуга <lane> · підтверджено: a, b · здійсненних: N із M [· чекають: x×k]   → 0
#   немає інструмента: N елемент(ів) чекають: swiftc×2                                   → 3
#   немає роботи                                                                            → 4
# «Не поміряти» → 2, НІКОЛИ 0/3/4: немає engine/items/, немає `tools:` при непорожніх
# потребах, інструмент поза словником (названо елементи-винуватці — один такий
# зупиняє всю чергу, це навмисно: fail-closed), смуга елемента не оголошена або
# без ключа `resources`, probe завис (таймаут) або не запустився, будь-який
# необроблений збій. «Взято» — перший здійсненний за id; це замовчування, а не
# пріоритет: порядок черги — Step 3a п.3 паспорта.
set -uo pipefail
ENGINE="${1:?вкажи engine-dir (strw-state/engine)}"
[ -d "$ENGINE" ] || { echo "toolchain-filter: немає $ENGINE (код 2)" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "toolchain-filter: немає python3 (код 2)" >&2; exit 2; }
PROBE_TIMEOUT="${TOOLCHAIN_PROBE_TIMEOUT:-10}"   # секунд на один probe; таймаут = «не поміряти»

python3 - "$ENGINE" "$PROBE_TIMEOUT" <<'PY'
import glob, os, subprocess, sys

def die(msg, code=2):
    print(f"toolchain-filter: {msg} (код {code})", file=sys.stderr); sys.exit(code)

def main():
    try:
        import yaml
    except ImportError:
        die("немає pyyaml — lanes.yaml не прочитати")
    engine, timeout = sys.argv[1], float(sys.argv[2])
    lanes_path = os.path.join(engine, "lanes.yaml")
    items_dir = os.path.join(engine, "items")
    if not os.path.isfile(lanes_path):
        die(f"немає {lanes_path}")
    if not os.path.isdir(items_dir):
        die(f"немає {items_dir} — це «нічим міряти», не «немає роботи»")
    doc = yaml.safe_load(open(lanes_path, encoding="utf-8")) or {}
    tools = doc.get("tools")
    if tools is not None and not isinstance(tools, dict):
        die("lanes.yaml: `tools:` має бути мапою")
    tools = tools or {}
    lanes = {}
    for l in (doc.get("lanes") or []):
        if isinstance(l, dict) and l.get("id"):
            lanes[l["id"]] = l

    items = []
    for p in sorted(glob.glob(os.path.join(items_dir, "*.yaml"))):
        try:
            it = yaml.safe_load(open(p, encoding="utf-8")) or {}
        except Exception as e:
            die(f"{os.path.basename(p)} не парситься: {e}")
        if it.get("state") != "ready" or it.get("blocked_by"):
            continue
        items.append(it)
    if not items:
        print("немає роботи"); sys.exit(4)

    # Потреби кожного елемента — з явними відмовами, не з мовчазних замовчувань.
    plan = []          # (id, lane, needs)
    bad_lane, bad_tools = [], {}
    for it in items:
        iid = it.get("id", "?"); lid = it.get("lane")
        lane = lanes.get(lid)
        if lane is None:
            bad_lane.append(f"{iid} (lane: {lid!r} не оголошена)"); continue
        if "resources" not in lane or not isinstance(lane.get("resources"), list):
            bad_lane.append(f"{iid} (смуга {lid}: немає списку `resources` — це не «нічого не треба»)"); continue
        req = it.get("requires") or []
        if not isinstance(req, list) or not all(isinstance(x, str) for x in req):
            bad_lane.append(f"{iid} (`requires` не список рядків)"); continue
        needs = []
        for t in list(lane["resources"]) + list(req):
            if t not in needs:
                needs.append(t)
        for t in needs:
            if not isinstance(tools.get(t), dict) or not str(tools[t].get("probe", "")).strip():
                bad_tools.setdefault(t, []).append(iid)
        plan.append((iid, lid, needs))
    if bad_lane:
        die("елементи з неоголошеною смугою/формою: " + "; ".join(bad_lane))
    if bad_tools:
        if not tools:
            die("у lanes.yaml немає словника `tools:`, а елементи потребують інструментів: "
                + "; ".join(f"{t} ← {', '.join(ids)}" for t, ids in sorted(bad_tools.items())))
        die("інструменти поза словником tools: (fail-closed, зупиняє всю чергу): "
            + "; ".join(f"{t} ← {', '.join(ids)}" for t, ids in sorted(bad_tools.items())))

    # Вимір — один раз на інструмент; stdin закритий; таймаут = не поміряти.
    measured = {}
    def have(tool):
        if tool in measured:
            return measured[tool]
        probe = tools[tool]["probe"]
        try:
            rc = subprocess.run(["bash", "-c", probe], stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            die(f"probe інструмента '{tool}' не завершився за {timeout:g} с — не поміряти")
        except OSError as e:
            die(f"probe інструмента '{tool}' не запустився: {e}")
        measured[tool] = (rc == 0)
        print(f"tool {tool}: {'ok' if measured[tool] else 'missing'} ({probe})", file=sys.stderr)
        return measured[tool]

    feasible, waiting = [], {}
    for iid, lid, needs in plan:
        missing = [t for t in needs if not have(t)]
        if missing:
            print(f"waits {iid} ← {', '.join(missing)}", file=sys.stderr)
            for t in missing:
                waiting[t] = waiting.get(t, 0) + 1
        else:
            print(f"feasible {iid} ({lid}; підтверджено: {', '.join(needs) or 'нічого не треба'})", file=sys.stderr)
            feasible.append((iid, lid, needs))
    tally = ", ".join(f"{t}×{n}" for t, n in sorted(waiting.items(), key=lambda x: (-x[1], x[0])))
    if feasible:
        iid, lid, needs = feasible[0]
        tail = f" · чекають: {tally}" if tally else ""
        print(f"взято: {iid} · смуга {lid} · підтверджено: {', '.join(needs) or 'нічого не треба'} · здійсненних: {len(feasible)} із {len(plan)}{tail}")
        sys.exit(0)
    print(f"немає інструмента: {len(plan)} елемент(ів) чекають: {tally}")
    sys.exit(3)

try:
    main()
except SystemExit:
    raise
except Exception as e:   # будь-який необроблений збій — «не поміряти», не 1 і не 0
    die(f"необроблений збій: {type(e).__name__}: {e}")
PY
