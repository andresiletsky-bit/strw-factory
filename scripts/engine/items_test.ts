// Тести читання/запису item-файлів. Спека v2 §3.3.
//
// Головна вимога до ЗАПИСУ: item-файли містять коментарі, які W0a лишила навмисно
// («НОТАТКА W0a → W0b (не видаляти без рішення)») і багаторядкові acceptance.
// Повний YAML round-trip їх знищив би. Тому запис — хірургічний, порядковий.
import { assertEquals, assertStringIncludes, assertThrows } from "jsr:@std/assert@1";
import { parseItem, setFields } from "./lib/items.ts";

const SAMPLE = `schema_version: 1
id: pact-001.m2.formed-labels
product: pact-001
lane: ios-ui
also_touches: [kmp-common]
state: ready
repo: pact-ios
branch: cycle/m2-formed-labels
size: S
acceptance: |
  - рядок один: state: НЕ ключ, а текст
  - рядок два
acceptance_basis:
  sources:
    - "design-spec.md#Б.5"
  verified_against_decisions_log_at: 2026-07-28T19:05Z
lease: {run_id: null, epoch: 0, heartbeat: null}
evidence: {run_id: null, commit_sha: null, cwd: null, toolchain: null, exit_code: null, ci_run_url: null}
attempts: 0
# НОТАТКА W0a → W0b (не видаляти без рішення).
# Друга смуга збережена машиночитно в also_touches.
`;

Deno.test("парсер читає скалярні поля верхнього рівня", () => {
  const it = parseItem(SAMPLE);
  assertEquals(it.id, "pact-001.m2.formed-labels");
  assertEquals(it.state, "ready");
  assertEquals(it.lane, "ios-ui");
  assertEquals(it.repo, "pact-ios");
  assertEquals(it.branch, "cycle/m2-formed-labels");
  assertEquals(it.attempts, 0);
});

Deno.test("парсер читає inline-послідовність also_touches — без неї гейт рівня 4 впаде", () => {
  assertEquals(parseItem(SAMPLE).also_touches, ["kmp-common"]);
});

Deno.test("парсер читає inline-мапу lease", () => {
  const l = parseItem(SAMPLE).lease;
  assertEquals(l, { run_id: null, epoch: 0, heartbeat: null });
});

Deno.test("парсер НЕ приймає за ключ те, що лежить у блочному літералі acceptance", () => {
  // `state: НЕ ключ` усередині `acceptance: |` — наївний рядковий парсер зчитав би його
  // як state і зіпсував планування.
  assertEquals(parseItem(SAMPLE).state, "ready");
});

// Мутаційна проба: вимкнення гілки блочного літерала лишало тест вище зеленим —
// його рятував відступ, а не код, який він нібито пінить. Acceptance мусить читатись
// як ТЕКСТ; без цього checker дістає об'єкт-сміття замість критеріїв приймання.
Deno.test("блочний літерал читається як цілий текст, а не як вкладена мапа", () => {
  const a = parseItem(SAMPLE).acceptance;
  assertEquals(typeof a, "string");
  assertStringIncludes(a as string, "- рядок один: state: НЕ ключ, а текст");
  assertStringIncludes(a as string, "- рядок два");
});

// Мутаційна проба: вимкнення stripComment лишало все зеленим, бо SAMPLE не мав
// хвостових коментарів — а РЕАЛЬНІ item-файли мають. Пін іде по живому файлу.
Deno.test("хвостовий коментар не потрапляє у значення inline-послідовності", () => {
  const it = parseItem("schema_version: 1\nalso_touches: [kmp-common]   # див. НОТАТКУ нижче\n");
  assertEquals(it.also_touches, ["kmp-common"]);
});

Deno.test("хвостовий коментар не потрапляє у значення скаляра", () => {
  const it = parseItem("schema_version: 1\nstate: ready   # ще не стартував\n");
  assertEquals(it.state, "ready");
});

Deno.test("`#` усередині лапок — частина значення, не початок коментаря", () => {
  const it = parseItem('schema_version: 1\nsrc: "design-spec.md#Б.5"   # рядок 293\n');
  assertEquals(it.src, "design-spec.md#Б.5");
});

// Мутаційна проба: splitTop без лічильника глибини різав по комах усередині вкладених
// дужок. Сьогодні жоден item такого не має, але lease/evidence — inline-мапи, і поява
// списку в них тихо зіпсувала б розбір.
Deno.test("кома всередині вкладених дужок не ділить inline-мапу", () => {
  const it = parseItem("schema_version: 1\nevidence: {tags: [a, b], exit_code: 0}\n");
  assertEquals(it.evidence, { tags: ["a", "b"], exit_code: 0 });
});

Deno.test("парсер читає вкладений acceptance_basis", () => {
  const b = parseItem(SAMPLE).acceptance_basis;
  assertEquals(b?.verified_against_decisions_log_at, "2026-07-28T19:05Z");
  assertEquals(b?.sources, ["design-spec.md#Б.5"]);
});

Deno.test("парсер читає blocked_by як inline-послідовність", () => {
  const it = parseItem(
    "schema_version: 1\nid: x\nstate: blocked\nblocked_by: [item:a, decision:d-014]\n",
  );
  assertEquals(it.blocked_by, ["item:a", "decision:d-014"]);
});

Deno.test("відсутність schema_version — помилка, а не мовчазний дефолт", () => {
  assertThrows(() => parseItem("id: x\nstate: ready\n"), Error, "schema_version");
});

Deno.test("запис змінює лише названі поля й лишає решту байт у спокої", () => {
  const out = setFields(SAMPLE, { state: "merge-pending", attempts: 3 });
  assertEquals(parseItem(out).state, "merge-pending");
  assertEquals(parseItem(out).attempts, 3);
  assertEquals(parseItem(out).id, "pact-001.m2.formed-labels");
  assertStringIncludes(out, "# НОТАТКА W0a → W0b (не видаляти без рішення).");
  assertStringIncludes(out, "  - рядок один: state: НЕ ключ, а текст");
  assertStringIncludes(out, 'sources:\n    - "design-spec.md#Б.5"');
});

Deno.test("запис поля, якого у файлі ще немає, додає його — pr/head_sha/merge_commit", () => {
  const out = setFields(SAMPLE, { pr: 51, head_sha: "abc123", merge_commit: "def456" });
  const it = parseItem(out);
  assertEquals(it.pr, 51);
  assertEquals(it.head_sha, "abc123");
  assertEquals(it.merge_commit, "def456");
});

Deno.test("запис inline-мапи lease перезаписує рядок цілком, не приписує другий", () => {
  const out = setFields(SAMPLE, {
    lease: { run_id: "run-7", epoch: 4, heartbeat: 1738000000000 },
  });
  assertEquals(out.match(/^lease:/gm)?.length, 1);
  assertEquals(parseItem(out).lease, {
    run_id: "run-7",
    epoch: 4,
    heartbeat: 1738000000000,
  });
});

Deno.test("запис null пише YAML-null, а не рядок 'null'", () => {
  const out = setFields(SAMPLE, { blocked_since: null });
  assertEquals(parseItem(out).blocked_since, null);
  assertStringIncludes(out, "blocked_since: null");
});

Deno.test("рядок із двокрапкою або # береться в лапки, інакше файл ламається", () => {
  const out = setFields(SAMPLE, { note: "a: b # c" });
  assertEquals(parseItem(out).note, "a: b # c");
});

Deno.test("файл лишається валідним для повторного розбору після серії записів", () => {
  let s = SAMPLE;
  s = setFields(s, { state: "merging", pr: 51, head_sha: "sha-1" });
  s = setFields(s, { state: "done", merge_commit: "sha-merge" });
  s = setFields(s, { attempts: 2 });
  const it = parseItem(s);
  assertEquals(it.state, "done");
  assertEquals(it.pr, 51);
  assertEquals(it.merge_commit, "sha-merge");
  assertEquals(it.attempts, 2);
  assertEquals(it.also_touches, ["kmp-common"]);
  assertStringIncludes(s, "# НОТАТКА W0a → W0b (не видаляти без рішення).");
});

Deno.test("реальні 14 елементів реєстру розбираються без винятків", () => {
  const dir = "/Users/Andrew/Developer/STRW/strw-state/engine/items";
  const files = [...Deno.readDirSync(dir)].filter((e) => e.name.endsWith(".yaml"));
  assertEquals(files.length, 14);
  for (const f of files) {
    const it = parseItem(Deno.readTextFileSync(`${dir}/${f.name}`));
    assertEquals(typeof it.id, "string", `${f.name}: немає id`);
    assertEquals(typeof it.state, "string", `${f.name}: немає state`);
    assertEquals(typeof it.repo, "string", `${f.name}: немає repo`);
    assertEquals(typeof it.lease?.epoch, "number", `${f.name}: немає lease.epoch`);
  }
});
