// Ланцюжок елемента — спека v2 §4.1 п.3 і §4.2 «намір перед ефектом».
import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { claim } from "./lib/lease.ts";
import { CasMismatch } from "./lib/lease.ts";
import { parseItem } from "./lib/items.ts";
import { chainWrite, withIntent } from "./lib/chain.ts";

const ITEM_YAML = `schema_version: 1
id: pact-001.m2.x
lane: ios-ui
state: running
repo: pact-ios
branch: cycle/m2-x
lease: {run_id: null, epoch: 0, heartbeat: null}
attempts: 1
`;

function fixture(): { repo: string; itemPath: string } {
  const repo = Deno.makeTempDirSync({ prefix: "engine-chain-" });
  const itemPath = `${repo}/pact-001.m2.x.yaml`;
  Deno.writeTextFileSync(itemPath, ITEM_YAML);
  return { repo, itemPath };
}

Deno.test("chainWrite під живим fence записує поля", () => {
  const { repo, itemPath } = fixture();
  claim(repo, "pact-001.m2.x", "run-1", 1000);
  chainWrite(repo, itemPath, "pact-001.m2.x", "run-1", 1, { state: "gated" });
  assertEquals(parseItem(Deno.readTextFileSync(itemPath)).state, "gated");
});

Deno.test("chainWrite на застарілому epoch НЕ пише нічого — старий воркер відсічений", () => {
  const { repo, itemPath } = fixture();
  claim(repo, "pact-001.m2.x", "run-1", 1000);
  claim(repo, "pact-001.m2.x", "run-1", 2000); // реклейм тим самим run_id
  assertThrows(
    () => chainWrite(repo, itemPath, "pact-001.m2.x", "run-1", 1, { state: "done" }),
    CasMismatch,
  );
  assertEquals(parseItem(Deno.readTextFileSync(itemPath)).state, "running");
});

Deno.test("НАМІР ПЕРЕД ЕФЕКТОМ: state merging + pr + head_sha вже на диску, коли ефект стартує", () => {
  const { repo, itemPath } = fixture();
  claim(repo, "pact-001.m2.x", "run-1", 1000);

  let seenDuringEffect: ReturnType<typeof parseItem> | null = null;
  withIntent(
    repo,
    itemPath,
    "pact-001.m2.x",
    "run-1",
    1,
    { state: "merging", pr: 51, head_sha: "sha-head" },
    () => {
      // цю мить імітує SIGKILL у сценарії (а)
      seenDuringEffect = parseItem(Deno.readTextFileSync(itemPath));
      return "effect-done";
    },
  );

  assertEquals(seenDuringEffect!.state, "merging");
  assertEquals(seenDuringEffect!.pr, 51);
  assertEquals(seenDuringEffect!.head_sha, "sha-head");
});

Deno.test("withIntent повертає значення ефекту", () => {
  const { repo, itemPath } = fixture();
  claim(repo, "pact-001.m2.x", "run-1", 1000);
  const out = withIntent(repo, itemPath, "pact-001.m2.x", "run-1", 1, { state: "merging" }, () => 42);
  assertEquals(out, 42);
});

Deno.test("розбіжність fence → ефект НЕ виконується взагалі", () => {
  const { repo, itemPath } = fixture();
  claim(repo, "pact-001.m2.x", "run-1", 1000);
  claim(repo, "pact-001.m2.x", "run-2", 2000);

  let effectRan = false;
  assertThrows(
    () =>
      withIntent(repo, itemPath, "pact-001.m2.x", "run-1", 1, { state: "merging" }, () => {
        effectRan = true;
      }),
    CasMismatch,
  );
  assertEquals(effectRan, false, "дія з ефектом при розбіжності fence заборонена (§4.1 п.3)");
  assertEquals(parseItem(Deno.readTextFileSync(itemPath)).state, "running");
});

Deno.test("падіння ефекту лишає намір на диску — саме він дає реконсиляції зачіпку", () => {
  const { repo, itemPath } = fixture();
  claim(repo, "pact-001.m2.x", "run-1", 1000);
  assertThrows(() =>
    withIntent(repo, itemPath, "pact-001.m2.x", "run-1", 1, { state: "merging", pr: 51 }, () => {
      throw new Error("процес убито під час мержу");
    })
  );
  const it = parseItem(Deno.readTextFileSync(itemPath));
  assertEquals(it.state, "merging");
  assertEquals(it.pr, 51);
});

Deno.test("fence перевіряється ПЕРЕД записом наміру, а не після", () => {
  const { repo, itemPath } = fixture();
  // лізи немає взагалі
  assertThrows(
    () => withIntent(repo, itemPath, "pact-001.m2.x", "run-1", 1, { state: "merging" }, () => {}),
    CasMismatch,
  );
  assertEquals(parseItem(Deno.readTextFileSync(itemPath)).state, "running");
});
