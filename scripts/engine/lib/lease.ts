// Ліза з fencing — спека v2 §3.1 і §4.1.
//
// ЧОМУ ФАЙЛ ЛЕЖИТЬ У ПРОДУКТОВОМУ РЕПО, А НЕ В strw-state:
// 27.07 strw-state був незаписуваним 5 год 52 хв (08:09→14:01, три застряглі .lock),
// а pact-ios за той самий час зробив 10 комітів, включно з мержем PR #43. Робота йшла,
// а heartbeat писати було нікуди → масовий хибний реклейм рівно тієї роботи, яку v1
// оголошувала недублюваною. Ліза мусить жити там, де йде робота.
//
// Каталог `<repo>/.engine/` — поза git-індексом (.gitignore).

/** Поріг протухання — ЗА ЧАСОМ, не за переходом стадії (§4.1 п.2). */
export const HEARTBEAT_MAX_MS = 5 * 60 * 1000;

export interface Lease {
  item_id: string;
  /** null = ліза вільна; epoch при цьому НЕ скидається. */
  run_id: string | null;
  /** Монотонний лічильник клеймів. Ніколи не зменшується й не переюзується. */
  epoch: number;
  /** ms від epoch. null, коли ліза вільна. */
  heartbeat: number | null;
  claimed_in_tick: number | null;
  /** Тік, у якому лізу відібрали в попереднього власника. Карантин: T+1 (§4.1 п.4). */
  reclaimed_in_tick: number | null;
}

/** Розбіжність fence. Ловиться скрізь, де далі йшла б дія з ефектом. */
export class CasMismatch extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CasMismatch";
  }
}

export function leaseDir(repoRoot: string): string {
  return `${repoRoot}/.engine/leases`;
}

export function leasePath(repoRoot: string, itemId: string): string {
  return `${leaseDir(repoRoot)}/${itemId}.json`;
}

export function readLease(repoRoot: string, itemId: string): Lease | null {
  try {
    return JSON.parse(Deno.readTextFileSync(leasePath(repoRoot, itemId))) as Lease;
  } catch (e) {
    if (e instanceof Deno.errors.NotFound) return null;
    throw e;
  }
}

/**
 * Запис через tmp + rename(2). tmp навмисне в тому самому каталозі — rename атомарний
 * лише в межах однієї файлової системи. Читач бачить або старий файл, або новий,
 * ніколи —半 записаний.
 */
function writeAtomic(repoRoot: string, lease: Lease): Lease {
  const dir = leaseDir(repoRoot);
  Deno.mkdirSync(dir, { recursive: true });
  const tmp = `${dir}/.${lease.item_id}.${crypto.randomUUID()}.tmp`;
  Deno.writeTextFileSync(tmp, JSON.stringify(lease, null, 2) + "\n");
  Deno.renameSync(tmp, leasePath(repoRoot, lease.item_id));
  return lease;
}

/**
 * Протухла? Два джерела істини, бо годинник хосту не надійний (§11 «Хост»):
 *  1. heartbeat старший за поріг;
 *  2. heartbeat У МАЙБУТНЬОМУ — годинник стрибав. Такій лізі не можна вірити.
 * Другий випадок навмисно рахується протухлим, а не «вічно живим»: реклейм безпечний,
 * бо старого власника все одно відсіче CAS на першому ж записі, а «вічно жива» ліза —
 * це елемент, застряглий назавжди.
 */
export function isStale(lease: Lease, nowMs: number): boolean {
  if (lease.run_id === null) return true;
  if (lease.heartbeat === null) return true;
  if (lease.heartbeat > nowMs) return true;
  return nowMs - lease.heartbeat > HEARTBEAT_MAX_MS;
}

/** Клейм: epoch += 1 і запис {run_id, epoch, heartbeat} (§4.1 п.1). */
export function claim(
  repoRoot: string,
  itemId: string,
  runId: string,
  nowMs: number,
  tick: number | null = null,
): Lease {
  const prev = readLease(repoRoot, itemId);
  const wasHeld = prev !== null && prev.run_id !== null;
  return writeAtomic(repoRoot, {
    item_id: itemId,
    run_id: runId,
    epoch: (prev?.epoch ?? 0) + 1,
    heartbeat: nowMs,
    claimed_in_tick: tick,
    reclaimed_in_tick: wasHeld ? tick : null,
  });
}

/**
 * Fence-перевірка перед КОЖНИМ записом ланцюжка (§4.1 п.3).
 * Розбіжність = негайний abort; жодна дія з ефектом не виконується.
 */
export function requireFence(
  repoRoot: string,
  itemId: string,
  runId: string,
  epoch: number,
): Lease {
  const l = readLease(repoRoot, itemId);
  if (l === null) {
    throw new CasMismatch(`${itemId}: лізи немає, а воркер ${runId}@${epoch} діє`);
  }
  if (l.run_id !== runId || l.epoch !== epoch) {
    throw new CasMismatch(
      `${itemId}: fence розбіжність — на диску ${l.run_id}@${l.epoch}, воркер ${runId}@${epoch}`,
    );
  }
  return l;
}

/** Heartbeat за часом. epoch НЕ чіпається — це не новий клейм. */
export function heartbeat(
  repoRoot: string,
  itemId: string,
  runId: string,
  epoch: number,
  nowMs: number,
): Lease {
  const l = requireFence(repoRoot, itemId, runId, epoch);
  return writeAtomic(repoRoot, { ...l, heartbeat: nowMs });
}

/** Чисте звільнення. epoch лишається як монотонний лічильник. */
export function release(
  repoRoot: string,
  itemId: string,
  runId: string,
  epoch: number,
): Lease {
  const l = requireFence(repoRoot, itemId, runId, epoch);
  return writeAtomic(repoRoot, { ...l, run_id: null, heartbeat: null });
}

/**
 * Карантин (§4.1 п.4): елемент, реклеймнутий у тіку T, не планується раніше T+1.
 * Захищає від циклу «протух → реклейм → знову протух у тому ж тіку».
 */
export function inQuarantine(lease: Lease | null, currentTick: number): boolean {
  return lease?.reclaimed_in_tick != null && lease.reclaimed_in_tick >= currentTick;
}
