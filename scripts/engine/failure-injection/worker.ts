#!/usr/bin/env -S deno run --allow-all
// worker.ts — воркер ланцюжка, який можна вбити у ТОЧНО заданій точці.
//
// Він навмисно не ловить сигнали й не має обробників виходу: у точці --die-at
// пише маркер і засинає назавжди, а харнес шле йому SIGKILL. SIGKILL не
// перехоплюється — це справжня раптова смерть процесу, а не імітація через
// throw чи Deno.exit(). Саме такий воркер помирав 27.07.

import { claim, heartbeat } from "../lib/lease.ts";
import { chainWrite, withIntent } from "../lib/chain.ts";
import { run } from "../lib/world.ts";

function arg(name: string, fallback?: string): string {
  const i = Deno.args.indexOf(`--${name}`);
  if (i >= 0 && i + 1 < Deno.args.length) return Deno.args[i + 1];
  if (fallback !== undefined) return fallback;
  throw new Error(`бракує --${name}`);
}

const repoRoot = arg("repo");
const itemPath = arg("item-path");
const itemId = arg("item");
const runId = arg("run");
const branch = arg("branch");
const dieAt = arg("die-at", "");
const marker = arg("marker");
const tick = Number(arg("tick", "1"));
const pr = Number(arg("pr", "0"));

function checkpoint(name: string): void {
  if (dieAt !== name) return;
  // Повідомляємо харнес, що ми РІВНО в потрібному стані, і завмираємо.
  Deno.writeTextFileSync(marker, `${name}\n${Deno.pid}\n`);
  console.error(`[worker] у точці '${name}', чекаю на SIGKILL`);
  while (true) {
    // активне очікування без таймерів: жодного шансу «дочиститись» після сигналу
    const t = Date.now();
    while (Date.now() - t < 50) { /* spin */ }
  }
}

console.error(`[worker] старт ${itemId} run=${runId}`);

// ── Клейм ───────────────────────────────────────────────────────────────────────
const lease = claim(repoRoot, itemId, runId, Date.now(), tick);
const epoch = lease.epoch;
console.error(`[worker] ліза взята: epoch=${epoch}`);
checkpoint("after-claim");

// ── A. maker ────────────────────────────────────────────────────────────────────
chainWrite(repoRoot, itemPath, itemId, runId, epoch, { state: "running" });
heartbeat(repoRoot, itemId, runId, epoch, Date.now());
checkpoint("during-maker");

// ── B. детермінований гейт ──────────────────────────────────────────────────────
chainWrite(repoRoot, itemPath, itemId, runId, epoch, { state: "gated" });
heartbeat(repoRoot, itemId, runId, epoch, Date.now());
// Тут «під час гейта» — сценарій (б). Гілка вже існує, PR ще нема, merge не було.
checkpoint("during-gate");

// ── C. checker ──────────────────────────────────────────────────────────────────
chainWrite(repoRoot, itemPath, itemId, runId, epoch, { state: "reviewed" });
checkpoint("during-checker");

// ── D→E. НАМІР ПЕРЕД ЕФЕКТОМ, далі сам ефект (merge) ────────────────────────────
const headSha = run(repoRoot, ["git", "rev-parse", branch]).stdout.trim();
withIntent(
  repoRoot,
  itemPath,
  itemId,
  runId,
  epoch,
  { state: "merging", pr: pr || null, head_sha: headSha },
  () => {
    // ЕФЕКТ: реальний merge у main. Після цієї команди робота у «проді».
    const r = run(repoRoot, ["git", "merge", "--no-ff", "-m", `merge ${branch}`, branch]);
    if (!r.ok) throw new Error(`merge впав: ${r.stderr}`);
    console.error(`[worker] merge виконано`);

    // ⬇ РІВНО ТУТ помирала v1: робота у проді, стан ще не записаний.
    checkpoint("after-merge-before-state");
  },
);

// ── Запис підсумку ──────────────────────────────────────────────────────────────
// Ланцюжок закінчується на merge-pending; тут merge вже зроблений харнесом
// сценарію, тож фіксуємо done лише щоб було видно, що воркер ДОЙШОВ до запису.
chainWrite(repoRoot, itemPath, itemId, runId, epoch, { state: "done" });
console.error(`[worker] стан записано, вихід 0`);
