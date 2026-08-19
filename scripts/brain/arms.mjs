#!/usr/bin/env -S deno run --allow-read --allow-write --allow-env
// arms.mjs — ARMS-шар графа: Applications · Routines · Memory · Skills.
//
// НУЛЬ LLM, НУЛЬ мережі, НУЛЬ залежностей. Кожен вузол генерується з РЕАЛЬНОГО
// джерела; те, що програмно не читається, стає стабом із TODO, а не вигадкою.
//
// ЧОМУ ЦЕЙ ШАР ТІЛЬКИ ГЕНЕРУЄТЬСЯ.
// Скіли, агенти, розклади й доступи змінюються щотижня, а нотатка про них —
// ні. Рукописний опис розходиться з реальністю мовчки: рівно так секція
// «Чекає рішення Andrii» в 🧠 STRW Home три тижні стверджувала, що tea-001
// чекає G1, коли той був заморожений. Тому кожен файл тут несе заголовок
// «не редагувати рукою», а джерело названо в самому файлі.
//
// Usage: arms.mjs [--state <dir>] [--factory <dir>] [--dry-run]

import fs from "node:fs";
import path from "node:path";
import { slugify } from "./lib.mjs";

const argv = process.argv.slice(2);
const val = (f) => { const i = argv.indexOf(f); return i === -1 ? null : argv[i + 1]; };
const HOME = process.env.HOME ?? "";
const STATE = path.resolve(val("--state") ?? path.join(HOME, "Developer/STRW/strw-state"));
const FACTORY = path.resolve(val("--factory") ?? path.join(HOME, "Developer/STRW/strw-factory"));
const MEMDIR = val("--memory") ?? path.join(HOME, ".claude/projects/-Users-Andrew-Developer-STRW/memory");
const SETTINGS = val("--settings") ?? path.join(HOME, ".claude/settings.json");
const DRY = argv.includes("--dry-run");
const OUT = path.join(STATE, "_brain", "arms");
// Дата приходить аргументом, а не з годинника: інакше кожна перегенерація
// давала б інший діф і `--check` не міг би відрізнити «протухло» від «інша
// хвилина». Той самий мотив, що й у решті генераторів фабрики.
const TODAY = val("--today") ?? "2026-08-19";

const HEAD = (src) =>
  `> ⚙️ Згенеровано \`scripts/brain/arms.mjs\` — **не редагувати рукою**.\n> Джерело: ${src}\n`;

const slug = (s) => slugify(s, 60);
const fmOf = (t) => {
  const m = t.match(/^---\n([\s\S]*?)\n---/);
  const o = {};
  if (m) for (const l of m[1].split("\n")) {
    const kv = l.match(/^([a-z_][\w-]*):\s*(.*)$/i);
    if (kv) o[kv[1]] = kv[2].trim().replace(/^["']|["']$/g, "");
  }
  return o;
};
const files = [];
const seen = new Set();
// Колізія імен мовчки з'їдає вузол: перший прогін дав 49 файлів проти 50
// згенерованих, і побачити це можна було лише порахувавши. Тепер падає.
const emit = (rel, text) => {
  if (seen.has(rel)) throw new Error(`колізія імені вузла: ${rel} — два джерела дають той самий шлях`);
  seen.add(rel);
  files.push({ rel, text });
};

// ── S: скіли й агенти з реального репо плагіна ─────────────────────────────
function skills() {
  const dir = path.join(FACTORY, "skills");
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir).filter((d) => fs.existsSync(path.join(dir, d, "SKILL.md"))).map((d) => {
    const fm = fmOf(fs.readFileSync(path.join(dir, d, "SKILL.md"), "utf8"));
    return { name: fm.name ?? d, version: fm.version ?? "—", desc: fm.description ?? "" };
  });
}
function agents() {
  const dir = path.join(FACTORY, "agents");
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir).filter((f) => f.endsWith(".md")).map((f) => {
    const fm = fmOf(fs.readFileSync(path.join(dir, f), "utf8"));
    return { name: fm.name ?? f.replace(/\.md$/, ""), model: fm.model ?? "—", desc: fm.description ?? "" };
  });
}

// ── R: розклади з пульта автоматизації ─────────────────────────────────────
// Джерело — таблиця в `⏰ Автоматизація.md`, яку веде людина. Це свідомо: сам
// список тасків програмно з Mac не читається (він у хмарі), тож пульт лишається
// джерелом, а ARMS робить із нього вузли й показує ДАТУ ЗВІРКИ — щоб протухання
// було видно, а не приховане.
function routines() {
  const p = path.join(STATE, "_brain", "⏰ Автоматизація.md");
  if (!fs.existsSync(p)) return { rows: [], checked: null };
  const t = fs.readFileSync(p, "utf8");
  const checked = (t.match(/Звірено `list_triggers` (\d{4}-\d{2}-\d{2})/) ?? [])[1] ?? null;
  const rows = t.split("\n")
    .filter((l) => /^\| `[^`]+` \|/.test(l))
    .map((l) => l.split("|").map((c) => c.trim()).filter(Boolean))
    .filter((c) => c.length >= 4)
    .map((c) => ({ task: c[0].replace(/`/g, ""), when: c[1], cron: c[2], loop: c[3], writes: c[4] ?? "—" }));
  return { rows, checked };
}

// ── A: застосунки/плагіни з локальних конфігів ─────────────────────────────
// Читаємо ЛИШЕ імена. Значення з `~/.claude.json` не торкаємось узагалі:
// там бувають токени, а data-policy §4 і скан секретів у pre-commit існують
// саме для цього класу помилок.
function applications() {
  const out = [];
  try {
    const s = JSON.parse(fs.readFileSync(SETTINGS, "utf8"));
    for (const p of Object.keys(s.enabledPlugins ?? {})) out.push({ name: p, kind: "plugin", src: "~/.claude/settings.json" });
  } catch { /* конфіг відсутній — нижче буде стаб */ }
  return out;
}

// ── M: дзеркало-індекс пам'яті ─────────────────────────────────────────────
// Дзеркало, а не копія: імена й описи, без тіл. Тіла — окремий силос, і
// дублювати їх у git означало б завести другу копію, що розійдеться.
function memory() {
  if (!fs.existsSync(MEMDIR)) return [];
  return fs.readdirSync(MEMDIR).filter((f) => f.endsWith(".md") && f !== "MEMORY.md").map((f) => {
    const fm = fmOf(fs.readFileSync(path.join(MEMDIR, f), "utf8"));
    return { name: fm.name ?? f.replace(/\.md$/, ""), desc: fm.description ?? "", type: fm.type ?? "" };
  });
}

// ── Побудова ───────────────────────────────────────────────────────────────
const S = skills(), AG = agents(), R = routines(), A = applications(), M = memory();

const node = (dir, id, type, title, src, body, extraTags = []) => emit(
  path.join("_brain", "arms", dir, `${slug(id)}.md`),
  // id — той самий слаг, що й ім'я файлу: id із пробілами ламає вікі-лінки,
  // а розбіжність між id і шляхом робить граф неоднозначним.
  ["---", `id: ${slug(id)}`, `type: ${type}`, `updated: ${TODAY}`,
   'up: "[[ARMS]]"',
   `tags: [${[...new Set([`type/${type}`, "scope/factory", ...extraTags])].join(", ")}]`, "---", "",
   `# ${title}`, "", HEAD(src), "", body, ""].join("\n"),
);

for (const s of S) node("skills", `skill-${s.name}`, "skill", `🧠 ${s.name}`,
  "`strw-factory/skills/<name>/SKILL.md` (frontmatter)",
  [`**Версія:** ${s.version}`, "", s.desc].join("\n"));

for (const a of AG) node("skills", `agent-${a.name}`, "agent", `🤖 ${a.name}`,
  "`strw-factory/agents/*.md` (frontmatter)",
  [`**Модель за замовчуванням:** ${a.model}`, "", a.desc].join("\n"));

for (const r of R.rows) node("routines", `routine-${r.task}`, "routine", `⏰ ${r.task}`,
  "`_brain/⏰ Автоматизація.md` (таблиця пульта)",
  [`**Коли:** ${r.when} · **cron:** ${r.cron}`, `**Петля/дія:** ${r.loop}`, `**Пише:** ${r.writes}`, "",
   R.checked ? `Звірено з \`list_triggers\`: **${R.checked}**. Якщо дата стара — вузол показує стан пульта, не хмари.`
             : "⚠️ TODO: у пульті немає дати звірки з `list_triggers` — свіжість невідома."].join("\n"),
  ["type/routine"]);

for (const a of A) node("applications", `app-${a.name}`, "application", `🔌 ${a.name}`,
  `\`${a.src}\``,
  [`**Рід:** ${a.kind}`, "", "**До чого має доступ:** TODO — рівень доступу плагіна локальний конфіг не описує."].join("\n"),
  ["type/application"]);

for (const m of M) node("memory", `mem-${m.name}`, "reference", `💾 ${m.name}`,
  "пам'ять Cowork (дзеркало імен і описів, без тіл)",
  [`**Рід:** ${m.type || "—"}`, "", m.desc].join("\n"));

// MOC розділу
const moc = [
  "---", "id: arms", "type: moc", `updated: ${TODAY}`,
  'up: "[[🧠 STRW Home]]"', "tags: [type/moc, scope/factory]", "---", "",
  "# ARMS — чим фабрика вміє діяти", "", HEAD("`scripts/brain/arms.mjs`"), "",
  "Чотири роди вузлів: **A**pplications · **R**outines · **M**emory · **S**kills.",
  "Шар закриває сліпу пляму графа: продукти й рішення були картографовані, а те,",
  "ЧИМ вони робляться — ні.", "",
  `## 🧠 Skills та агенти (${S.length + AG.length})`, "",
  ...S.map((s) => `- [[skill-${slug(s.name)}|${s.name}]] — ${s.desc.slice(0, 90)}`),
  ...AG.map((a) => `- [[agent-${slug(a.name)}|${a.name}]] (${a.model})`),
  "", `## ⏰ Routines (${R.rows.length})`, "",
  R.checked ? `Звірено з хмарою **${R.checked}**.` : "⚠️ Дата звірки з `list_triggers` невідома.",
  ...R.rows.map((r) => `- [[routine-${slug(r.task)}|${r.task}]] — ${r.when} · ${r.loop}`),
  "", `## 🔌 Applications (${A.length})`, "",
  ...A.map((a) => `- [[app-${slug(a.name)}|${a.name}]]`),
  "", "> ⚠️ **Неповно, і це названо явно.** Локальні конфіги описують лише плагіни.",
  "> Конектори рівня сесії (claude.ai) у `~/.claude.json` не зберігаються, тож",
  "> поверхня доступів тут НЕ повна. Дочитати її можна лише з інтерфейсу —",
  "> це TODO, а не пропуск: саме поле «до чого має доступ» є входом у data-policy.",
  "", `## 💾 Memory (${M.length})`, "",
  "Дзеркало імен і описів пам'яті Cowork — тіла лишаються в своєму силосі.",
  ...M.slice(0, 40).map((m) => `- [[mem-${slug(m.name)}|${m.name}]] — ${m.desc.slice(0, 80)}`),
  "",
].join("\n");
emit(path.join("_brain", "arms", "ARMS.md"), moc);

if (DRY) {
  console.log("arms --dry-run · НІЧОГО НЕ ЗАПИСАНО\n");
  console.log(`  skills   ${String(S.length).padStart(3)}   agents ${AG.length}`);
  console.log(`  routines ${String(R.rows.length).padStart(3)}   звірено ${R.checked ?? "невідомо"}`);
  console.log(`  apps     ${String(A.length).padStart(3)}   (неповно — конектори сесії не в конфігу)`);
  console.log(`  memory   ${String(M.length).padStart(3)}`);
  console.log(`\n  файлів до запису: ${files.length}`);
} else {
  // Шар перебудовується ЦІЛКОМ: вузол, чиє джерело зникло, не має пережити
  // перегенерацію — інакше граф накопичує привидів.
  if (fs.existsSync(OUT)) fs.rmSync(OUT, { recursive: true });
  for (const f of files) {
    const abs = path.join(STATE, f.rel.replace(/^_brain/, "_brain"));
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, f.text);
  }
  console.log(`arms: ${files.length} файлів → _brain/arms/`);
}
