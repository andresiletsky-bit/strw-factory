// Ексклюзивні resources і непересічність — спека v2 §3.4 рівні 1–4.
//
// Інцидент 27.07 у pact-ios: два формально незалежні цикли в одному чекауті,
// кожен дотримався правила «ніколи два xcodebuild» УСЕРЕДИНІ СЕБЕ — і все одно
// «324/366 з 7 фейлами» плюс фантомний TEST FAILED. Дослівний висновок запису:
// «every intermediate number was fiction».
// Файлова непересічність цього не ловить. Ловить лише лок на РЕСУРС.
import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  acquireResources,
  disjointOrThrow,
  effectivePaths,
  IsolationConflict,
  ownsOf,
  pathsOverlap,
  releaseResources,
  resourcesOf,
} from "./lib/resources.ts";

const LANES = {
  "ios-ui": {
    id: "ios-ui",
    repo: "pact-ios",
    owns: ["App/Sources/**", "App/Tests/**", "PactDesignKit/**"],
    resources: ["xcodebuild", "simulator", "derived-data"],
  },
  "kmp-common": {
    id: "kmp-common",
    repo: "pact-ios",
    owns: ["shared/src/commonMain/**", "shared/src/jvmMain/**", "shared/src/jvmTest/**"],
    resources: ["gradle-cache"],
  },
  backend: {
    id: "backend",
    repo: "pact-backend",
    owns: ["backend/supabase/functions/**", "backend/supabase/tests/**"],
    resources: ["supabase-db"],
  },
};
const SHARED = ["contract/**", "App/project.yml", "**/Package.resolved"];

function tmpDir(): string {
  return Deno.makeTempDirSync({ prefix: "engine-res-" });
}

// ── Рівень 3: ексклюзивні ресурси ───────────────────────────────────────────────

Deno.test("ресурс береться ексклюзивно: другий претендент відхиляється", () => {
  const d = tmpDir();
  assertEquals(acquireResources(d, ["xcodebuild"], "run-1", 1000).ok, true);
  assertEquals(acquireResources(d, ["xcodebuild"], "run-2", 1000).ok, false);
});

Deno.test("конфлікт називає і ресурс, і власника — інакше діагностика неможлива", () => {
  const d = tmpDir();
  acquireResources(d, ["xcodebuild", "simulator"], "run-1", 1000);
  const r = acquireResources(d, ["simulator"], "run-2", 1000);
  assertEquals(r.ok, false);
  assertEquals(r.conflicts, [{ resource: "simulator", held_by: "run-1" }]);
});

Deno.test("часткове взяття НЕ лишає напівзахоплених ресурсів", () => {
  const d = tmpDir();
  acquireResources(d, ["simulator"], "run-1", 1000);
  const r = acquireResources(d, ["xcodebuild", "simulator"], "run-2", 1000);
  assertEquals(r.ok, false);
  // xcodebuild мусить лишитись вільним, інакше run-2 «отруїв» ресурс, якого не отримав
  assertEquals(acquireResources(d, ["xcodebuild"], "run-3", 1000).ok, true);
});

Deno.test("після release ресурс знову вільний", () => {
  const d = tmpDir();
  acquireResources(d, ["supabase-db"], "run-1", 1000);
  releaseResources(d, ["supabase-db"], "run-1");
  assertEquals(acquireResources(d, ["supabase-db"], "run-2", 1000).ok, true);
});

Deno.test("release чужого локу не звільняє його", () => {
  const d = tmpDir();
  acquireResources(d, ["supabase-db"], "run-1", 1000);
  releaseResources(d, ["supabase-db"], "run-ЧУЖИЙ");
  assertEquals(acquireResources(d, ["supabase-db"], "run-2", 1000).ok, false);
});

Deno.test("протухлий лок ресурсу перехоплюється — інакше мертвий процес блокує назавжди", () => {
  const d = tmpDir();
  acquireResources(d, ["xcodebuild"], "run-1", 1000);
  const r = acquireResources(d, ["xcodebuild"], "run-2", 1000 + 6 * 60 * 1000);
  assertEquals(r.ok, true);
});

Deno.test("той самий власник бере свій лок повторно (реентрантність у межах ланцюжка)", () => {
  const d = tmpDir();
  acquireResources(d, ["xcodebuild"], "run-1", 1000);
  assertEquals(acquireResources(d, ["xcodebuild"], "run-1", 2000).ok, true);
});

// ── Рівень 3: ресурси елемента = смуга + also_touches ────────────────────────────

Deno.test("resourcesOf об'єднує ресурси основної смуги й also_touches", () => {
  const rs = resourcesOf({ lane: "ios-ui", also_touches: ["kmp-common"] }, LANES);
  assertEquals(rs.sort(), ["derived-data", "gradle-cache", "simulator", "xcodebuild"]);
});

Deno.test("два елементи різних смуг ОДНОГО репо конфліктують по ресурсу, не по шляхах", () => {
  // Це і є інцидент 27.07: ios-ui і kmp-common не перетинаються по ВЛАСНИХ шляхах…
  // (звірка йде по owns, не по effectivePaths: останній містить shared, тож будь-які
  // дві смуги там завжди «перетинаються» і доказ був би вакуумно хибним)
  assertEquals(
    pathsOverlap(ownsOf({ lane: "ios-ui" }, LANES), ownsOf({ lane: "kmp-common" }, LANES)),
    false,
  );
  // …а shared спільний у них ЗАВЖДИ — саме тому він серіалізує, а не доводить перетин
  assertEquals(
    pathsOverlap(
      effectivePaths({ lane: "ios-ui" }, LANES, SHARED),
      effectivePaths({ lane: "kmp-common" }, LANES, SHARED),
    ),
    true,
  );
  // …але елемент із also_touches тягне обидва набори ресурсів, і паралельний
  // ios-ui-елемент більше не пройде.
  const d = tmpDir();
  const a = resourcesOf({ lane: "ios-ui", also_touches: ["kmp-common"] }, LANES);
  assertEquals(acquireResources(d, a, "run-1", 1000).ok, true);
  assertEquals(acquireResources(d, resourcesOf({ lane: "ios-ui" }, LANES), "run-2", 1000).ok, false);
});

Deno.test("backend і ios-ui не ділять жодного ресурсу — це і є єдиний реальний паралелізм", () => {
  const d = tmpDir();
  assertEquals(acquireResources(d, resourcesOf({ lane: "ios-ui" }, LANES), "run-1", 1000).ok, true);
  assertEquals(acquireResources(d, resourcesOf({ lane: "backend" }, LANES), "run-2", 1000).ok, true);
});

// ── Рівень 1–2: шляхи ───────────────────────────────────────────────────────────

Deno.test("effectivePaths = owns(lane) ∪ owns(also_touches) ∪ shared", () => {
  const p = effectivePaths({ lane: "ios-ui", also_touches: ["kmp-common"] }, LANES, SHARED);
  assertEquals(p.includes("App/Sources/**"), true);
  assertEquals(p.includes("shared/src/commonMain/**"), true);
  assertEquals(p.includes("contract/**"), true);
});

Deno.test("непересічність доводиться по owns; shared не рахується перетином, він серіалізує", () => {
  disjointOrThrow(
    [{ id: "a", lane: "ios-ui" }, { id: "b", lane: "backend" }],
    LANES,
    SHARED,
  );
});

Deno.test("два елементи однієї смуги — пряма пересічність, планувати разом заборонено", () => {
  assertThrows(
    () => disjointOrThrow([{ id: "a", lane: "ios-ui" }, { id: "b", lane: "ios-ui" }], LANES, SHARED),
    IsolationConflict,
  );
});

Deno.test("елемент із also_touches пересікається з елементом тієї другої смуги", () => {
  assertThrows(
    () =>
      disjointOrThrow(
        [{ id: "a", lane: "ios-ui", also_touches: ["kmp-common"] }, { id: "b", lane: "kmp-common" }],
        LANES,
        SHARED,
      ),
    IsolationConflict,
  );
});

// Мутаційна проба: вимкнення перевірки owns лишало все зеленим — у кожному тесті
// пересічні смуги ділили ще й ресурс, і падіння приходило звідти. Тут ресурси
// НАВМИСНО різні, тож упасти може тільки перевірка шляхів.
Deno.test("збіг owns при РІЗНИХ ресурсах усе одно заборонений", () => {
  const lanes = {
    ...LANES,
    "ios-docs": {
      id: "ios-docs",
      repo: "pact-ios",
      owns: ["App/Sources/**"], // той самий шлях, що й в ios-ui
      resources: ["docs-build"], // ресурс інший — конфлікт видно лише по owns
    },
  };
  assertThrows(
    () => disjointOrThrow([{ id: "a", lane: "ios-ui" }, { id: "b", lane: "ios-docs" }], lanes, SHARED),
    IsolationConflict,
    "App/Sources/**",
  );
});

Deno.test("збіг owns при повній відсутності ресурсів у обох смугах — теж заборонений", () => {
  const lanes = {
    ...LANES,
    "a-lane": { id: "a-lane", repo: "r", owns: ["src/**"], resources: [] },
    "b-lane": { id: "b-lane", repo: "r", owns: ["src/**"], resources: [] },
  };
  assertThrows(
    () => disjointOrThrow([{ id: "a", lane: "a-lane" }, { id: "b", lane: "b-lane" }], lanes, SHARED),
    IsolationConflict,
    "src/**",
  );
});

Deno.test("непересічність по ШЛЯХАХ не рятує, коли збігається РЕСУРС", () => {
  // ios-ui і kmp-common мають різні owns, але якби kmp-common теж тримав xcodebuild,
  // паралельний запуск відтворив би 27.07. Доказ мусить падати саме тут.
  const lanes = { ...LANES, "kmp-common": { ...LANES["kmp-common"], resources: ["gradle-cache", "xcodebuild"] } };
  assertThrows(
    () => disjointOrThrow([{ id: "a", lane: "ios-ui" }, { id: "b", lane: "kmp-common" }], lanes, SHARED),
    IsolationConflict,
    "xcodebuild",
  );
});

Deno.test("одинокий елемент завжди непересічний сам із собою", () => {
  disjointOrThrow([{ id: "a", lane: "ios-ui" }], LANES, SHARED);
});

Deno.test("невідома смуга — помилка конфігурації, а не «нічим не володію»", () => {
  // v1 мала два неіснуючі шляхи з чотирьох, і доказ непересічності над ними був
  // ВАКУУМНО істинним: завжди PASS, нульовий захист.
  assertThrows(
    () => disjointOrThrow([{ id: "a", lane: "смуги-немає" }], LANES, SHARED),
    IsolationConflict,
  );
});

Deno.test("смуга без жодного owns — помилка конфігурації, а не вакуумний PASS", () => {
  const lanes = { ...LANES, empty: { id: "empty", repo: "pact-ios", owns: [], resources: [] } };
  assertThrows(
    () => disjointOrThrow([{ id: "a", lane: "empty" }], lanes, SHARED),
    IsolationConflict,
  );
});
