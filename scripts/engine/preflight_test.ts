// Фаза 0 Preflight — спека v2 §3.1 і §4.
//
// ЖОРСТКИЙ ІНВАРІАНТ: `strw-state` незаписуваний АБО має незапушені коміти →
// тік НЕ ПОЧИНАЄТЬСЯ. Не «завершується чисто» — не починається. Формулювання зі
// спеки дослівне, і воно тут пінується як окремий тест на кожну половину «або».
import { assertEquals } from "jsr:@std/assert@1";
import { hasUnpushedCommits, isWritable, preflight } from "./lib/preflight.ts";

function sh(cwd: string, cmd: string[]): void {
  const r = new Deno.Command(cmd[0], { args: cmd.slice(1), cwd, stdout: "piped", stderr: "piped" })
    .outputSync();
  if (!r.success) throw new Error(`${cmd.join(" ")}: ${new TextDecoder().decode(r.stderr)}`);
}

/** Справжня пара «bare-віддалений + клон», щоб «запушено» означало запушено. */
function clonedRepo(): { root: string; remote: string } {
  const base = Deno.makeTempDirSync({ prefix: "engine-pre-" });
  const remote = `${base}/remote.git`;
  const root = `${base}/work`;
  Deno.mkdirSync(remote, { recursive: true });
  sh(remote, ["git", "init", "-q", "--bare", "-b", "main"]);
  sh(base, ["git", "clone", "-q", remote, "work"]);
  sh(root, ["git", "config", "user.email", "engine@strw.local"]);
  sh(root, ["git", "config", "user.name", "engine"]);
  Deno.writeTextFileSync(`${root}/a.md`, "base\n");
  sh(root, ["git", "add", "-A"]);
  sh(root, ["git", "commit", "-qm", "base"]);
  sh(root, ["git", "push", "-q", "-u", "origin", "main"]);
  return { root, remote };
}

Deno.test("чистий запушений репозиторій — незапушених комітів немає", () => {
  const { root } = clonedRepo();
  assertEquals(hasUnpushedCommits(root), false);
});

Deno.test("локальний коміт без push — незапушені коміти Є", () => {
  const { root } = clonedRepo();
  Deno.writeTextFileSync(`${root}/b.md`, "нове\n");
  sh(root, ["git", "add", "-A"]);
  sh(root, ["git", "commit", "-qm", "локально"]);
  assertEquals(hasUnpushedCommits(root), true);
});

// Мутаційна проба: `невідомий origin → false` переживав усі тести, бо в кожному
// віддалений існував. Це найнебезпечніший дефолт із можливих: «не знаю стану
// віддаленого» перетворювалось на «можна писати».
Deno.test("репозиторій БЕЗ віддаленого — вважається таким, що має незапушені коміти", () => {
  const root = Deno.makeTempDirSync({ prefix: "engine-noremote-" });
  sh(root, ["git", "init", "-q", "-b", "main"]);
  sh(root, ["git", "config", "user.email", "engine@strw.local"]);
  sh(root, ["git", "config", "user.name", "engine"]);
  Deno.writeTextFileSync(`${root}/a.md`, "base\n");
  sh(root, ["git", "add", "-A"]);
  sh(root, ["git", "commit", "-qm", "base"]);
  assertEquals(hasUnpushedCommits(root), true);
});

// Найтонший випадок: каталог узагалі не git-репозиторій. Тоді ОБИДВА rev-parse
// падають, обидва stdout порожні — і наївне порівняння «head === remote» дає
// РІВНІСТЬ, тобто «все запушено». Тік почався б поверх невідомо чого.
Deno.test("каталог, який не є git-репозиторієм, не рахується запушеним", () => {
  const root = Deno.makeTempDirSync({ prefix: "engine-nogit-" });
  assertEquals(hasUnpushedCommits(root), true);
});

Deno.test("ІНВАРІАНТ: нерозв'язний origin/main → тік НЕ починається", () => {
  const root = Deno.makeTempDirSync({ prefix: "engine-noremote2-" });
  sh(root, ["git", "init", "-q", "-b", "main"]);
  sh(root, ["git", "config", "user.email", "engine@strw.local"]);
  sh(root, ["git", "config", "user.name", "engine"]);
  Deno.writeTextFileSync(`${root}/a.md`, "base\n");
  sh(root, ["git", "add", "-A"]);
  sh(root, ["git", "commit", "-qm", "base"]);
  const r = preflight({ stateRepo: root, validate: () => ({ ok: true, output: "" }) });
  assertEquals(r.started, false);
});

Deno.test("записуваний каталог — isWritable true, і проба по собі прибирає", () => {
  const { root } = clonedRepo();
  assertEquals(isWritable(root), true);
  const left = [...Deno.readDirSync(root)].map((e) => e.name).filter((n) => n.includes("preflight"));
  assertEquals(left, []);
});

Deno.test("незаписуваний каталог — isWritable false (реальний chmod, не мок)", () => {
  const { root } = clonedRepo();
  Deno.chmodSync(root, 0o500);
  try {
    assertEquals(isWritable(root), false);
  } finally {
    Deno.chmodSync(root, 0o755);
  }
});

// ── Інваріант, обидві половини «або» ────────────────────────────────────────────

Deno.test("ІНВАРІАНТ: незаписуваний strw-state → тік НЕ починається", () => {
  const { root } = clonedRepo();
  Deno.chmodSync(root, 0o500);
  try {
    const r = preflight({ stateRepo: root, validate: () => ({ ok: true, output: "" }) });
    assertEquals(r.ok, false);
    assertEquals(r.started, false);
    assertEquals(r.stop_reason?.includes("незаписуваний"), true);
  } finally {
    Deno.chmodSync(root, 0o755);
  }
});

Deno.test("ІНВАРІАНТ: незапушені коміти в strw-state → тік НЕ починається", () => {
  const { root } = clonedRepo();
  Deno.writeTextFileSync(`${root}/b.md`, "нове\n");
  sh(root, ["git", "add", "-A"]);
  sh(root, ["git", "commit", "-qm", "локально"]);
  const r = preflight({ stateRepo: root, validate: () => ({ ok: true, output: "" }) });
  assertEquals(r.ok, false);
  assertEquals(r.started, false);
  assertEquals(r.stop_reason?.includes("незапушен"), true);
});

Deno.test("обидві умови зелені + валідатор зелений → тік починається", () => {
  const { root } = clonedRepo();
  const r = preflight({ stateRepo: root, validate: () => ({ ok: true, output: "OK" }) });
  assertEquals(r.ok, true);
  assertEquals(r.started, true);
});

Deno.test("червоний validate-items.sh зупиняє тік — реєстр не має права бути невалідним", () => {
  const { root } = clonedRepo();
  const r = preflight({
    stateRepo: root,
    validate: () => ({ ok: false, output: "STALE: acceptance_basis протух" }),
  });
  assertEquals(r.ok, false);
  assertEquals(r.stop_reason?.includes("реєстр"), true);
});

Deno.test("перевірка запису йде ПЕРШОЮ — на незаписуваному репо валідатор навіть не кличеться", () => {
  const { root } = clonedRepo();
  Deno.chmodSync(root, 0o500);
  let validateCalled = false;
  try {
    preflight({
      stateRepo: root,
      validate: () => {
        validateCalled = true;
        return { ok: true, output: "" };
      },
    });
    assertEquals(validateCalled, false);
  } finally {
    Deno.chmodSync(root, 0o755);
  }
});

Deno.test("зміна кількості елементів проти попереднього тіку фіксується, а не мовчить", () => {
  const { root } = clonedRepo();
  const r = preflight({
    stateRepo: root,
    validate: () => ({ ok: true, output: "" }),
    itemCount: 13,
    previousItemCount: 14,
  });
  assertEquals(r.ok, true);
  assertEquals(r.notes.some((n) => n.includes("14") && n.includes("13")), true);
});

Deno.test("однакова кількість елементів нотатки не породжує", () => {
  const { root } = clonedRepo();
  const r = preflight({
    stateRepo: root,
    validate: () => ({ ok: true, output: "" }),
    itemCount: 14,
    previousItemCount: 14,
  });
  assertEquals(r.notes.some((n) => n.includes("кількість")), false);
});

Deno.test("STOP несе причину текстом — мовчазна зупинка невідрізненна від успіху", () => {
  const { root } = clonedRepo();
  Deno.writeTextFileSync(`${root}/b.md`, "x\n");
  sh(root, ["git", "add", "-A"]);
  sh(root, ["git", "commit", "-qm", "l"]);
  const r = preflight({ stateRepo: root, validate: () => ({ ok: true, output: "" }) });
  assertEquals(typeof r.stop_reason, "string");
  assertEquals((r.stop_reason ?? "").length > 10, true);
});
