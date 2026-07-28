#!/usr/bin/env -S deno run --allow-all
// run.ts — failure injection, три сценарії. Головний доказ сесії W0b.
//
// Успіх = реконсиляція повертає КОРЕКТНИЙ стан у 3/3.
// KILL-критерій (§13, не пом'якшується): будь-який сценарій дає ДУБЛЬ або
// ВТРАТУ роботи → трек зупиняється, N лишається 1.
//
// Що означають «дубль» і «втрата» операційно:
//   дубль  — після реконсиляції елемент знову планується, хоча робота вже в main
//            (або в main з'явився другий merge тієї самої гілки);
//   втрата — робота є в main, а реєстр вважає її незробленою, або навпаки:
//            реєстр каже done, а в main нічого немає.

import { parseItem } from "../lib/items.ts";
import { readLease } from "../lib/lease.ts";
import { reconcile } from "../lib/reconcile.ts";
import { realWorld } from "../lib/world.ts";
import { makeSandbox, pinMergeSha, type Sandbox, sh } from "./sandbox.ts";

const HERE = new URL(".", import.meta.url).pathname;
const WORKER = `${HERE}worker.ts`;

interface Outcome {
  name: string;
  killed_at: string;
  disk_state: string;
  world: string;
  verdict_state: string;
  verdict_attempts: number;
  expected_state: string;
  duplicate: boolean;
  lost: boolean;
  pass: boolean;
  detail: string;
}

/** Запускає воркер, чекає маркера й шле СПРАВЖНІЙ SIGKILL. */
async function killAt(sb: Sandbox, dieAt: string, pr = 0): Promise<void> {
  const marker = `${sb.base}/marker.${dieAt}`;
  const env: Record<string, string> = { ...Deno.env.toObject() };
  env.PATH = `${sb.binDir}:${env.PATH}`;

  const child = new Deno.Command("deno", {
    args: [
      "run", "--allow-all", WORKER,
      "--repo", sb.repo,
      "--item-path", sb.itemPath,
      "--item", sb.itemId,
      "--run", "run-fi-1",
      "--branch", sb.branch,
      "--die-at", dieAt,
      "--marker", marker,
      "--tick", "1",
      "--pr", String(pr),
    ],
    env,
    stdout: "piped",
    stderr: "piped",
  }).spawn();

  // Чекаємо, поки воркер підтвердить, що він РІВНО в потрібній точці.
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    try {
      Deno.statSync(marker);
      break;
    } catch { /* ще не там */ }
    await new Promise((r) => setTimeout(r, 25));
  }
  try {
    Deno.statSync(marker);
  } catch {
    child.kill("SIGKILL");
    await child.status;
    throw new Error(`воркер не дійшов до точки '${dieAt}' за 30 с`);
  }

  child.kill("SIGKILL"); // не перехоплюється — справжня раптова смерть
  const st = await child.status;
  if (st.signal !== "SIGKILL") {
    throw new Error(`очікували смерть від SIGKILL, отримали ${JSON.stringify(st)}`);
  }
  // Стрічки треба закрити, інакше Deno лишає ресурс висіти.
  await child.stdout.cancel();
  await child.stderr.cancel();
}

function mergeCount(sb: Sandbox): number {
  const log = sh(sb.repo, ["git", "log", "main", "--oneline", "--merges"]);
  return log.split("\n").filter((l) => l.trim() !== "").length;
}

function workInMain(sb: Sandbox): boolean {
  return sh(sb.repo, ["git", "ls-tree", "-r", "--name-only", "main"]).includes("App/feature.swift");
}

function report(o: Outcome): void {
  const mark = o.pass ? "✅ PASS" : "❌ FAIL";
  console.log(`\n${"═".repeat(78)}`);
  console.log(`${mark}  ${o.name}`);
  console.log(`${"─".repeat(78)}`);
  console.log(`  убито в точці      : ${o.killed_at}`);
  console.log(`  на диску після kill: state = ${o.disk_state}`);
  console.log(`  що каже світ       : ${o.world}`);
  console.log(`  вердикт реконсиляції: ${o.verdict_state} (attempts ${o.verdict_attempts})`);
  console.log(`  очікувалось        : ${o.expected_state}`);
  console.log(`  дубль роботи       : ${o.duplicate ? "ТАК — KILL-критерій" : "ні"}`);
  console.log(`  втрата роботи      : ${o.lost ? "ТАК — KILL-критерій" : "ні"}`);
  console.log(`  ${o.detail}`);
}

const outcomes: Outcome[] = [];

// ═══════════════════════════════════════════════════════════════════════════════
// СЦЕНАРІЙ А — смерть ПІСЛЯ merge, ДО запису стану.
// Саме тут v1 давала повний фальшивий цикл: порожній diff → вакуумний PASS
// мутаційної проби → вакуумний PASS checker'а → списаний цикл у телеметрії.
// ═══════════════════════════════════════════════════════════════════════════════
async function scenarioA_withPr(): Promise<Outcome> {
  const sb = makeSandbox("a-pr", "MERGED");
  await killAt(sb, "after-merge-before-state", 51);
  pinMergeSha(sb);

  const it = parseItem(Deno.readTextFileSync(sb.itemPath));
  const merged = workInMain(sb);
  const mergesBefore = mergeCount(sb);

  const env = Deno.env.get("PATH")!;
  Deno.env.set("PATH", `${sb.binDir}:${env}`);
  const v = reconcile(
    { id: it.id, repo: "pact-ios", branch: sb.branch, state: it.state, attempts: it.attempts, pr: it.pr },
    realWorld({ "pact-ios": sb.repo }),
  );
  Deno.env.set("PATH", env);

  const duplicate = v.schedulable || mergeCount(sb) > mergesBefore;
  const lost = merged && v.state !== "done";

  return {
    name: "А1. Убито ПІСЛЯ merge, ДО запису стану (PR змерджено, gh відповідає MERGED)",
    killed_at: "after-merge-before-state",
    disk_state: it.state,
    world: `робота в main: ${merged ? "ТАК" : "ні"}, merge-комітів: ${mergesBefore}, gh: MERGED`,
    verdict_state: v.state,
    verdict_attempts: v.attempts,
    expected_state: "done",
    duplicate,
    lost,
    pass: v.state === "done" && v.attempts === it.attempts && !duplicate && !lost,
    detail: v.reason,
  };
}

async function scenarioA_gitOnly(): Promise<Outcome> {
  // Той самий сценарій БЕЗ жодної симуляції: ні gh, ні PR — чистий git.
  const sb = makeSandbox("a-git");
  await killAt(sb, "after-merge-before-state", 0);

  const it = parseItem(Deno.readTextFileSync(sb.itemPath));
  const merged = workInMain(sb);
  const mergesBefore = mergeCount(sb);

  const v = reconcile(
    { id: it.id, repo: "pact-ios", branch: sb.branch, state: it.state, attempts: it.attempts, pr: null },
    realWorld({ "pact-ios": sb.repo }),
  );

  const duplicate = v.schedulable || mergeCount(sb) > mergesBefore;
  const lost = merged && v.state !== "done";

  return {
    name: "А2. Те саме БЕЗ симуляції: без PR, звірка чистим git (§4.2 рядок 2)",
    killed_at: "after-merge-before-state",
    disk_state: it.state,
    world: `робота в main: ${merged ? "ТАК" : "ні"}, merge-комітів: ${mergesBefore}, gh НЕ використовується`,
    verdict_state: v.state,
    verdict_attempts: v.attempts,
    expected_state: "done",
    duplicate,
    lost,
    pass: v.state === "done" && v.attempts === it.attempts && !duplicate && !lost,
    detail: v.reason,
  };
}

// ═══════════════════════════════════════════════════════════════════════════════
// СЦЕНАРІЙ Б — смерть ПІД ЧАС гейта. Робота НЕ змерджена; чесна відповідь —
// повторити, піднявши attempts. Тут помилкою була б протилежність: списати
// елемент як done, не маючи його в main.
// ═══════════════════════════════════════════════════════════════════════════════
async function scenarioB(): Promise<Outcome> {
  const sb = makeSandbox("b");
  await killAt(sb, "during-gate", 0);

  const it = parseItem(Deno.readTextFileSync(sb.itemPath));
  const merged = workInMain(sb);

  const v = reconcile(
    { id: it.id, repo: "pact-ios", branch: sb.branch, state: it.state, attempts: it.attempts, pr: null },
    realWorld({ "pact-ios": sb.repo }),
  );

  const lease = readLease(sb.repo, sb.itemId);
  // Дубль тут означав би «взяти в роботу те, що вже в main». В main нічого немає,
  // тож повторна спроба — це не дубль, а єдиний коректний хід.
  const duplicate = merged && v.schedulable;
  const lost = v.state === "done" && !merged;

  return {
    name: "Б. Убито ПІД ЧАС гейта (робота не змерджена)",
    killed_at: "during-gate",
    disk_state: it.state,
    world: `робота в main: ${merged ? "ТАК" : "ні"}, гілка існує, PR немає`,
    verdict_state: v.state,
    verdict_attempts: v.attempts,
    expected_state: "ready (attempts += 1)",
    duplicate,
    lost,
    pass: v.state === "ready" && v.attempts === it.attempts + 1 && !duplicate && !lost &&
      lease !== null && lease.epoch === 1,
    detail: `${v.reason} · ліза лишилась epoch=${lease?.epoch} (наступний клейм дасть 2 — старий воркер відсічений CAS)`,
  };
}

// ═══════════════════════════════════════════════════════════════════════════════
// СЦЕНАРІЙ В — незаписуваний strw-state.
// Перевіряється ІНШЕ, ніж у А і Б: не «чи вгадала реконсиляція», а чи тік
// ВЗАГАЛІ НЕ ПОЧАВСЯ. 27.07 цей стан тривав 5 год 52 хв, поки pact-ios робив
// 10 комітів — і саме тому ліза живе в продуктовому репо, а не тут.
// ═══════════════════════════════════════════════════════════════════════════════
async function scenarioC(): Promise<Outcome> {
  const sb = makeSandbox("c");

  // Справжній strw-state: git-репо з віддаленим, усе запушено.
  const base = Deno.makeTempDirSync({ prefix: "fi-c-state-" });
  const remote = `${base}/remote.git`;
  const state = `${base}/strw-state`;
  Deno.mkdirSync(remote, { recursive: true });
  sh(remote, ["git", "init", "-q", "--bare", "-b", "main"]);
  sh(base, ["git", "clone", "-q", remote, "strw-state"]);
  sh(state, ["git", "config", "user.email", "engine@strw.local"]);
  sh(state, ["git", "config", "user.name", "engine"]);
  Deno.mkdirSync(`${state}/products/pact-001`, { recursive: true });
  Deno.writeTextFileSync(`${state}/products/pact-001/state.md`, "# Стан\n\n## Next\n- людське\n");
  sh(state, ["git", "add", "-A"]);
  sh(state, ["git", "commit", "-qm", "base"]);
  sh(state, ["git", "push", "-q", "-u", "origin", "main"]);

  const stateBefore = Deno.readTextFileSync(`${state}/products/pact-001/state.md`);

  // Робимо strw-state незаписуваним — рівно як 27.07.
  Deno.chmodSync(state, 0o500);
  let started: boolean;
  let stopReason = "";
  let leaseWritten = false;
  try {
    const r = new Deno.Command("deno", {
      args: [
        "run", "--allow-all", `${HERE}../engine.ts`, "preflight",
        "--state", state, "--factory", `${HERE}../../..`,
      ],
      stdout: "piped",
      stderr: "piped",
    }).outputSync();
    const parsed = JSON.parse(new TextDecoder().decode(r.stdout) || "{}");
    started = parsed.started === true;
    stopReason = parsed.stop_reason ?? "";
    // Ліза мала б лягти в ПРОДУКТОВЕ репо — перевіряємо, що тік не встиг нічого взяти.
    leaseWritten = readLease(sb.repo, sb.itemId) !== null;
  } finally {
    Deno.chmodSync(state, 0o755);
  }

  const stateAfter = Deno.readTextFileSync(`${state}/products/pact-001/state.md`);
  const untouched = stateBefore === stateAfter;

  return {
    name: "В. strw-state незаписуваний — тік НЕ починається",
    killed_at: "не застосовне: тік не стартував",
    disk_state: "item-файли не чіпались",
    world: `strw-state chmod 0500, state.md незмінений: ${untouched ? "ТАК" : "ні"}`,
    verdict_state: started ? "тік ПОЧАВСЯ (помилка)" : "тік НЕ почався",
    verdict_attempts: 0,
    expected_state: "тік НЕ почався",
    duplicate: leaseWritten,
    lost: !untouched,
    pass: !started && untouched && !leaseWritten && stopReason.includes("незаписуваний"),
    detail: stopReason || "(причини не повернуто)",
  };
}

// ═══════════════════════════════════════════════════════════════════════════════

console.log("FAILURE INJECTION — W0b, ядро диспетчера. N=1.");
console.log("Справжнє: git, файлова система, процеси, SIGKILL, лізи, реконсиляція.");
console.log("Симульоване: відповідь GitHub API (підставний gh у PATH) — і сценарій А");
console.log("прогнано ДВІЧІ, другий раз узагалі без gh, на чистому git.");

outcomes.push(await scenarioA_withPr());
outcomes.push(await scenarioA_gitOnly());
outcomes.push(await scenarioB());
outcomes.push(await scenarioC());

for (const o of outcomes) report(o);

// Підсумок рахується по ТРЬОХ сценаріях спеки: А (обидва прогони мусять пройти), Б, В.
const aPass = outcomes[0].pass && outcomes[1].pass;
const bPass = outcomes[2].pass;
const cPass = outcomes[3].pass;
const passed = [aPass, bPass, cPass].filter(Boolean).length;

console.log(`\n${"═".repeat(78)}`);
console.log(`ПІДСУМОК: ${passed}/3 сценаріїв`);
console.log(`  А (після merge, до запису): ${aPass ? "PASS" : "FAIL"}`);
console.log(`  Б (під час гейта)         : ${bPass ? "PASS" : "FAIL"}`);
console.log(`  В (незаписуваний state)   : ${cPass ? "PASS" : "FAIL"}`);
const anyDup = outcomes.some((o) => o.duplicate);
const anyLost = outcomes.some((o) => o.lost);
console.log(`  дубль роботи: ${anyDup ? "Є" : "немає"} · втрата роботи: ${anyLost ? "Є" : "немає"}`);
if (passed === 3 && !anyDup && !anyLost) {
  console.log(`\n3/3. KILL-критерій §13 НЕ спрацював.`);
} else {
  console.log(`\nKILL-критерій §13 СПРАЦЮВАВ: трек зупиняється, N лишається 1.`);
}
console.log("═".repeat(78));

Deno.exit(passed === 3 && !anyDup && !anyLost ? 0 : 1);
