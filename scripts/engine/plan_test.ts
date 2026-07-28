// Фаза 1 Plan — спека v2 §4 (таблиця фаз), §4.4 (бюджет слотів).
import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { CYCLE_ERROR, PlanError, planTick, slotCeiling, topoSort } from "./lib/plan.ts";

const LANES = {
  "ios-ui": {
    id: "ios-ui",
    repo: "pact-ios",
    owns: ["App/Sources/**"],
    resources: ["xcodebuild", "simulator", "derived-data"],
  },
  "kmp-common": {
    id: "kmp-common",
    repo: "pact-ios",
    owns: ["shared/src/commonMain/**"],
    resources: ["gradle-cache"],
  },
  backend: {
    id: "backend",
    repo: "pact-backend",
    owns: ["backend/supabase/functions/**"],
    resources: ["supabase-db"],
  },
};
const SHARED = ["contract/**"];

function item(over: Record<string, unknown> = {}) {
  return {
    id: "a",
    lane: "ios-ui",
    state: "ready",
    repo: "pact-ios",
    branch: "cycle/a",
    attempts: 0,
    ...over,
  };
}

// ── Топологічне сортування ──────────────────────────────────────────────────────

Deno.test("незалежні елементи сортуються без помилки", () => {
  const order = topoSort([item({ id: "a" }), item({ id: "b" })]);
  assertEquals(order.length, 2);
});

Deno.test("залежність ставить попередника раніше", () => {
  const order = topoSort([
    item({ id: "client", blocked_by: ["item:backend"] }),
    item({ id: "backend" }),
  ]);
  assertEquals(order.indexOf("backend") < order.indexOf("client"), true);
});

Deno.test("ЦИКЛ — це error, а не тихий порожній набір", () => {
  // v1 на циклі мовчки не планувала нічого, і це виглядало як «роботи немає».
  const e = assertThrows(
    () =>
      topoSort([
        item({ id: "a", blocked_by: ["item:b"] }),
        item({ id: "b", blocked_by: ["item:a"] }),
      ]),
    PlanError,
  ) as PlanError;
  assertEquals(e.code, CYCLE_ERROR);
  assertEquals(e.message.includes("a"), true);
  assertEquals(e.message.includes("b"), true);
});

Deno.test("самопосилання теж цикл", () => {
  assertThrows(() => topoSort([item({ id: "a", blocked_by: ["item:a"] })]), PlanError);
});

Deno.test("посилання на decision: не є ребром графа елементів", () => {
  const order = topoSort([item({ id: "a", blocked_by: ["decision:d-014"] })]);
  assertEquals(order, ["a"]);
});

Deno.test("посилання на неіснуючий елемент — помилка, а не мовчазний пропуск", () => {
  assertThrows(() => topoSort([item({ id: "a", blocked_by: ["item:немає"] })]), PlanError);
});

// ── Бюджет слотів §4.4 ──────────────────────────────────────────────────────────

Deno.test("стеля воркфлоу = min(16, cores − 2); при 8 ядрах це 6", () => {
  assertEquals(slotCeiling(8), 6);
});

Deno.test("стеля не перевищує 16 навіть на великій машині", () => {
  assertEquals(slotCeiling(64), 16);
});

Deno.test("інваріант N × (1 + max_fanout) + panel ≤ 6 тримає N=1 при fanout 2", () => {
  // 1 × (1 + 2) + 0 = 3 ≤ 6
  const p = planTick({
    items: [item()],
    lanes: LANES,
    shared: SHARED,
    n: 1,
    maxFanout: 2,
    panel: 0,
    cores: 8,
    tick: 1,
    leases: {},
  });
  assertEquals(p.selected.length, 1);
});

Deno.test("N, що ламає інваріант слотів, відхиляється ДО планування", () => {
  const e = assertThrows(
    () =>
      planTick({
        items: [item({ id: "a" }), item({ id: "b", lane: "backend", repo: "pact-backend" })],
        lanes: LANES,
        shared: SHARED,
        n: 2,
        maxFanout: 2,
        panel: 3, // 2 × 3 + 3 = 9 > 6
        cores: 8,
        tick: 1,
        leases: {},
      }),
    PlanError,
  ) as PlanError;
  assertEquals(e.message.includes("6"), true);
});

// ── Відбір ──────────────────────────────────────────────────────────────────────

Deno.test("планується лише ready — blocked, done, merge-pending не беруться", () => {
  const p = planTick({
    items: [
      item({ id: "r", state: "ready" }),
      item({ id: "b", state: "blocked", lane: "backend", repo: "pact-backend" }),
      item({ id: "d", state: "done", lane: "kmp-common" }),
      item({ id: "m", state: "merge-pending", lane: "kmp-common" }),
    ],
    lanes: LANES,
    shared: SHARED,
    n: 3,
    maxFanout: 1,
    panel: 0,
    cores: 8,
    tick: 1,
    leases: {},
  });
  assertEquals(p.selected.map((s) => s.id), ["r"]);
});

Deno.test("КАРАНТИН: реклеймнутий у цьому ж тіку елемент не планується", () => {
  const leases = {
    a: { item_id: "a", run_id: "old", epoch: 2, heartbeat: 0, claimed_in_tick: 5, reclaimed_in_tick: 5 },
  };
  const p = planTick({
    items: [item({ id: "a" })],
    lanes: LANES,
    shared: SHARED,
    n: 1,
    maxFanout: 1,
    panel: 0,
    cores: 8,
    tick: 5,
    leases,
  });
  assertEquals(p.selected.length, 0);
  assertEquals(p.skipped.find((s) => s.id === "a")?.reason.includes("карантин"), true);
});

Deno.test("КАРАНТИН знімається на наступному тіку T+1", () => {
  const leases = {
    a: { item_id: "a", run_id: null, epoch: 2, heartbeat: null, claimed_in_tick: 5, reclaimed_in_tick: 5 },
  };
  const p = planTick({
    items: [item({ id: "a" })],
    lanes: LANES,
    shared: SHARED,
    n: 1,
    maxFanout: 1,
    panel: 0,
    cores: 8,
    tick: 6,
    leases,
  });
  assertEquals(p.selected.map((s) => s.id), ["a"]);
});

Deno.test("елемент під ЖИВОЮ чужою лізою не планується", () => {
  const leases = {
    a: { item_id: "a", run_id: "інший", epoch: 1, heartbeat: 1000, claimed_in_tick: 4, reclaimed_in_tick: null },
  };
  const p = planTick({
    items: [item({ id: "a" })],
    lanes: LANES,
    shared: SHARED,
    n: 1,
    maxFanout: 1,
    panel: 0,
    cores: 8,
    tick: 5,
    leases,
    nowMs: 1000 + 60_000, // 1 хв — ліза ще жива
  });
  assertEquals(p.selected.length, 0);
  assertEquals(p.skipped.find((s) => s.id === "a")?.reason.includes("жива ліза"), true);
});

Deno.test("N=1 ріже набір до одного елемента, навіть коли готових більше", () => {
  const p = planTick({
    items: [
      item({ id: "a", lane: "ios-ui" }),
      item({ id: "b", lane: "backend", repo: "pact-backend" }),
    ],
    lanes: LANES,
    shared: SHARED,
    n: 1,
    maxFanout: 1,
    panel: 0,
    cores: 8,
    tick: 1,
    leases: {},
  });
  assertEquals(p.selected.length, 1);
});

Deno.test("зріз до N іде ПІСЛЯ підрахунку вільних слотів — і кандидати лишаються видимі", () => {
  const p = planTick({
    items: [
      item({ id: "a", lane: "ios-ui" }),
      item({ id: "b", lane: "backend", repo: "pact-backend" }),
    ],
    lanes: LANES,
    shared: SHARED,
    n: 1,
    maxFanout: 1,
    panel: 0,
    cores: 8,
    tick: 1,
    leases: {},
  });
  assertEquals(p.candidates.length, 2, "обидва були готові — це має бути видно в телеметрії");
  assertEquals(p.selected.length, 1);
});

Deno.test("другий елемент, що ділить ексклюзивний ресурс, у той самий тік не потрапляє", () => {
  const p = planTick({
    items: [
      item({ id: "a", lane: "ios-ui" }),
      item({ id: "b", lane: "ios-ui", branch: "cycle/b" }),
    ],
    lanes: LANES,
    shared: SHARED,
    n: 2,
    maxFanout: 1,
    panel: 0,
    cores: 8,
    tick: 1,
    leases: {},
  });
  assertEquals(p.selected.length, 1);
  assertEquals(p.skipped.find((s) => s.id === "b")?.reason.includes("ізоляц"), true);
});

Deno.test("вибраний набір завжди проходить доказ непересічності", () => {
  const p = planTick({
    items: [
      item({ id: "a", lane: "ios-ui" }),
      item({ id: "b", lane: "backend", repo: "pact-backend" }),
      item({ id: "c", lane: "kmp-common" }),
    ],
    lanes: LANES,
    shared: SHARED,
    n: 3,
    maxFanout: 1,
    panel: 0,
    cores: 8,
    tick: 1,
    leases: {},
  });
  assertEquals(p.selected.length, 3);
  assertEquals(p.disjointness_proved, true);
});

Deno.test("кожен пропущений елемент несе причину — мовчазний пропуск заборонений", () => {
  const p = planTick({
    items: [item({ id: "a", state: "blocked" })],
    lanes: LANES,
    shared: SHARED,
    n: 1,
    maxFanout: 1,
    panel: 0,
    cores: 8,
    tick: 1,
    leases: {},
  });
  assertEquals(p.skipped.length, 1);
  assertEquals(p.skipped[0].reason.length > 0, true);
});
