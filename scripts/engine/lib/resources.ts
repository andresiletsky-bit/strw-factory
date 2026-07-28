// Ізоляція — спека v2 §3.4, рівні 1–4.
//
// Рівень 3 (`resources`) — головний. Файлова непересічність НІЧОГО не каже про
// спільні build-ресурси: та сама Supabase БД, порт, Gradle cache, DerivedData,
// симулятор, xcodebuild. 27.07 два формально незалежні цикли в одному чекауті
// дали «every intermediate number was fiction» саме тому, що owns не перетинались.

/** Той самий поріг, що й у лізи: мертвий процес не тримає ресурс вічно. */
const RESOURCE_STALE_MS = 5 * 60 * 1000;

export class IsolationConflict extends Error {
  constructor(message: string) {
    super(message);
    this.name = "IsolationConflict";
  }
}

export interface Lane {
  id: string;
  repo: string;
  owns: string[];
  resources?: string[];
}

export interface PlanItem {
  id?: string;
  lane: string;
  also_touches?: string[];
}

export type LaneMap = Record<string, Lane>;

function laneOrThrow(lanes: LaneMap, id: string): Lane {
  const l = lanes[id];
  if (!l) {
    throw new IsolationConflict(
      `смуга '${id}' не оголошена в lanes.yaml — помилка конфігурації, не «нічим не володію»`,
    );
  }
  return l;
}

/** Усі смуги елемента: основна + also_touches (нотатка W0a, єдиний такий елемент із 14). */
export function lanesOf(item: PlanItem): string[] {
  return [item.lane, ...(item.also_touches ?? [])];
}

export function resourcesOf(item: PlanItem, lanes: LaneMap): string[] {
  const out = new Set<string>();
  for (const id of lanesOf(item)) {
    for (const r of laneOrThrow(lanes, id).resources ?? []) out.add(r);
  }
  return [...out];
}

/**
 * Шляхи, які елементу дозволено чіпати: owns(lane) ∪ owns(also_touches) ∪ shared.
 * Без also_touches гейт рівня 4 («git diff --name-only ⊆ owns ∪ shared») ВПАДЕ на
 * легітимному дифі елемента session-expired-client — це прямо записано W0a.
 */
export function effectivePaths(item: PlanItem, lanes: LaneMap, shared: string[]): string[] {
  const out = new Set<string>(shared);
  for (const id of lanesOf(item)) {
    for (const p of laneOrThrow(lanes, id).owns) out.add(p);
  }
  return [...out];
}

/**
 * Тільки owns, без shared — саме по ньому доводиться непересічність.
 * `effectivePaths` для цього НЕ годиться: він містить shared, тож будь-які дві смуги
 * там завжди «перетинаються», і доказ став би вакуумно хибним.
 */
export function ownsOf(item: PlanItem, lanes: LaneMap): string[] {
  const out = new Set<string>();
  for (const id of lanesOf(item)) {
    const l = laneOrThrow(lanes, id);
    if (l.owns.length === 0) {
      throw new IsolationConflict(
        `смуга '${id}' не володіє жодним шляхом — доказ непересічності над нею вакуумно істинний (§3.4 рівень 1)`,
      );
    }
    for (const p of l.owns) out.add(p);
  }
  return [...out];
}

export function pathsOverlap(a: string[], b: string[]): boolean {
  const setB = new Set(b);
  return a.some((p) => setB.has(p));
}

/**
 * Доказ непересічності набору елементів (фаза 1).
 * Падає, якщо збігається owns АБО збігається ресурс. `shared` навмисно не рахується
 * перетином: торкання shared серіалізує елемент, це окремий механізм (рівень 2).
 */
export function disjointOrThrow(items: PlanItem[], lanes: LaneMap, shared: string[]): void {
  const owned = items.map((i) => ownsOf(i, lanes));
  const res = items.map((i) => resourcesOf(i, lanes));

  for (let i = 0; i < items.length; i++) {
    for (let j = i + 1; j < items.length; j++) {
      const pathHit = owned[i].filter((p) => owned[j].includes(p));
      if (pathHit.length > 0) {
        throw new IsolationConflict(
          `${items[i].id ?? i} і ${items[j].id ?? j} пересікаються по owns: ${pathHit.join(", ")}`,
        );
      }
      const resHit = res[i].filter((r) => res[j].includes(r));
      if (resHit.length > 0) {
        throw new IsolationConflict(
          `${items[i].id ?? i} і ${items[j].id ?? j} ділять ексклюзивний ресурс: ${
            resHit.join(", ")
          } — файлова непересічність цього не ловить (інцидент 27.07)`,
        );
      }
    }
  }
  void shared;
}

// ── Локи ресурсів на диску ──────────────────────────────────────────────────────

interface ResourceLock {
  resource: string;
  held_by: string;
  taken_at: number;
}

export interface AcquireResult {
  ok: boolean;
  conflicts: Array<{ resource: string; held_by: string }>;
}

function lockPath(dir: string, resource: string): string {
  return `${dir}/resources/${resource}.lock.json`;
}

function readLock(dir: string, resource: string): ResourceLock | null {
  try {
    return JSON.parse(Deno.readTextFileSync(lockPath(dir, resource))) as ResourceLock;
  } catch (e) {
    if (e instanceof Deno.errors.NotFound) return null;
    throw e;
  }
}

/**
 * Взяти всі ресурси або жодного. Часткове взяття залишило б «отруєні» локи
 * за претендентом, який роботу так і не почав.
 */
export function acquireResources(
  dir: string,
  resources: string[],
  runId: string,
  nowMs: number,
): AcquireResult {
  const conflicts: AcquireResult["conflicts"] = [];
  for (const r of resources) {
    const held = readLock(dir, r);
    if (held === null) continue;
    if (held.held_by === runId) continue; // реентрантно в межах свого ланцюжка
    if (nowMs - held.taken_at > RESOURCE_STALE_MS) continue; // мертвий власник
    conflicts.push({ resource: r, held_by: held.held_by });
  }
  if (conflicts.length > 0) return { ok: false, conflicts };

  Deno.mkdirSync(`${dir}/resources`, { recursive: true });
  for (const r of resources) {
    const lock: ResourceLock = { resource: r, held_by: runId, taken_at: nowMs };
    const tmp = `${dir}/resources/.${r}.${crypto.randomUUID()}.tmp`;
    Deno.writeTextFileSync(tmp, JSON.stringify(lock, null, 2) + "\n");
    Deno.renameSync(tmp, lockPath(dir, r));
  }
  return { ok: true, conflicts: [] };
}

export function releaseResources(dir: string, resources: string[], runId: string): void {
  for (const r of resources) {
    const held = readLock(dir, r);
    if (held === null || held.held_by !== runId) continue; // чужий лок не чіпаємо
    try {
      Deno.removeSync(lockPath(dir, r));
    } catch (e) {
      if (!(e instanceof Deno.errors.NotFound)) throw e;
    }
  }
}
