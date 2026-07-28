#!/usr/bin/env -S deno run --allow-read --allow-write --allow-run --allow-env
// engine.ts — детерміноване ядро диспетчера. БЕЗ моделі.
//
// ЧОМУ ЯДРО — CLI, А НЕ САМ WORKFLOW-СКРИПТ.
// Workflow-скрипт (`tick.workflow.js`) виконується в пісочниці харнеса, де НЕМАЄ
// доступу ні до файлової системи, ні до Node/Deno API — він уміє лише оркеструвати
// агентів. Лізи, CAS, git і реконсиляція — це файлові й процесні операції, тож вони
// мусять жити в справжньому виконуваному файлі. Наслідок, потрібний саме цій сесії:
// цей процес можна ВБИТИ сигналом і подивитись, що лишилось на диску. Failure
// injection над оркестратором агентів такого доказу не дала б.
//
// Usage:
//   engine.ts preflight  --state <dir> [--factory <dir>]
//   engine.ts plan       --engine <dir> --repos <json> [--tick N] [--n N]
//   engine.ts claim      --repo <dir> --item <id> --run <id> [--tick N]
//   engine.ts heartbeat  --repo <dir> --item <id> --run <id> --epoch N
//   engine.ts reconcile  --engine <dir> --repos <json> [--item <id>] [--apply]
//   engine.ts settle     --engine <dir> --state <dir> --product <id> --cycle <id> [--tick N]

import { claim, heartbeat, isStale, type Lease, readLease, release } from "./lib/lease.ts";
import { parseItem, readItem, writeItemFields } from "./lib/items.ts";
import { reconcile, type World } from "./lib/reconcile.ts";
import { realWorld } from "./lib/world.ts";
import { preflight, runValidator } from "./lib/preflight.ts";
import { planTick } from "./lib/plan.ts";
import type { Lane, LaneMap } from "./lib/resources.ts";
import { cycleLine, isoWeekFile, renderEngineBlock, upsertBlock } from "./lib/settle.ts";

function arg(name: string, fallback?: string): string {
  const i = Deno.args.indexOf(`--${name}`);
  if (i >= 0 && i + 1 < Deno.args.length) return Deno.args[i + 1];
  if (fallback !== undefined) return fallback;
  throw new Error(`бракує обов'язкового аргументу --${name}`);
}

function flag(name: string): boolean {
  return Deno.args.includes(`--${name}`);
}

function out(obj: unknown): void {
  console.log(JSON.stringify(obj, null, 2));
}

// ── Читання реєстру ─────────────────────────────────────────────────────────────

interface LoadedRegistry {
  lanes: LaneMap;
  shared: string[];
  items: ReturnType<typeof parseItem>[];
  itemPaths: Record<string, string>;
}

function loadRegistry(engineDir: string): LoadedRegistry {
  const lanesText = Deno.readTextFileSync(`${engineDir}/lanes.yaml`);
  const lanes: LaneMap = {};
  const shared: string[] = [];

  // lanes.yaml має власну форму (список смуг), тож розбирається окремо від items.
  let cur: Lane | null = null;
  let section: "lanes" | "shared" | null = null;
  for (const raw of lanesText.split("\n")) {
    const line = raw.replace(/\s+#.*$/, "");
    if (/^lanes:/.test(line)) { section = "lanes"; continue; }
    if (/^shared:/.test(line)) { section = "shared"; cur = null; continue; }
    if (section === "shared") {
      const m = /^\s*-\s*"?([^"]+)"?\s*$/.exec(line);
      if (m) shared.push(m[1].trim());
      continue;
    }
    if (section !== "lanes") continue;
    const idM = /^\s*-\s*id:\s*(\S+)/.exec(line);
    if (idM) {
      cur = { id: idM[1], repo: "", owns: [], resources: [] };
      lanes[cur.id] = cur;
      continue;
    }
    if (!cur) continue;
    const repoM = /^\s*repo:\s*(\S+)/.exec(line);
    if (repoM) { cur.repo = repoM[1]; continue; }
    const ownsM = /^\s*owns:\s*\[(.*)\]/.exec(line);
    if (ownsM) {
      cur.owns = ownsM[1].split(",").map((s) => s.trim().replace(/^"|"$/g, "")).filter(Boolean);
      continue;
    }
    const resM = /^\s*resources:\s*\[(.*)\]/.exec(line);
    if (resM) {
      cur.resources = resM[1].split(",").map((s) => s.trim().replace(/^"|"$/g, "")).filter(Boolean);
      continue;
    }
  }

  const items: ReturnType<typeof parseItem>[] = [];
  const itemPaths: Record<string, string> = {};
  for (const e of Deno.readDirSync(`${engineDir}/items`)) {
    if (!e.name.endsWith(".yaml")) continue;
    const p = `${engineDir}/items/${e.name}`;
    const it = readItem(p);
    items.push(it);
    itemPaths[it.id] = p;
  }
  return { lanes, shared, items, itemPaths };
}

function leasesFor(items: { id: string; repo: string }[], repos: Record<string, string>) {
  const out: Record<string, Lease> = {};
  for (const it of items) {
    const root = repos[it.repo];
    if (!root) continue;
    const l = readLease(root, it.id);
    if (l) out[it.id] = l;
  }
  return out;
}

// ── Команди ─────────────────────────────────────────────────────────────────────

function cmdPreflight(): number {
  const stateRepo = arg("state");
  const factory = arg("factory", `${stateRepo}/../strw-factory`);
  const r = preflight({
    stateRepo,
    validate: () => runValidator(factory, `${stateRepo}/engine`),
  });
  out(r);
  return r.started ? 0 : 3; // 3 = тік НЕ почався. Окремий код, щоб не плутати з падінням.
}

function cmdPlan(): number {
  const engineDir = arg("engine");
  const repos = JSON.parse(arg("repos")) as Record<string, string>;
  const tick = Number(arg("tick", "1"));
  const n = Number(arg("n", "1"));
  const reg = loadRegistry(engineDir);
  const p = planTick({
    // deno-lint-ignore no-explicit-any
    items: reg.items as any,
    lanes: reg.lanes,
    shared: reg.shared,
    n,
    maxFanout: Number(arg("fanout", "2")),
    panel: Number(arg("panel", "0")),
    cores: Number(arg("cores", "8")),
    tick,
    leases: leasesFor(reg.items as { id: string; repo: string }[], repos),
    nowMs: Date.now(),
  });
  out({
    selected: p.selected.map((s) => ({ id: s.id, lane: s.lane, repo: s.repo, branch: s.branch })),
    candidates: p.candidates.map((c) => c.id),
    skipped: p.skipped,
    ceiling: p.ceiling,
    disjointness_proved: p.disjointness_proved,
  });
  return 0;
}

function cmdClaim(): number {
  const l = claim(arg("repo"), arg("item"), arg("run"), Date.now(), Number(arg("tick", "1")));
  out(l);
  return 0;
}

function cmdHeartbeat(): number {
  out(heartbeat(arg("repo"), arg("item"), arg("run"), Number(arg("epoch")), Date.now()));
  return 0;
}

function cmdRelease(): number {
  out(release(arg("repo"), arg("item"), arg("run"), Number(arg("epoch"))));
  return 0;
}

/**
 * Реконсиляція. Без --apply нічого не пише — тільки показує вердикт.
 * З --apply записує стан у item-файл. Це і є те, що має врятувати сценарій (а).
 */
function cmdReconcile(): number {
  const engineDir = arg("engine");
  const repos = JSON.parse(arg("repos")) as Record<string, string>;
  const only = arg("item", "");
  const apply = flag("apply");
  const reg = loadRegistry(engineDir);
  const world: World = realWorld(repos);

  const results: unknown[] = [];
  for (const it of reg.items) {
    if (only && it.id !== only) continue;
    const lease = repos[it.repo] ? readLease(repos[it.repo], it.id) : null;
    const staleLease = lease !== null && isStale(lease, Date.now());

    // Реконсилюємо тільки те, що НЕ в спокої: або ліза протухла, або елемент
    // завис у робочому/намірному стані. Живу лізу чіпати не можна.
    const inFlight = ["claimed", "running", "gated", "merging", "reviewed"].includes(it.state);
    if (!staleLease && !inFlight && !only) continue;

    const v = reconcile(
      { id: it.id, repo: it.repo, branch: it.branch, state: it.state, attempts: it.attempts, pr: it.pr },
      world,
    );
    results.push({ id: it.id, from: it.state, ...v });

    if (apply && (v.state !== it.state || v.attempts !== it.attempts)) {
      const fields: Record<string, unknown> = { state: v.state, attempts: v.attempts };
      if (v.merge_commit) fields.merge_commit = v.merge_commit;
      writeItemFields(reg.itemPaths[it.id], fields);
      // Ліза протухлого/завершеного елемента більше не потрібна.
      const root = repos[it.repo];
      if (root && lease?.run_id) {
        try {
          release(root, it.id, lease.run_id, lease.epoch);
        } catch { /* чужий fence — не наша ліза, не чіпаємо */ }
      }
    }
  }
  out({ applied: apply, results });
  return 0;
}

function cmdSettle(): number {
  const engineDir = arg("engine");
  const stateRepo = arg("state");
  const product = arg("product");
  const cycleId = arg("cycle");
  const tick = Number(arg("tick", "1"));
  const reg = loadRegistry(engineDir);

  const statePath = `${stateRepo}/products/${product}/state.md`;
  const doc = Deno.readTextFileSync(statePath);
  const block = renderEngineBlock(
    reg.items.map((i) => ({
      id: i.id,
      state: i.state,
      lane: i.lane,
      attempts: i.attempts,
      pr: i.pr ?? null,
    })),
    { tick, cycle_id: cycleId, generated_at: new Date().toISOString() },
  );
  const next = upsertBlock(doc, block);
  const tmp = `${statePath}.${crypto.randomUUID()}.tmp`;
  Deno.writeTextFileSync(tmp, next);
  Deno.renameSync(tmp, statePath);

  const week = isoWeekFile(new Date());
  const cyclesPath = `${engineDir}/cycles/${week}.jsonl`;
  Deno.mkdirSync(`${engineDir}/cycles`, { recursive: true });
  const line = cycleLine({
    cycle_id: cycleId,
    tick,
    started_at: arg("started", new Date().toISOString()),
    finished_at: new Date().toISOString(),
    selected: arg("selected", "").split(",").filter(Boolean),
    outcomes: Object.fromEntries(reg.items.map((i) => [i.id, i.state])),
    n: Number(arg("n", "1")),
  });
  Deno.writeTextFileSync(cyclesPath, line + "\n", { append: true });

  out({ state_md: statePath, cycles: cyclesPath, items: reg.items.length });
  return 0;
}

// ── Точка входу ─────────────────────────────────────────────────────────────────

const COMMANDS: Record<string, () => number> = {
  preflight: cmdPreflight,
  plan: cmdPlan,
  claim: cmdClaim,
  heartbeat: cmdHeartbeat,
  release: cmdRelease,
  reconcile: cmdReconcile,
  settle: cmdSettle,
};

if (import.meta.main) {
  const cmd = Deno.args[0];
  const fn = COMMANDS[cmd];
  if (!fn) {
    console.error(`невідома команда '${cmd ?? ""}'. Доступні: ${Object.keys(COMMANDS).join(", ")}`);
    Deno.exit(2);
  }
  try {
    Deno.exit(fn());
  } catch (e) {
    console.error(`${(e as Error).name}: ${(e as Error).message}`);
    Deno.exit(1);
  }
}

export { loadRegistry };
