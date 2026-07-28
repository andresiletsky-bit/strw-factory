// Тести лізи з fencing — спека v2 §4.1.
// Кожен тест названий за інваріантом, який він тримає, а не за функцією.
import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  CasMismatch,
  claim,
  heartbeat,
  HEARTBEAT_MAX_MS,
  isStale,
  leasePath,
  readLease,
  release,
  requireFence,
} from "./lib/lease.ts";

function tmpRepo(): string {
  return Deno.makeTempDirSync({ prefix: "engine-lease-" });
}

Deno.test("ліза лежить у <repo>/.engine/leases/, а не в strw-state", () => {
  const repo = tmpRepo();
  assertEquals(leasePath(repo, "p.m2.x"), `${repo}/.engine/leases/p.m2.x.json`);
});

Deno.test("клейм піднімає epoch на 1 від наявного значення", () => {
  const repo = tmpRepo();
  const a = claim(repo, "p.m2.x", "run-1", 1000);
  assertEquals(a.epoch, 1);
  const b = claim(repo, "p.m2.x", "run-2", 2000);
  assertEquals(b.epoch, 2);
  assertEquals(readLease(repo, "p.m2.x")!.run_id, "run-2");
});

Deno.test("запис лізи атомарний: після claim у leases/ немає .tmp-хвостів", () => {
  const repo = tmpRepo();
  claim(repo, "p.m2.x", "run-1", 1000);
  const left = [...Deno.readDirSync(`${repo}/.engine/leases`)].map((e) => e.name);
  assertEquals(left, ["p.m2.x.json"]);
});

Deno.test("протухання рахується ЗА ЧАСОМ: 5 хв рівно — ще жива, 5 хв + 1 мс — протухла", () => {
  const repo = tmpRepo();
  const l = claim(repo, "p.m2.x", "run-1", 1000);
  assertEquals(HEARTBEAT_MAX_MS, 5 * 60 * 1000);
  assertEquals(isStale(l, 1000 + HEARTBEAT_MAX_MS), false);
  assertEquals(isStale(l, 1000 + HEARTBEAT_MAX_MS + 1), true);
});

Deno.test("heartbeat подовжує лізу, НЕ чіпаючи epoch (v1 писала його на переходах стадій)", () => {
  const repo = tmpRepo();
  claim(repo, "p.m2.x", "run-1", 1000);
  const beat = heartbeat(repo, "p.m2.x", "run-1", 1, 1000 + 4 * 60 * 1000);
  assertEquals(beat.epoch, 1);
  assertEquals(isStale(beat, 1000 + 8 * 60 * 1000), false);
});

Deno.test("heartbeat від власника застарілого epoch відхиляється — старий воркер не воскрешає лізу", () => {
  const repo = tmpRepo();
  claim(repo, "p.m2.x", "run-1", 1000);
  claim(repo, "p.m2.x", "run-2", 2000); // реклейм, epoch=2
  assertThrows(
    () => heartbeat(repo, "p.m2.x", "run-1", 1, 3000),
    CasMismatch,
  );
});

Deno.test("requireFence пропускає власника поточного (run_id, epoch)", () => {
  const repo = tmpRepo();
  claim(repo, "p.m2.x", "run-1", 1000);
  requireFence(repo, "p.m2.x", "run-1", 1); // не кидає
});

Deno.test("requireFence кидає при розбіжності epoch — будь-яка дія з ефектом заборонена", () => {
  const repo = tmpRepo();
  claim(repo, "p.m2.x", "run-1", 1000);
  claim(repo, "p.m2.x", "run-2", 2000);
  assertThrows(() => requireFence(repo, "p.m2.x", "run-1", 1), CasMismatch);
});

Deno.test("requireFence кидає при розбіжності run_id навіть на тому самому epoch", () => {
  const repo = tmpRepo();
  claim(repo, "p.m2.x", "run-1", 1000);
  assertThrows(() => requireFence(repo, "p.m2.x", "run-DIFFERENT", 1), CasMismatch);
});

// Мутаційна проба показала, що перевірка epoch була НЕ запінена: у решті тестів
// реклейм робив інший run_id, тож розбіжність ловилась по run_id, а `l.epoch !== epoch`
// можна було видалити з requireFence — і всі 15 тестів лишались зеленими.
// Це рівно той дефект, який §4.1 п.3 називає «того, чого v1 не мала взагалі»:
// той самий воркер після реклейму пише результат. Тут run_id НАВМИСНО однаковий.
Deno.test("requireFence кидає на застарілому epoch при ІДЕНТИЧНОМУ run_id", () => {
  const repo = tmpRepo();
  claim(repo, "p.m2.x", "run-1", 1000);
  claim(repo, "p.m2.x", "run-1", 2000); // той самий воркер реклеймить: epoch 1 → 2
  requireFence(repo, "p.m2.x", "run-1", 2); // нинішній fence живий
  assertThrows(() => requireFence(repo, "p.m2.x", "run-1", 1), CasMismatch);
});

Deno.test("heartbeat на застарілому epoch при ІДЕНТИЧНОМУ run_id відхиляється", () => {
  const repo = tmpRepo();
  claim(repo, "p.m2.x", "run-1", 1000);
  claim(repo, "p.m2.x", "run-1", 2000);
  assertThrows(() => heartbeat(repo, "p.m2.x", "run-1", 1, 3000), CasMismatch);
});

Deno.test("release на застарілому epoch при ІДЕНТИЧНОМУ run_id відхиляється", () => {
  const repo = tmpRepo();
  claim(repo, "p.m2.x", "run-1", 1000);
  claim(repo, "p.m2.x", "run-1", 2000);
  assertThrows(() => release(repo, "p.m2.x", "run-1", 1), CasMismatch);
});

Deno.test("requireFence кидає, коли лізи взагалі немає", () => {
  const repo = tmpRepo();
  assertThrows(() => requireFence(repo, "p.m2.x", "run-1", 1), CasMismatch);
});

Deno.test("клейм записує тік і реклеймнутий елемент недоступний у тому ж тіку (карантин)", () => {
  const repo = tmpRepo();
  const first = claim(repo, "p.m2.x", "run-1", 1000, 7);
  assertEquals(first.claimed_in_tick, 7);
  assertEquals(first.reclaimed_in_tick, null); // перший клейм — не реклейм

  const second = claim(repo, "p.m2.x", "run-2", 2000, 8);
  assertEquals(second.reclaimed_in_tick, 8);
});

Deno.test("release знімає лізу, лишаючи epoch як монотонний лічильник", () => {
  const repo = tmpRepo();
  claim(repo, "p.m2.x", "run-1", 1000);
  release(repo, "p.m2.x", "run-1", 1);
  const l = readLease(repo, "p.m2.x")!;
  assertEquals(l.run_id, null);
  assertEquals(l.epoch, 1);
  // наступний клейм не переюзує epoch 1
  assertEquals(claim(repo, "p.m2.x", "run-2", 2000).epoch, 2);
});

Deno.test("release від чужого fence відхиляється", () => {
  const repo = tmpRepo();
  claim(repo, "p.m2.x", "run-1", 1000);
  claim(repo, "p.m2.x", "run-2", 2000);
  assertThrows(() => release(repo, "p.m2.x", "run-1", 1), CasMismatch);
});

Deno.test("епоха переживає падіння процесу: ліза читається з диска, не з пам'яті", () => {
  const repo = tmpRepo();
  claim(repo, "p.m2.x", "run-1", 1000);
  const raw = JSON.parse(Deno.readTextFileSync(leasePath(repo, "p.m2.x")));
  assertEquals(raw.epoch, 1);
  assertEquals(raw.run_id, "run-1");
});

Deno.test("стрибок годинника назад не оживляє протухлу лізу — монотонний лічильник тіків теж рахується", () => {
  const repo = tmpRepo();
  // ліза з heartbeat у майбутньому (годинник стрибнув уперед і назад)
  const l = claim(repo, "p.m2.x", "run-1", 10_000_000);
  // «зараз» менше за heartbeat — v1 порахувала б лізу вічно живою
  assertEquals(isStale(l, 1000), true);
});
