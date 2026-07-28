// Фаза 3 Settle — спека v2 §4 (таблиця фаз) і §4 «Фаза 3 пише state.md».
//
// v1 не писала state.md ВЗАГАЛІ — пряме порушення hard rule «State або не сталося».
// Але state.md — це 661 рядок людського документа. Тому запис іде в машинний блок
// між маркерами: усе поза ними лишається байт-у-байт.
import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { BLOCK_END, BLOCK_START, cycleLine, renderEngineBlock, upsertBlock } from "./lib/settle.ts";

const ITEMS = [
  { id: "pact-001.m2.a", state: "done", lane: "ios-ui", attempts: 1, pr: 51 },
  { id: "pact-001.m2.b", state: "ready", lane: "backend", attempts: 0 },
  { id: "pact-001.m2.c", state: "blocked", lane: "kmp-common", attempts: 0 },
];

Deno.test("блок містить кожен елемент і його стан", () => {
  const b = renderEngineBlock(ITEMS, { tick: 7, cycle_id: "c-7" });
  assertStringIncludes(b, "pact-001.m2.a");
  assertStringIncludes(b, "done");
  assertStringIncludes(b, "pact-001.m2.c");
  assertStringIncludes(b, "blocked");
});

Deno.test("блок обрамлений маркерами — інакше його не можна оновити ідемпотентно", () => {
  const b = renderEngineBlock(ITEMS, { tick: 7, cycle_id: "c-7" });
  assertStringIncludes(b, BLOCK_START);
  assertStringIncludes(b, BLOCK_END);
});

Deno.test("блок каже, що він похідний від items/ — щоб його не правили руками", () => {
  const b = renderEngineBlock(ITEMS, { tick: 7, cycle_id: "c-7" });
  assertStringIncludes(b, "items/");
});

Deno.test("перший запис ДОПИСУЄ блок, не чіпаючи наявний текст", () => {
  const doc = "# Стан\n\n## Next\n- щось людське\n";
  const out = upsertBlock(doc, renderEngineBlock(ITEMS, { tick: 1, cycle_id: "c-1" }));
  assertStringIncludes(out, "## Next\n- щось людське");
  assertStringIncludes(out, BLOCK_START);
});

Deno.test("повторний запис ЗАМІНЮЄ блок, а не додає другий", () => {
  const doc = "# Стан\n\n## Next\n- щось людське\n";
  let out = upsertBlock(doc, renderEngineBlock(ITEMS, { tick: 1, cycle_id: "c-1" }));
  out = upsertBlock(out, renderEngineBlock(ITEMS, { tick: 2, cycle_id: "c-2" }));
  assertEquals(out.split(BLOCK_START).length - 1, 1);
  assertEquals(out.split(BLOCK_END).length - 1, 1);
  assertStringIncludes(out, "тік 2");
});

Deno.test("людський текст ПІСЛЯ блоку переживає оновлення", () => {
  const doc = "# Стан\n";
  let out = upsertBlock(doc, renderEngineBlock(ITEMS, { tick: 1, cycle_id: "c-1" }));
  out += "\n## Open questions\n- людське питання\n";
  out = upsertBlock(out, renderEngineBlock(ITEMS, { tick: 2, cycle_id: "c-2" }));
  assertStringIncludes(out, "## Open questions\n- людське питання");
  assertStringIncludes(out, "тік 2");
});

Deno.test("перший запис дописує блок у кінець — людський текст не зсувається", () => {
  const doc = "# Стан\n\n## Done\n- рядок А\n";
  const out = upsertBlock(doc, renderEngineBlock(ITEMS, { tick: 1, cycle_id: "c-1" }));
  assertEquals(out.slice(0, doc.length), doc);
});

Deno.test("оновлення блоку не змінює жодного байта поза маркерами", () => {
  const head = "# Стан\n\n## Done\n- рядок А\n- рядок Б\n\n";
  const tail = "\n## Tried & failed\n- рядок В\n";
  // блок уже стоїть МІЖ head і tail — саме цей випадок і буде в реальному state.md
  // на другому й наступних тіках
  const seeded = head + renderEngineBlock(ITEMS, { tick: 1, cycle_id: "c-1" }) + tail;
  const out = upsertBlock(seeded, renderEngineBlock(ITEMS, { tick: 9, cycle_id: "c-9" }));

  assertEquals(out.slice(0, out.indexOf(BLOCK_START)), head);
  assertEquals(out.slice(out.indexOf(BLOCK_END) + BLOCK_END.length), tail);
  assertStringIncludes(out, "тік 9");
  assertEquals(out.includes("тік 1 "), false);
});

Deno.test("рядок cycles/ — валідний JSON з cycle_id", () => {
  const line = cycleLine({
    cycle_id: "c-7",
    tick: 7,
    started_at: "2026-07-29T00:00:00Z",
    finished_at: "2026-07-29T00:04:00Z",
    selected: ["pact-001.m2.a"],
    outcomes: { "pact-001.m2.a": "merge-pending" },
    n: 1,
  });
  const j = JSON.parse(line);
  assertEquals(j.cycle_id, "c-7");
  assertEquals(j.selected, ["pact-001.m2.a"]);
  assertEquals(j.n, 1);
});

Deno.test("рядок cycles/ — рівно один рядок, інакше JSONL ламається", () => {
  const line = cycleLine({
    cycle_id: "c-7",
    tick: 7,
    started_at: "a",
    finished_at: "b",
    selected: ["x"],
    outcomes: { x: "done" },
    n: 1,
  });
  assertEquals(line.includes("\n"), false);
});

Deno.test("зведення станів у блоці рахується, а не переписується з рук", () => {
  const b = renderEngineBlock(ITEMS, { tick: 7, cycle_id: "c-7" });
  assertStringIncludes(b, "done=1");
  assertStringIncludes(b, "ready=1");
  assertStringIncludes(b, "blocked=1");
});
