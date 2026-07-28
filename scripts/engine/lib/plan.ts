// Фаза 1 Plan — спека v2 §4 (таблиця фаз), §4.4 (бюджет слотів).

import { disjointOrThrow, IsolationConflict, type LaneMap, type PlanItem } from "./resources.ts";
import { inQuarantine, isStale, type Lease } from "./lease.ts";

export const CYCLE_ERROR = "CYCLE";

export class PlanError extends Error {
  code: string;
  constructor(message: string, code = "PLAN") {
    super(message);
    this.name = "PlanError";
    this.code = code;
  }
}

export interface PlanItemFull extends PlanItem {
  id: string;
  state: string;
  repo: string;
  branch?: string;
  attempts?: number;
  blocked_by?: string[];
}

/** §4.4: `hw.ncpu` = 8 → min(16, cores − 2) = 6. */
export function slotCeiling(cores: number): number {
  return Math.min(16, Math.max(1, cores - 2));
}

/**
 * Топологічне сортування. Цикл — ПОМИЛКА, а не тихий порожній набір:
 * порожній набір невідрізненний від «роботи немає» і ховає зламаний реєстр.
 */
export function topoSort(items: PlanItemFull[]): string[] {
  const byId = new Map(items.map((i) => [i.id, i]));
  const deps = new Map<string, string[]>();

  for (const it of items) {
    const d: string[] = [];
    for (const ref of it.blocked_by ?? []) {
      if (!String(ref).startsWith("item:")) continue; // decision:* — не ребро графа
      const dep = String(ref).slice(5);
      if (!byId.has(dep)) {
        throw new PlanError(
          `${it.id}: blocked_by посилається на неіснуючий елемент '${dep}' — реєстр зламано`,
        );
      }
      d.push(dep);
    }
    deps.set(it.id, d);
  }

  const order: string[] = [];
  const state = new Map<string, 0 | 1 | 2>(); // 0 не бачили, 1 у стеку, 2 готово
  const stack: string[] = [];

  const visit = (id: string): void => {
    const s = state.get(id) ?? 0;
    if (s === 2) return;
    if (s === 1) {
      const from = stack.indexOf(id);
      const cyc = [...stack.slice(from), id].join(" → ");
      throw new PlanError(`цикл залежностей у реєстрі: ${cyc}`, CYCLE_ERROR);
    }
    state.set(id, 1);
    stack.push(id);
    for (const d of deps.get(id) ?? []) visit(d);
    stack.pop();
    state.set(id, 2);
    order.push(id);
  };

  for (const it of items) visit(it.id);
  return order;
}

export interface PlanOpts {
  items: PlanItemFull[];
  lanes: LaneMap;
  shared: string[];
  n: number;
  maxFanout: number;
  panel: number;
  cores: number;
  tick: number;
  leases: Record<string, Lease>;
  nowMs?: number;
}

export interface Skipped {
  id: string;
  reason: string;
}

export interface PlanResult {
  selected: PlanItemFull[];
  /** Усі, хто був готовий ДО зрізу до N — щоб телеметрія бачила справжній попит. */
  candidates: PlanItemFull[];
  skipped: Skipped[];
  disjointness_proved: boolean;
  ceiling: number;
}

export function planTick(opts: PlanOpts): PlanResult {
  const nowMs = opts.nowMs ?? 0;
  const ceiling = slotCeiling(opts.cores);

  // Інваріант бюджету — ДО будь-якого планування (§4.4).
  const demand = opts.n * (1 + opts.maxFanout) + opts.panel;
  if (demand > ceiling) {
    throw new PlanError(
      `бюджет слотів порушено: N(${opts.n}) × (1 + fanout ${opts.maxFanout}) + panel(${opts.panel}) ` +
        `= ${demand} > стеля ${ceiling}. Надлишок стає в чергу, час очікування йде в поріг лізи → ` +
        `протух → реклейм → livelock (§4.4).`,
    );
  }

  const order = topoSort(opts.items);
  const byId = new Map(opts.items.map((i) => [i.id, i]));
  const skipped: Skipped[] = [];
  const candidates: PlanItemFull[] = [];

  for (const id of order) {
    const it = byId.get(id)!;

    if (it.state !== "ready") {
      skipped.push({ id, reason: `стан '${it.state}' — планується лише ready` });
      continue;
    }

    const lease = opts.leases[id] ?? null;
    if (inQuarantine(lease, opts.tick)) {
      skipped.push({
        id,
        reason: `карантин: елемент реклеймнуто в тіку ${lease!.reclaimed_in_tick}, ` +
          `доступний не раніше ${lease!.reclaimed_in_tick! + 1} (§4.1 п.4)`,
      });
      continue;
    }

    if (lease !== null && !isStale(lease, nowMs)) {
      skipped.push({ id, reason: `жива ліза: run_id ${lease.run_id}, epoch ${lease.epoch}` });
      continue;
    }

    candidates.push(it);
  }

  // Зріз до N — ПІСЛЯ підрахунку кандидатів, щоб справжній попит лишався видимим.
  const selected: PlanItemFull[] = [];
  for (const it of candidates) {
    if (selected.length >= opts.n) {
      skipped.push({ id: it.id, reason: `понад стелю N=${opts.n} у цьому тіку` });
      continue;
    }
    try {
      disjointOrThrow([...selected, it], opts.lanes, opts.shared);
      selected.push(it);
    } catch (e) {
      if (e instanceof IsolationConflict) {
        skipped.push({ id: it.id, reason: `ізоляція: ${e.message}` });
        continue;
      }
      throw e;
    }
  }

  // Фінальний доказ на вибраному наборі — не на кандидатах.
  disjointOrThrow(selected, opts.lanes, opts.shared);

  return { selected, candidates, skipped, disjointness_proved: true, ceiling };
}
