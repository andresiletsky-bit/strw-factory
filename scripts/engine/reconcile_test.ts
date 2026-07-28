// Реконсиляція — спека v2 §4.2. Таблиця пінується дослівно, рядок за рядком.
//
// Найважливіший випадок — смерть ПІСЛЯ merge, ДО запису стану. Саме там v1 давала
// повний фальшивий цикл: елемент каже `ready`, maker бачить порожній diff, мутаційна
// проба «мутуються лише нові/змінені тести» при нулі змінених тестів PASS вакуумно,
// checker бачить порожній diff проти acceptance → PASS, фаза 3 списує цикл у телеметрію.
import { assertEquals } from "jsr:@std/assert@1";
import { reconcile, type World } from "./lib/reconcile.ts";

/** Світ за замовчуванням: нічого немає. Кожен тест перекриває лише те, що пінить. */
function world(over: Partial<World> = {}): World {
  return {
    prView: () => null,
    branchMerged: () => false,
    branchExists: () => false,
    ciStatus: () => "pending",
    ...over,
  };
}

const ITEM = {
  id: "pact-001.m2.x",
  repo: "pact-ios",
  branch: "cycle/m2-x",
  state: "running",
  attempts: 1,
  pr: 51 as number | null,
};

Deno.test("§4.2 рядок 1: gh pr view MERGED → done + merge_commit, attempts НЕ росте", () => {
  const r = reconcile(ITEM, world({
    prView: () => ({ state: "MERGED", mergeCommit: "sha-merge" }),
  }));
  assertEquals(r.state, "done");
  assertEquals(r.merge_commit, "sha-merge");
  assertEquals(r.attempts, 1);
});

Deno.test("СЦЕНАРІЙ А: елемент завис у `merging` — merge стався, стан не записався", () => {
  // Це буквально стан на диску після SIGKILL між merge і фазою 3.
  const r = reconcile({ ...ITEM, state: "merging" }, world({
    prView: () => ({ state: "MERGED", mergeCommit: "sha-merge" }),
  }));
  assertEquals(r.state, "done");
  assertEquals(r.attempts, 1, "повторна спроба зробила б дубль уже змердженої роботи");
  assertEquals(r.merge_commit, "sha-merge");
});

Deno.test("§4.2 рядок 2: гілка змерджена в main → done, навіть коли PR не записаний", () => {
  const r = reconcile({ ...ITEM, pr: null }, world({ branchMerged: () => true }));
  assertEquals(r.state, "done");
  assertEquals(r.attempts, 1);
});

Deno.test("гілка змерджена перемагає закритий PR — merge міг піти іншим PR", () => {
  const r = reconcile(ITEM, world({
    prView: () => ({ state: "CLOSED", mergeCommit: null }),
    branchMerged: () => true,
  }));
  assertEquals(r.state, "done");
  assertEquals(r.attempts, 1);
});

Deno.test("§4.2 рядок 3: PR відкритий + CI зелений → merge-pending, attempts НЕ росте", () => {
  const r = reconcile(ITEM, world({
    prView: () => ({ state: "OPEN", mergeCommit: null }),
    branchExists: () => true,
    ciStatus: () => "green",
  }));
  assertEquals(r.state, "merge-pending");
  assertEquals(r.attempts, 1);
});

Deno.test("§4.2 рядок 4: PR відкритий + CI червоний → ready, attempts += 1", () => {
  const r = reconcile(ITEM, world({
    prView: () => ({ state: "OPEN", mergeCommit: null }),
    branchExists: () => true,
    ciStatus: () => "red",
  }));
  assertEquals(r.state, "ready");
  assertEquals(r.attempts, 2);
});

Deno.test("§4.2 рядок 5: гілки немає → ready, attempts += 1", () => {
  const r = reconcile({ ...ITEM, pr: null }, world({ branchExists: () => false }));
  assertEquals(r.state, "ready");
  assertEquals(r.attempts, 2);
});

Deno.test("гілка є, PR не відкрито → ready, attempts += 1 (робота почалась і вмерла)", () => {
  const r = reconcile({ ...ITEM, pr: null }, world({ branchExists: () => true }));
  assertEquals(r.state, "ready");
  assertEquals(r.attempts, 2);
});

// Поза дослівною таблицею §4.2, але без цього таблиця дає дубль: рядок 4 («CI червоний»)
// не покриває «CI ще біжить». Повернути `ready` там означало б запустити другого maker'а
// на живий PR — рівно те подвоєння, проти якого написано §3.2.
Deno.test("PR відкритий + CI ще біжить → gated, attempts НЕ росте, елемент не планується", () => {
  const r = reconcile(ITEM, world({
    prView: () => ({ state: "OPEN", mergeCommit: null }),
    branchExists: () => true,
    ciStatus: () => "pending",
  }));
  assertEquals(r.state, "gated");
  assertEquals(r.attempts, 1);
  assertEquals(r.schedulable, false);
});

Deno.test("merge-pending не планується — merge робить CEO, ланцюжок закінчився", () => {
  const r = reconcile(ITEM, world({
    prView: () => ({ state: "OPEN", mergeCommit: null }),
    branchExists: () => true,
    ciStatus: () => "green",
  }));
  assertEquals(r.schedulable, false);
});

Deno.test("done не планується й не відкочується назад у ready", () => {
  const r = reconcile({ ...ITEM, state: "done" }, world({ branchExists: () => false }));
  assertEquals(r.state, "done");
  assertEquals(r.attempts, 1);
  assertEquals(r.schedulable, false);
});

Deno.test("ready планується", () => {
  const r = reconcile({ ...ITEM, pr: null }, world({ branchExists: () => false }));
  assertEquals(r.schedulable, true);
});

Deno.test("MERGED без mergeCommit не втрачає факт мержу, але фіксує прогалину", () => {
  const r = reconcile(ITEM, world({
    prView: () => ({ state: "MERGED", mergeCommit: null }),
  }));
  assertEquals(r.state, "done");
  assertEquals(r.merge_commit, null);
  assertEquals(r.needs_attention, true);
});

Deno.test("кожен вердикт несе причину — реконсиляція мовчки не переставляє стан", () => {
  const r = reconcile(ITEM, world({
    prView: () => ({ state: "MERGED", mergeCommit: "sha" }),
  }));
  assertEquals(typeof r.reason, "string");
  assertEquals(r.reason.length > 0, true);
});

Deno.test("недоступний gh НЕ трактується як «PR не існує» — це не привід для retry", () => {
  // Найтонший випадок: `gh` падає (мережа, ліміт), світ невідомий. Повернути `ready`
  // означало б переробити, можливо, змерджену роботу. Чесна відповідь — «не знаю».
  const r = reconcile(ITEM, world({
    prView: () => {
      throw new Error("gh: API rate limit exceeded");
    },
  }));
  assertEquals(r.state, "running");
  assertEquals(r.attempts, 1);
  assertEquals(r.schedulable, false);
  assertEquals(r.needs_attention, true);
});
