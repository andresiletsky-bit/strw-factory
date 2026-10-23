#!/usr/bin/env -S deno run --allow-read --allow-write --allow-env
// split-monoliths.mjs — «дієта» B1: моноліти strw-state стають типізованими вузлами
// з генерованим дайджест-фасадом на старому шляху.
//
// НУЛЬ залежностей, НУЛЬ мережі, НУЛЬ LLM. Рантайм — Deno (як решта scripts/),
// але код на node:-білтінах, тож той самий файл виконає і Node ≥18.
//
// ЯК ТУТ ДОВОДИТЬСЯ, ЩО НІЧОГО НЕ ЗАГУБЛЕНО.
// Не одним «діфом наприкінці», а двома незалежними перевірками, бо вони ловлять
// різні класи помилок і кожна вміє почервоніти окремо:
//   1) round-trip: serialize(parse(x)) ≡ x — доводить, що РОЗБІР нічого не з'їв
//      (найтихіший клас: з'їдений роздільник помітно лише через місяці);
//   2) on-disk: тіла вузлів на диску ≡ тіла, які дав розбір — доводить, що ЗАПИС
//      не спотворив (кодування, кінцеві переводи рядка).
// Разом вони і є інваріант «конкатенація тіл вузлів + шапка ≡ оригінал».
// Одна перевірка замість двох виглядала б так само зелено і не бачила б половини.
//
// Usage:
//   split-monoliths.mjs --dry-run [--state <dir>]   # рахує, НЕ пише (режим за замовчуванням)
//   split-monoliths.mjs --apply   [--state <dir>]   # пише вузли + фасади, оригінали в .trash/
//   split-monoliths.mjs --verify  [--state <dir>]   # обидві перевірки над тим, що на диску
//   split-monoliths.mjs --check-facade [<file>]     # фасад ≡ вивід генератора з вузлів (pre-commit)
//   split-monoliths.mjs --regen [--state <dir>]     # перегенерувати фасади з вузлів
//   Без --state: поточна тека, якщо це checkout strw-state; інакше --regen/--apply відмовляють (tri-194).
//
// Фасадів inbox два шари: загальний `triage-inbox.md` і зрізи за продуктом `triage-inbox.<ключ>.md`
// (D4 розведення STRW і продуктів) — див. `triageKey` і `facadeTriageKey`.

import fs from "node:fs";
import path from "node:path";
import { slugify } from "./lib.mjs";

// ── Аргументи ──────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const valOf = (f) => { const i = argv.indexOf(f); return i === -1 ? null : argv[i + 1]; };

const MODE = has("--apply") ? "apply" : has("--verify") ? "verify"
  : has("--regen") ? "regen" : has("--check-facade") ? "check-facade" : "dry-run";

// КУДИ ПИСАТИ (клас tri-194 «запис у спільну копію заморожує її»). До 23.10 без `--state` генератор брав
// спільну копію ~/Developer/STRW/strw-state, а підказки в помилках радили просто «--regen». Сесія у worktree
// strw-state, що виконала підказку, перегенеровувала ЧУЖУ теку: 23.10 там лишились 10 untracked
// triage-inbox.*.md, і вони заблокували `pull --ff-only` інтегратора. Тепер без `--state`: поточна тека —
// checkout strw-state → вона (і для читання теж: з worktree читається worktree, не спільна копія); інакше режими,
// що ПИШУТЬ (--regen, --apply), відмовляють з причиною, а читання (--check-facade, --verify, --dry-run) — спільна
// копія, як було. Явний `--state` для запису мусить бути текою з triage-inbox.md — інакше та сама відмова, а не
// ENOENT зі стеком (підказка `--state "$(pwd)"`, виконана не з тієї теки).
const isStateCheckout = (d) =>
  fs.existsSync(path.join(d, "triage-inbox.md")) && fs.existsSync(path.join(d, "engine", "items"));
const stateArg = (() => { const v = valOf("--state"); return v && !v.startsWith("--") ? v : null; })();
if (!stateArg && !isStateCheckout(process.cwd()) && (MODE === "regen" || MODE === "apply")) {
  console.error(`ВІДМОВА: --${MODE} без --state, а поточна тека (${process.cwd()}) — не checkout strw-state.`);
  console.error("  Без --state генератор писав би у спільну копію ~/Developer/STRW/strw-state — і її заморозили б");
  console.error("  незакомічені фасади (tri-194). Запусти з теки strw-state, яку комітиш (worktree), або назви її явно:");
  console.error(`  <strw-factory>/scripts/brain/split-monoliths.mjs --${MODE} --state "$(pwd)"`);
  process.exit(2);
}
if (stateArg && (MODE === "regen" || MODE === "apply") && !fs.existsSync(path.join(path.resolve(stateArg), "triage-inbox.md"))) {
  console.error(`ВІДМОВА: --${MODE} --state ${stateArg} — у цій теці немає triage-inbox.md, це не strw-state.`);
  console.error('  Запусти з теки strw-state, яку комітиш (worktree): <strw-factory>/scripts/brain/split-monoliths.mjs --' + MODE + ' --state "$(pwd)"');
  process.exit(2);
}
const STATE = path.resolve(
  stateArg ?? (isStateCheckout(process.cwd()) ? process.cwd() : path.join(process.env.HOME ?? "", "Developer/STRW/strw-state")),
);

// Маркер межі: усе НАД ним — людський текст, збережений побайтово; усе під ним
// генерується. Фасад без маркера — фасад, який хтось правив рукою.
const MARK = "<!-- brain:generated нижче · не редагувати рукою · джерело: %SRC% -->";

// ── Транслітерація: заголовки українські, імена файлів англійські ───────────
// Свідомий компроміс: транслітерація, а не переклад. Переклад потребував би
// моделі всередині скрипта — пряма не-ціль v1. Читабельність програє, зате
// результат детермінований і відтворюваний на будь-якій машині.
// TRANSLIT і slugify живуть у ./lib.mjs — див. коментар там про дрейф копій.

// ── ISO-тиждень без залежностей (правило четверга) ─────────────────────────
// Директорія береться за ISO-РОКОМ, не календарним: 2026-12-31 → 2027-W01.
// Роздільна межа року — саме той випадок, який ламає наївне `getFullYear()`.
function isoWeek(dateStr) {
  const [y, m, d] = dateStr.split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  const day = dt.getUTCDay() || 7;          // Пн=1 … Нд=7
  dt.setUTCDate(dt.getUTCDate() + 4 - day); // четвер цього тижня
  const isoYear = dt.getUTCFullYear();
  const jan1 = new Date(Date.UTC(isoYear, 0, 1));
  const week = Math.ceil(((dt - jan1) / 86400000 + 1) / 7);
  return `${isoYear}-W${String(week).padStart(2, "0")}`;
}

const yamlStr = (s) => `"${String(s).replace(/"/g, '\\"')}"`;
const isProduct = (s) => /^[a-z][a-z0-9]*-\d{3}$/.test(s);

// ══ Розбір монолітів ═══════════════════════════════════════════════════════
// Кожен parse() повертає { preamble, nodes[] }, а serialize() складає їх назад
// ПОБАЙТОВО. Саме на цій парі тримається round-trip-перевірка.

const readState = (rel) => fs.readFileSync(path.join(STATE, rel), "utf8");

// Після apply моноліта вже НЕМАЄ — на його шляху лежить фасад. Тож перевірка
// зобов'язана читати оригінал із .trash/, інакше вона «перевіряє» фасад проти
// вузлів і червоніє завжди. Відсутній оригінал — не привід тихо взяти те, що
// під рукою: без нього доводити нема чого, і це FAIL.
function readMonolith(rel) {
  if (MODE !== "verify") return readState(rel);
  const orig = path.join(STATE, ".trash", `${rel}.orig`);
  if (!fs.existsSync(orig)) {
    console.error(`FAIL: немає .trash/${rel}.orig — перевіряти вузли нема з чим.`);
    process.exit(1);
  }
  return fs.readFileSync(orig, "utf8");
}

// --- decisions-log.md: 75 секцій `## YYYY-MM-DD · <об'єкт> · <заголовок>` ---
// Та сама пара «строгий + грубий», що й для тріажу. Спершу її мали лише
// ескалації — і це була непослідовність, а не рішення: `decisions-log.md`
// такий самий append-only журнал, який ростиме, а заголовок повз `·` тихо
// приклеївся б до тіла ПОПЕРЕДНЬОГО рішення.
const DEC_HEAD = /^## (\d{4}-\d{2}-\d{2}) · ([^·]+?) · (.+)$/;
const DEC_HEAD_LOOSE = /^## \d{4}-\d{2}-\d{2}/;

function parseDecisions(text) {
  const lines = text.split("\n");
  const heads = [];
  const unseen = [];
  let fence = false;
  lines.forEach((ln, i) => {
    if (/^```/.test(ln)) fence = !fence;
    if (fence) return;
    if (DEC_HEAD.test(ln)) heads.push(i);
    else if (DEC_HEAD_LOOSE.test(ln)) unseen.push(`${i + 1}: ${ln}`);
  });
  if (unseen.length) {
    throw new Error(
      `decisions: ${unseen.length} заголовк(ів) схожі на рішення, але не розібрані — ` +
      `вони приклеїлись би до попереднього вузла мовчки:\n  ${unseen.join("\n  ")}`,
    );
  }
  if (fence) throw new Error("decisions-log.md: незакритий код-фенс — розбір сліпне саме там, де мовчить лічильник");
  const preamble = lines.slice(0, heads[0]).join("\n");
  const nodes = heads.map((start, k) => {
    const end = k + 1 < heads.length ? heads[k + 1] : lines.length;
    const body = lines.slice(start, end).join("\n");
    const m = lines[start].match(DEC_HEAD);
    const [, date, objectRaw, title] = m;
    const object = objectRaw.trim();
    const verdict = (title.match(/\b(KILL|PIVOT|GO)\b/) ?? [])[1] ?? "—";
    const gate = (title.match(/\bG([1-4])\b/) ?? [])[1];
    return { seq: k + 1, date, object, title: title.trim(), verdict, gate, body };
  });
  return { preamble, nodes };
}
// Шматки — це РОЗБИТТЯ списку рядків, тож склеюються рівно тим самим "\n",
// яким split їх роз'єднав. Наївне `preamble + bodies` губить по одному переводу
// рядка на кожному стику — 77 зниклих байтів, яких не видно очима в діфі.
const serializeDecisions = ({ preamble, nodes }) =>
  [preamble, ...nodes.map((n) => n.body)].join("\n");

function decisionNode(n) {
  const id = `dec-${String(n.seq).padStart(3, "0")}`;
  const product = isProduct(n.object) ? n.object : null;
  const tags = ["type/decision", product ? `product/${product}` : "scope/company"];
  if (n.gate) tags.push(`gate/g${n.gate}`);
  const fm = [
    "---",
    `id: ${id}`,
    "type: decision",
    `date: ${n.date}`,
    `object: ${yamlStr(n.object)}`,
    product ? `product: "[[${product}]]"` : "product:",
    `verdict: ${yamlStr(n.verdict)}`,
    `updated: ${n.date}`,
    'up: "[[decisions-log]]"',
    `tags: [${tags.join(", ")}]`,
    "---",
    "",
  ].join("\n");
  return {
    rel: path.join("decisions", n.date.slice(0, 4), `${id}-${slugify(n.title)}.md`),
    text: fm + n.body,
    body: n.body,
  };
}

// --- triage-inbox.md: `## [OPEN|DONE] <дата> [час] · <петля> · <тип>` -------
// Шапка містить КОД-ФЕНС зі шаблоном запису. Він виглядає точно як запис і
// записом не є — саме на цьому місці наївний парсер тихо створює 114-й вузол
// зі сміттям. Той самий фенс уже обходить awk у .githooks/pre-commit.
//
// Хвилини бувають НЕ цифрами: «19:2x», «16:3x», «23:0x» — петлі свідомо пишуть
// приблизний час. Вимога двох цифр у хвилинах відсікала 35 із 113 записів, і
// відсікала ТИХО: лічильник просто показував менше число, без жодної помилки.
const TRIAGE_HEAD = /^## \[(OPEN|DONE)\] (\d{4}-\d{2}-\d{2})(?: ~?([0-9]{2}:[0-9x]{2}))? · ([^·]+?) · (.+)$/;
// Груба форма — «щось схоже на запис». Різниця між нею і TRIAGE_HEAD і є
// сліпа пляма парсера, тож вона рахується і валить розбір. Без цього лічильника
// один заголовок із «~13:10» зник би тихо: цифра у звіті просто була б меншою.
const TRIAGE_HEAD_LOOSE = /^## \[(?:OPEN|DONE)\] /;

function parseTriage(text) {
  const lines = text.split("\n");
  const heads = [];
  const unseen = [];
  let fence = false;
  lines.forEach((ln, i) => {
    if (/^```/.test(ln)) fence = !fence;
    if (fence) return;
    if (TRIAGE_HEAD.test(ln)) heads.push(i);
    else if (TRIAGE_HEAD_LOOSE.test(ln)) unseen.push(`${i + 1}: ${ln}`);
  });
  if (unseen.length) {
    throw new Error(
      `triage: ${unseen.length} заголовк(ів) схожі на запис, але не розібрані — ` +
      `вони випали б з розбивки мовчки:\n  ${unseen.join("\n  ")}`,
    );
  }
  // Непарна кількість фенсів означає, що трекер десинхронізовано — і тоді
  // `if (fence) return` глушить сам лічильник вище: розбір бадьоро звітує
  // «0 вузлів», фасад друкує «Чекає рішення: 0» при живих ескалаціях.
  if (fence) throw new Error("triage-inbox.md: незакритий код-фенс — розбір сліпне саме там, де мовчить лічильник");
  const preamble = lines.slice(0, heads[0]).join("\n");
  const nodes = heads.map((start, k) => {
    const end = k + 1 < heads.length ? heads[k + 1] : lines.length;
    const body = lines.slice(start, end).join("\n");
    const [, status, date, time, loop, kind] = lines[start].match(TRIAGE_HEAD);
    return {
      seq: k + 1,
      status: status === "OPEN" ? "open" : "resolved",
      date, time: time ?? null, loop: loop.trim(), kind: kind.trim(), body,
    };
  });
  return { preamble, nodes };
}
const serializeTriage = serializeDecisions;

function triageNode(n) {
  const kindSlug = slugify(n.kind, 24) || "item";
  const file = `${n.date}-${String(n.seq).padStart(3, "0")}-${kindSlug}.md`;
  const dir = n.status === "open" ? path.join("triage", "open")
    : path.join("triage", "resolved", isoWeek(n.date));
  const product = (n.body.match(/^- Продукт: *([a-z][a-z0-9]*-\d{3})/m) ?? [])[1] ?? null;
  const tags = ["type/triage-item", product ? `product/${product}` : "scope/company"];
  if (n.status === "open") tags.push("status/waiting-decision");
  const fm = [
    "---",
    `id: tri-${String(n.seq).padStart(3, "0")}`,
    "type: triage-item",
    `status: ${n.status}`,
    `kind: ${yamlStr(n.kind)}`,
    `date: ${n.date}`,
    `loop: ${yamlStr(n.loop)}`,
    product ? `product: "[[${product}]]"` : "product:",
    `updated: ${n.date}`,
    'up: "[[triage-inbox]]"',
    `tags: [${tags.join(", ")}]`,
    "---",
    "",
  ].join("\n");
  return { rel: path.join(dir, file), text: fm + n.body, body: n.body, node: n };
}

// --- budget.md: обсяг — не секції, а 82 рядки таблиці «Факт» ---------------
// Тому вузол тут = МІСЯЦЬ, а шапка (стелі, ліміти, заголовок таблиці) лишається
// у фасаді побайтово: це і є те, заради чого файл читають.
const LEDGER_ROW = /^\| (\d{4})-(\d{2})-\d{2} \|/;

// Таблиця «Факт» — НЕ суцільний масив рядків: між ними лежать абзаци-NB
// (рядки 56-57, 91-97 станом на 14.08) — пояснення, чому журнал у тому місці
// рветься. Групування «взяти всі рядки за місяцем» викидало їх мовчки: сума
// сходилась, таблиця виглядала цілою, а зникав саме текст про те, ЧОМУ вона
// така. Тому вузол = НЕПЕРЕРВНИЙ шматок документа, а не вибірка за датою.
function parseBudget(text) {
  const lines = text.split("\n");
  const first = lines.findIndex((l) => LEDGER_ROW.test(l));
  const preamble = lines.slice(0, first).join("\n");

  // Ріжемо хвіст на пробіги: пробіг = послідовні рядки, поки місяць не змінився.
  // Не-рядкові лінії прилипають до поточного пробігу — вони про нього і написані.
  const runs = [];
  let cur = null;
  for (const ln of lines.slice(first)) {
    const m = ln.match(LEDGER_ROW);
    const month = m ? `${m[1]}-${m[2]}` : null;
    if (month && (!cur || cur.month !== month)) {
      cur = { month, lines: [] };
      runs.push(cur);
    }
    (cur ?? (runs.push(cur = { month: null, lines: [] }), cur)).lines.push(ln);
  }
  // Місяць, розірваний на кілька пробігів, означає дописування заднім числом.
  // Тоді один файл на місяць уже НЕ відновлює порядок документа — і чесніше
  // впасти тут, ніж тихо переставити рядки журналу бюджету.
  const seen = new Map();
  for (const r of runs) {
    if (seen.has(r.month)) throw new Error(`budget: місяць ${r.month} розірваний на кілька пробігів — розбивка на файл-на-місяць втратила б порядок`);
    seen.set(r.month, true);
  }
  return { preamble, nodes: runs.map((r) => ({ month: r.month, rows: r.lines })) };
}
const serializeBudget = ({ preamble, nodes }) =>
  [preamble, ...nodes.map((n) => n.rows.join("\n"))].join("\n");

function ledgerNode(n) {
  // Рахуємо суму ЛИШЕ по рядках таблиці — абзаци-NB, що їдуть у тому ж шматку,
  // у суму потрапити не можуть за побудовою.
  const dataRows = n.rows.filter((r) => LEDGER_ROW.test(r));
  // `parseFloat(...) || 0` мовчки перетворював «—», «$12» чи зсунуту колонку на
  // нуль — тобто занижував витрати проти стелі. Це рівно те число, заради якого
  // фасад узагалі існує (запит «скільки лишилось» — агрегат), тож хай падає.
  const total = dataRows.reduce((sum, r) => {
    const cell = (r.split("|")[4] ?? "").trim();
    const v = Number(cell);
    if (cell === "" || !Number.isFinite(v)) {
      throw new Error(`budget ${n.month}: нерозбірна клітинка витрат «${cell}» у рядку:\n  ${r}`);
    }
    return sum + v;
  }, 0);
  const fm = [
    "---",
    `id: ledger-${n.month}`,
    "type: ledger",
    `month: ${n.month}`,
    `external_usd: ${total}`,
    `updated: ${n.month}-01`,
    'up: "[[budget]]"',
    "tags: [type/ledger, scope/company]",
    "---",
    "",
    `# Budget ledger · ${n.month}`,
    "",
    `> Зовнішні витрати за місяць: **$${total}**. Генерований вузол — не редагувати рукою.`,
    "",
    "| Дата | Петля | Запуск | Зовнішні витрати $ | Примітка |",
    "|------|-------|--------|--------------------|----------|",
  ].join("\n");
  return {
    rel: path.join("budget", "ledger", `${n.month}.md`),
    text: fm + "\n" + n.rows.join("\n") + "\n",
    // `month` тут не декоративне: фасад друкує саме його, і без цього поля у
    // таблицю фасаду їхало «undefined». Спіймано звіркою двох виробників —
    // сам по собі apply був зелений і виглядав правильно.
    month: n.month, rows: dataRows, total,
  };
}

// ══ Фасади ═════════════════════════════════════════════════════════════════

function facadeDecisions(preamble, nodes) {
  const last = nodes.slice(-15).reverse();
  const rows = last.map((n) =>
    `| ${n.date} | ${n.object} | [${n.title.replace(/\|/g, "\\|")}](${encodeURI(n.rel)}) | ${n.verdict} |`);
  return [
    preamble.replace(/\n+$/, ""),
    "",
    MARK.replace("%SRC%", "decisions/"),
    "",
    `**${nodes.length} рішень** у \`decisions/YYYY/\`. Нижче — останні 15; повний журнал — директорія, а не цей файл.`,
    "",
    "| Дата | Об'єкт | Рішення | Вердикт |",
    "|------|--------|---------|---------|",
    ...rows,
    "",
  ].join("\n");
}

function facadeTriage(preamble, nodes) {
  return [preamble.replace(/\n+$/, ""), "", ...triageBodyLines(nodes)].join("\n");
}

function triageBodyLines(nodes) {
  const open = nodes.filter((n) => n.status === "open");
  const resolved = nodes.filter((n) => n.status === "resolved");
  const lastResolved = resolved.slice(0, 10);
  return [
    MARK.replace("%SRC%", "triage/"),
    "",
    `**Чекає рішення: ${open.length}.** Джерело правди — \`triage/open/\`; закриті — \`triage/resolved/YYYY-Www/\` (${resolved.length}).`,
    "Редагується вузол, не цей зріз: рішення вписується у файл під `triage/open/`, далі перегенерація.",
    "",
    ...(open.length ? open.map((n) => "\n" + n.body.replace(/\n+$/, "") + "\n") : ["_Порожньо._\n"]),
    "---",
    "",
    "### Останні закриті",
    "",
    "| Дата | Петля | Тип |",
    "|------|-------|-----|",
    ...lastResolved.map((n) => `| [${n.date}](${encodeURI(n.rel)}) | ${n.loop} | ${n.kind} |`),
    "",
  ];
}

// ── Фасади inbox за продуктом (D4, рішення CEO 20.10, tri-199 ★ п. 4 і 6) ─────────
// Сесія Pact бачить свій зріз, сесія фабрики — свій. РОЗБИТТЯ, не вибірка: кожна картка — рівно в одному
// фасаді за ключем, тож сума «Чекає рішення» по них = загальному (це міряє CI strw-state без генератора).
//
// Ключ — за властивістю, не за переліком форм: `product:` — вільний текст («pact-001», «"[[pact-001]]"»,
// «factory (наслідки — pact-001)», «homeinspect-001 (не заведено в портфель)», «—»). Знімаються лапки,
// `[[`, регістр; провідний id `xxx-NNN` — продукт, ЯКЩО в strw-state є тека `products/<id>/`; усе інше
// (`factory …`, `—`, порожнє, id без теки) — `factory`: картка не губиться, вона йде власнику-фабриці.
function triageKey(raw) {
  const v = String(raw ?? "").trim().replace(/^["']|["']$/g, "").replace(/^\[\[/, "").trim().toLowerCase();
  const id = (v.match(/^([a-z][a-z0-9]*-\d{3})(?![0-9])/) ?? [])[1];
  if (!id) return "factory";
  const dir = path.join(STATE, "products", id);
  return fs.existsSync(dir) && fs.statSync(dir).isDirectory() ? id : "factory";
}

// Повністю генерований файл: людської шапки немає (схема й правила — у загальному фасаді, на нього посилання).
function facadeTriageKey(key, nodes) {
  const scope = key === "factory"
    ? "картки фабрики — `product:` factory, «—», порожнє або продукт без теки в `products/`"
    : `картки з \`product: ${key}\``;
  return [
    "---",
    "type: triage",
    `title: "Triage Inbox · ${key}"`,
    `product: ${key}`,
    'up: "[[triage-inbox]]"',
    `tags: [type/triage, ${key === "factory" ? "scope/company" : `product/${key}`}]`,
    "---",
    "",
    `# Triage Inbox · ${key}`,
    `> Зріз [[triage-inbox|Triage Inbox]] (\`triage-inbox.md\`): ${scope}. Схема картки й правила — там.`,
    "> Файл генерується цілком (`scripts/brain/split-monoliths.mjs --regen` у strw-factory); рукою не правити.",
    "",
    ...triageBodyLines(nodes),
  ].join("\n");
}
function productIds() {
  const dir = path.join(STATE, "products");
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isDirectory() && /^[a-z][a-z0-9]*-\d{3}$/.test(e.name)).map((e) => e.name).sort();
}
const KEY_FACADE = /^triage-inbox\.([^/]+)\.md$/;
function keyFacadesOnDisk() {
  return fs.readdirSync(STATE).filter((f) => KEY_FACADE.test(f)).sort();
}

// Фасад бюджету несе ПОРАХОВАНИЙ підсумок — і це не косметика.
// Вимір бази (bench.baseline.json) показав: «скільки лишилось стелі» — агрегат
// по всіх 82 рядках, тож підлога запиту = 126 993 B, тобто майже весь файл.
// Секціонування саме по собі цей запит не здешевлює взагалі; здешевлює рівно
// те, що сума пораховна наперед і лежить у шапці.
function facadeBudget(preamble, ledgers) {
  const cap = (preamble.match(/^cap_external_usd_month: *(\d+)/m) ?? [])[1] ?? "?";
  const total = ledgers.reduce((s, l) => s + l.total, 0);
  const byMonth = ledgers.map((l) => `| ${l.month} | $${l.total} | [ledger](${encodeURI(l.rel)}) | ${l.rows.length} |`);
  return [
    preamble.replace(/\n+$/, ""),
    "",
    MARK.replace("%SRC%", "budget/ledger/"),
    "",
    `**Зовнішні витрати: $${total} зі стелі $${cap}/міс — лишилось $${Number(cap) - total}.**`,
    `Порахувано по ${ledgers.reduce((s, l) => s + l.rows.length, 0)} рядках журналу; самі рядки — у \`budget/ledger/\`.`,
    "",
    "| Місяць | Витрачено | Журнал | Рядків |",
    "|--------|-----------|--------|--------|",
    ...byMonth,
    "",
  ].join("\n");
}

// ══ Виконання ══════════════════════════════════════════════════════════════

const eq = (a, b) => a === b;
// Нормалізація рівно з трьох дій і жодної більше. Кожна зайва нормалізація —
// це клас розбіжностей, який перевірка перестає бачити.
const norm = (s) => s.replace(/[ \t]+$/gm, "").replace(/\n{3,}/g, "\n\n").replace(/\n*$/, "\n");

function buildAll() {
  const decRaw = readMonolith("decisions-log.md");
  const triRaw = readMonolith("triage-inbox.md");
  const budRaw = readMonolith("budget.md");

  const dec = parseDecisions(decRaw);
  const tri = parseTriage(triRaw);
  const bud = parseBudget(budRaw);

  const checks = [
    ["decisions-log.md", eq(norm(serializeDecisions(dec)), norm(decRaw))],
    ["triage-inbox.md", eq(norm(serializeTriage(tri)), norm(triRaw))],
    ["budget.md", eq(norm(serializeBudget(bud)), norm(budRaw))],
  ];

  const decFiles = dec.nodes.map(decisionNode);
  const triFiles = tri.nodes.map(triageNode);
  const ledFiles = bud.nodes.map(ledgerNode);

  return {
    dec, tri, bud, checks,
    files: [...decFiles, ...triFiles, ...ledFiles],
    facades: [
      { rel: "decisions-log.md", text: facadeDecisions(dec.preamble, dec.nodes.map((n, i) => ({ ...n, rel: decFiles[i].rel }))) },
      { rel: "triage-inbox.md", text: facadeTriage(tri.preamble, tri.nodes.map((n, i) => ({ ...n, rel: triFiles[i].rel }))) },
      { rel: "budget.md", text: facadeBudget(bud.preamble, ledFiles) },
    ],
  };
}

const b = (MODE === "check-facade" || MODE === "regen") ? null : buildAll();

if (MODE === "dry-run") {
  console.log("split-monoliths --dry-run · НІЧОГО НЕ ЗАПИСАНО\n");
  console.log(`  decisions-log.md → ${b.dec.nodes.length} вузлів  (decisions/YYYY/)`);
  const open = b.tri.nodes.filter((n) => n.status === "open").length;
  console.log(`  triage-inbox.md  → ${b.tri.nodes.length} вузлів  (${open} open · ${b.tri.nodes.length - open} resolved)`);
  const ledgerRows = b.bud.nodes.reduce((s, n) => s + n.rows.filter((r) => LEDGER_ROW.test(r)).length, 0);
  const ledgerProse = b.bud.nodes.reduce((s, n) => s + n.rows.filter((r) => !LEDGER_ROW.test(r) && r.trim()).length, 0);
  console.log(`  budget.md        → ${b.bud.nodes.length} вузлів  (budget/ledger/YYYY-MM.md, ${ledgerRows} рядків таблиці + ${ledgerProse} рядків прози)`);
  console.log(`\n  разом файлів до запису: ${b.files.length} вузлів + ${b.facades.length} фасади`);
  console.log("\n  round-trip (розбір нічого не з'їв):");
  for (const [name, ok] of b.checks) console.log(`    ${ok ? "OK  " : "FAIL"} ${name}`);
  const weeks = new Set(b.tri.nodes.filter((n) => n.status === "resolved").map((n) => isoWeek(n.date)));
  console.log(`\n  тижнів у triage/resolved/: ${weeks.size} (${[...weeks].sort().join(", ")})`);
  console.log("\n  розміри фасадів проти оригіналів:");
  for (const f of b.facades) {
    const was = fs.statSync(path.join(STATE, f.rel)).size;
    const now = Buffer.byteLength(f.text, "utf8");
    console.log(`    ${f.rel.padEnd(18)} ${String(was).padStart(7)} B → ${String(now).padStart(6)} B  (−${(100 * (1 - now / was)).toFixed(1)}%)`);
  }
  if (b.checks.some(([, ok]) => !ok)) process.exit(1);
} else if (MODE === "apply") {
  if (b.checks.some(([, ok]) => !ok)) {
    console.error("ВІДМОВА: round-trip червоний — розбір губить контент. Нічого не записано.");
    for (const [n, ok] of b.checks) if (!ok) console.error(`  FAIL ${n}`);
    process.exit(1);
  }
  // ГВАРДІЯ ІДЕМПОТЕНТНОСТІ. Без неї другий `--apply` читає ФАСАД як моноліт,
  // розбирає його у три вузли і перезаписує ним `.trash/*.orig` — тобто
  // знищує єдину копію 800 KB стану, звітує успіх, і `--verify` після цього
  // каже OK. Відтворено: .trash 817 359 B → 17 616 B, rc=0 на обох кроках.
  // Сценарій не екзотичний: «щось пішло не так, перезапущу» — це перше, що
  // робить оператор.
  const targets = ["decisions-log.md", "triage-inbox.md", "budget.md"];
  const markHead = MARK.slice(0, MARK.indexOf("%SRC%"));
  for (const f of targets) {
    if (readState(f).includes(markHead)) {
      console.error(`ВІДМОВА: ${f} уже фасад (є маркер генерації) — розбивка вже виконана.`);
      console.error("  Перегенерувати фасади з вузлів: --regen · Перевірити: --verify");
      process.exit(1);
    }
  }
  const trash = path.join(STATE, ".trash");
  fs.mkdirSync(trash, { recursive: true });
  for (const f of targets) {
    const dst = path.join(trash, `${f}.orig`);
    if (fs.existsSync(dst)) {
      console.error(`ВІДМОВА: ${dst} уже існує — перезапис затер би справжній оригінал.`);
      console.error("  Прибери копію свідомо і руками, якщо вона більше не потрібна.");
      process.exit(1);
    }
  }
  for (const f of targets) fs.copyFileSync(path.join(STATE, f), path.join(trash, `${f}.orig`));
  for (const f of [...b.files, ...b.facades]) {
    const abs = path.join(STATE, f.rel);
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, f.text);
  }
  console.log(`записано ${b.files.length} вузлів + ${b.facades.length} фасади; оригінали в .trash/`);
} else if (MODE === "verify") {
  // МЕЖА ЦІЄЇ ПЕРЕВІРКИ, названа явно, бо інакше її вивід бреше.
  // Вона звіряє диск із розбором ОРИГІНАЛІВ у `.trash/`, тобто зі знімком
  // моменту міграції. Це доказ, що розбивка нічого не загубила — і рівно
  // доти, доки стан не почав жити далі. Перша ж закрита ескалація (вузол
  // переїхав open→resolved) і перша нова дають «FAIL», який читається як
  // пошкодження, а є нормальною роботою.
  // Постійну цілісність стереже `--check-facade` (фасад ≡ вузли) і git.
  console.log("verify: звірка з міграційним знімком .trash/ — правки, зроблені ПІСЛЯ");
  console.log("        розбивки, тут очікувано показуються як розбіжності.");
  let bad = 0;
  for (const [name, ok] of b.checks) {
    console.log(`${ok ? "OK  " : "FAIL"} round-trip · ${name}`);
    if (!ok) bad++;
  }
  // Друга, незалежна перевірка: те, що на диску, ≡ те, що дав розбір.
  for (const f of b.files) {
    const abs = path.join(STATE, f.rel);
    if (!fs.existsSync(abs)) { console.log(`FAIL відсутній вузол · ${f.rel}`); bad++; continue; }
    if (fs.readFileSync(abs, "utf8") !== f.text) { console.log(`FAIL вузол розійшовся · ${f.rel}`); bad++; }
  }
  // Третій клас, якого ітерація по очікуваних файлах не бачить у принципі:
  // вузол, якого в розборі НЕМАЄ. Так виглядає осиротілий файл після того, як
  // оператор виправив заголовок і перезапустив розбивку — нумерація зсунулась,
  // а старий файл лишився назавжди і мовчки подвоює рішення.
  const expected = new Set(b.files.map((f) => f.rel));
  for (const dir of ["decisions", "triage", path.join("budget", "ledger")]) {
    for (const rel of lsRec(dir)) {
      if (!expected.has(rel)) { console.log(`FAIL зайвий вузол · ${rel}`); bad++; }
    }
  }
  console.log(bad === 0 ? `OK   ${b.files.length} вузлів на диску ≡ розбір, зайвих немає` : `${bad} розбіжностей`);
  process.exit(bad === 0 ? 0 : 1);
} else if (MODE === "check-facade" || MODE === "regen") {
  // Прапорець без значення: `--check-facade --state X` не має вважати "--state"
  // іменем фасаду — інакше перевірка «не знає такого файлу» і виходить кодом 2,
  // що для pre-commit виглядає як поламаний гейт, а не як чистий коміт.
  const rawTarget = valOf("--check-facade");
  const target = rawTarget && !rawTarget.startsWith("--") ? rawTarget : null;
  const built = facadesFromNodes();
  const wanted = target ? built.filter((f) => f.rel === target) : built;
  if (target && wanted.length === 0) { console.error(`невідомий фасад: ${target}`); process.exit(2); }
  let bad = 0;
  // Фасади за продуктом — набір рухається (D4): відсутній фасад набору створюється (regen) або є
  // розбіжністю (check); згенерований фасад поза набором прибирається (regen) або є розбіжністю (check);
  // файл `triage-inbox.*.md` без маркера генерації — не фасад, його не чіпаємо й кажемо вголос.
  if (!target) {
    const inSet = new Set(built.map((f) => f.rel));
    const markHead = MARK.slice(0, MARK.indexOf("%SRC%"));
    for (const rel of keyFacadesOnDisk().filter((r) => !inSet.has(r))) {
      const abs = path.join(STATE, rel);
      if (!fs.readFileSync(abs, "utf8").includes(markHead)) {
        console.error(`FAIL: ${rel} — не фасад (без маркера генерації); не чіпаю. Перейменуй або прибери руками.`);
        bad++;
      } else if (MODE === "regen") {
        fs.unlinkSync(abs); console.log(`прибрано ${rel} — теки продукту в products/ немає`);
      } else {
        console.error(`FAIL: ${rel} — зайвий фасад: теки його продукту в products/ немає. Далі: --regen`);
        bad++;
      }
    }
  }
  for (const f of wanted) {
    const abs = path.join(STATE, f.rel);
    if (!fs.existsSync(abs)) {
      if (MODE === "regen" && f.key) { fs.writeFileSync(abs, f.text); console.log(`створено ${f.rel}`); continue; }
      console.error(`FAIL: ${f.rel} — фасаду набору немає на диску. Далі, з теки strw-state, яку комітиш: <strw-factory>/scripts/brain/split-monoliths.mjs --regen --state "$(pwd)"`);
      bad++; continue;
    }
    const onDisk = fs.readFileSync(abs, "utf8");
    if (MODE === "regen") {
      if (onDisk !== f.text) { fs.writeFileSync(abs, f.text); console.log(`перегенеровано ${f.rel}`); }
    } else if (onDisk !== f.text) {
      console.error(`FAIL: ${f.rel} розійшовся з виводом генератора — фасад правили рукою.`);
      console.error("  Правити треба вузол (decisions/, triage/, budget/ledger/), далі:");
      console.error('  з теки strw-state, яку комітиш: <strw-factory>/scripts/brain/split-monoliths.mjs --regen --state "$(pwd)"');
      bad++;
    }
  }
  process.exit(bad === 0 ? 0 : 1);
}

// ══ Зворотний шлях: вузли з диска → фасад ══════════════════════════════════
//
// Після міграції моноліта більше немає, тож перегенерувати фасад із нього
// неможливо — джерелом стають самі вузли. Без цієї функції обіцянка «фасад
// генерований, ніколи не редагується рукою» лишилась би заявою без виконавця:
// pre-commit не мав би з чим звіряти.
//
// Людська шапка при цьому береться з ЧИННОГО фасаду — усе, що над маркером.
// Так текст, який писала людина, переживає будь-яку кількість перегенерацій.

// Оголошені як function, а не const: блок виконання стоїть ВИЩЕ за ці рядки, а
// const у temporal dead zone — виклик згори падає з ReferenceError. Спіймано
// тестом на check-facade; читанням коду це місце виглядає бездоганно.
function stripFm(t) { return t.replace(/^---\n[\s\S]*?\n---\n/, ""); }
function fmVal(t, k) {
  return (t.match(new RegExp(`^${k}: *(.*)$`, "m")) ?? [])[1]?.replace(/^"|"$/g, "") ?? "";
}
function seqOf(t) { return Number((fmVal(t, "id").match(/(\d+)$/) ?? [])[1] ?? 0); }

// Статус вузла тріажу читається ТУТ і більше ніде. Раніше фасад порівнював сире
// поле з "open" малими, і `status: OPEN` (так писав tri-175) мовчки випадав з
// лічильника й тіла фасаду, а `--check-facade` лишався зеленим — генератор і
// фасад були однаково сліпі. Монолітний розбір на невпізнане кидає виняток;
// читач вузлів мусить так само: регістр і лапки нормалізуються, а все, що не
// open/resolved, зупиняє генератор з назвою файлу.
function triageStatus(raw, rel) {
  const s = raw.trim().replace(/^["']|["']$/g, "").trim().toLowerCase();
  if (s === "open" || s === "resolved") return s;
  console.error(`FAIL: ${rel}: status: «${raw}» — очікується open або resolved (регістр значення байдужий).`);
  if (!s) console.error("  Поле порожнє або відсутнє: ключ має бути саме `status:` малими літерами (`Status:` генератор не бачить).");
  console.error("  Невпізнаний статус випав би з фасаду мовчки — «Чекає рішення» не порахувало б картку.");
  process.exit(1);
}

function lsRec(dir) {
  const abs = path.join(STATE, dir);
  if (!fs.existsSync(abs)) return [];
  return fs.readdirSync(abs, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? lsRec(path.join(dir, e.name)) : e.name.endsWith(".md") ? [path.join(dir, e.name)] : []
  );
}

function preambleOf(rel) {
  const cur = fs.readFileSync(path.join(STATE, rel), "utf8");
  const mark = cur.indexOf(MARK.slice(0, MARK.indexOf("%SRC%")));
  if (mark === -1) {
    console.error(`FAIL: у ${rel} немає маркера генерації — це вже не фасад.`);
    process.exit(1);
  }
  return cur.slice(0, mark).replace(/\n+$/, "");
}

// Порядок виводу НЕ МОЖЕ спиратись на порядок перерахунку теки.
//
// Було `sort((a, b) => a.seq - b.seq)`, і ключ неунікальний: `2026-08-19-003-finding`
// та `-003-question` обидва дають 3. JS-sort стабільний, тож рівні ключі зберігають
// порядок ВХОДУ — а вхід це `lsRec` → `fs.readdirSync`, чий порядок у node і в
// deno різний. Наслідок був не косметичний: пре-коміт звіряє фасад через deno,
// інструкції кажуть запускати просто «--regen» (тобто node), і чесно
// перегенерований файл відбивався з написом «фасад правили рукою» — гейт
// звинувачував у ручній правці, якої не було, і радив дію, що відтворює збій
// (`tri-027`, вимір 2026-08-27).
//
// Шлях вузла унікальний за побудовою, тож компаратор із ним стає ТОТАЛЬНИМ і
// вивід перестає залежати від чого-небудь поза вмістом.
function byKeyThenPath(key) {
  return (a, b) => {
    const ka = key(a), kb = key(b);
    const primary = typeof ka === "number" ? ka - kb : String(ka).localeCompare(String(kb));
    return primary || a.rel.localeCompare(b.rel);
  };
}

function facadesFromNodes() {
  const dec = lsRec("decisions").map((rel) => {
    const t = fs.readFileSync(path.join(STATE, rel), "utf8");
    const body = stripFm(t);
    const title = (body.match(/^## \d{4}-\d{2}-\d{2} · [^·]+ · (.+)$/m) ?? [])[1] ?? "";
    return { rel, seq: seqOf(t), date: fmVal(t, "date"), object: fmVal(t, "object"), verdict: fmVal(t, "verdict"), title };
  }).sort(byKeyThenPath((x) => x.seq));

  const tri = lsRec("triage").map((rel) => {
    const t = fs.readFileSync(path.join(STATE, rel), "utf8");
    // product — лише з frontmatter: рядок «product: …» у ТІЛІ картки не має переводити її в інший фасад.
    const fm = (t.match(/^---\n([\s\S]*?)\n---\n/) ?? [null, ""])[1];
    return {
      rel, seq: seqOf(t), status: triageStatus(fmVal(t, "status"), rel), date: fmVal(t, "date"),
      loop: fmVal(t, "loop"), kind: fmVal(t, "kind"), body: stripFm(t), key: triageKey(fmVal(fm, "product")),
    };
  }).sort(byKeyThenPath((x) => x.seq));
  // Набір СТАБІЛЬНИЙ: factory + кожна тека `products/<id>/` — і з нулем відкритих карток. Тоді відсутній
  // фасад продукту означає «не згенеровано» (стара копія генератора, гілка до D4), а не «0 відкритих» —
  // SessionStart Pact каже ⬜, а не хибне «0» (чекер плану D4 р.1, I4). Фасад продукту, чию теку прибрали,
  // --regen видаляє.
  const keys = ["factory", ...productIds()];

  // Вузол журналу — це МІСЯЦЬ, і пізнається він полем `month:`, а не тим, що
  // файл лежить у теці. `budget/ledger/README.md` полем не володіє, і без
  // цього фільтра він ставав рядком таблиці: місяць порожній, сума `$0` (бо
  // Number("") === 0), рядків 0. Тобто фасад друкував НЕІСНУЮЧИЙ місяць із
  // вигаданою сумою — той самий клас, що «порожній набір як усе гаразд».
  // Дефект латентний із 668f5df: видно його лише при першій перегенерації
  // після появи README.
  const ledAll = lsRec(path.join("budget", "ledger")).map((rel) => {
    const t = fs.readFileSync(path.join(STATE, rel), "utf8");
    return {
      rel, month: fmVal(t, "month"), total: Number(fmVal(t, "external_usd")),
      rows: t.split("\n").filter((l) => LEDGER_ROW.test(l)),
    };
  });
  const led = ledAll.filter((x) => x.month).sort(byKeyThenPath((x) => x.month));
  // Пропуск не мовчазний: файл без `month:` — це або README (тоді все гаразд),
  // або зламаний вузол місяця, і другий випадок мусить бути видно.
  const skipped = ledAll.filter((x) => !x.month).map((x) => x.rel);
  if (skipped.length) {
    console.error(`  ⬜ у budget/ledger/ пропущено без поля month: ${skipped.join(", ")}`);
  }

  return [
    { rel: "decisions-log.md", text: facadeDecisions(preambleOf("decisions-log.md"), dec) },
    { rel: "triage-inbox.md", text: facadeTriage(preambleOf("triage-inbox.md"), tri) },
    { rel: "budget.md", text: facadeBudget(preambleOf("budget.md"), led) },
    ...keys.map((k) => ({ rel: `triage-inbox.${k}.md`, text: facadeTriageKey(k, tri.filter((n) => n.key === k)), key: true })),
  ];
}
