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

import fs from "node:fs";
import path from "node:path";

// ── Аргументи ──────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const valOf = (f) => { const i = argv.indexOf(f); return i === -1 ? null : argv[i + 1]; };

const STATE = path.resolve(
  valOf("--state") ?? path.join(process.env.HOME ?? "", "Developer/STRW/strw-state"),
);
const MODE = has("--apply") ? "apply" : has("--verify") ? "verify"
  : has("--regen") ? "regen" : has("--check-facade") ? "check-facade" : "dry-run";

// Маркер межі: усе НАД ним — людський текст, збережений побайтово; усе під ним
// генерується. Фасад без маркера — фасад, який хтось правив рукою.
const MARK = "<!-- brain:generated нижче · не редагувати рукою · джерело: %SRC% -->";

// ── Транслітерація: заголовки українські, імена файлів англійські ───────────
// Свідомий компроміс: транслітерація, а не переклад. Переклад потребував би
// моделі всередині скрипта — пряма не-ціль v1. Читабельність програє, зате
// результат детермінований і відтворюваний на будь-якій машині.
const TRANSLIT = {
  а:"a",б:"b",в:"v",г:"h",ґ:"g",д:"d",е:"e",є:"ie",ж:"zh",з:"z",и:"y",і:"i",ї:"i",
  й:"i",к:"k",л:"l",м:"m",н:"n",о:"o",п:"p",р:"r",с:"s",т:"t",у:"u",ф:"f",х:"kh",
  ц:"ts",ч:"ch",ш:"sh",щ:"shch",ь:"",ю:"iu",я:"ia",ы:"y",э:"e",ъ:"","'":"","’":"",
};
function slugify(s, max = 50) {
  const t = [...s.toLowerCase()].map((c) => TRANSLIT[c] ?? c).join("");
  const cleaned = t.replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  if (cleaned.length <= max) return cleaned;
  const cut = cleaned.slice(0, max);
  const lastDash = cut.lastIndexOf("-");
  return (lastDash > max * 0.6 ? cut.slice(0, lastDash) : cut).replace(/-+$/, "");
}

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
  if (fence) throw new Error("decisions: незакритий код-фенс — розбір сліпне саме там, де мовчить лічильник");
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
  if (fence) throw new Error("triage: незакритий код-фенс — розбір сліпне саме там, де мовчить лічильник");
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
  const total = dataRows.reduce((s, r) => s + (parseFloat(r.split("|")[4]) || 0), 0);
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
  const open = nodes.filter((n) => n.status === "open");
  const resolved = nodes.filter((n) => n.status === "resolved");
  const lastResolved = resolved.slice(0, 10);
  return [
    preamble.replace(/\n+$/, ""),
    "",
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
  ].join("\n");
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
  for (const f of wanted) {
    const abs = path.join(STATE, f.rel);
    const onDisk = fs.readFileSync(abs, "utf8");
    if (MODE === "regen") {
      if (onDisk !== f.text) { fs.writeFileSync(abs, f.text); console.log(`перегенеровано ${f.rel}`); }
    } else if (onDisk !== f.text) {
      console.error(`FAIL: ${f.rel} розійшовся з виводом генератора — фасад правили рукою.`);
      console.error("  Правити треба вузол (decisions/, triage/, budget/ledger/), далі:");
      console.error("  scripts/brain/split-monoliths.mjs --regen");
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

function facadesFromNodes() {
  const dec = lsRec("decisions").map((rel) => {
    const t = fs.readFileSync(path.join(STATE, rel), "utf8");
    const body = stripFm(t);
    const title = (body.match(/^## \d{4}-\d{2}-\d{2} · [^·]+ · (.+)$/m) ?? [])[1] ?? "";
    return { rel, seq: seqOf(t), date: fmVal(t, "date"), object: fmVal(t, "object"), verdict: fmVal(t, "verdict"), title };
  }).sort((a, b) => a.seq - b.seq);

  const tri = lsRec("triage").map((rel) => {
    const t = fs.readFileSync(path.join(STATE, rel), "utf8");
    return {
      rel, seq: seqOf(t), status: fmVal(t, "status"), date: fmVal(t, "date"),
      loop: fmVal(t, "loop"), kind: fmVal(t, "kind"), body: stripFm(t),
    };
  }).sort((a, b) => a.seq - b.seq);

  const led = lsRec(path.join("budget", "ledger")).map((rel) => {
    const t = fs.readFileSync(path.join(STATE, rel), "utf8");
    return {
      rel, month: fmVal(t, "month"), total: Number(fmVal(t, "external_usd")),
      rows: t.split("\n").filter((l) => LEDGER_ROW.test(l)),
    };
  }).sort((a, b) => a.month.localeCompare(b.month));

  return [
    { rel: "decisions-log.md", text: facadeDecisions(preambleOf("decisions-log.md"), dec) },
    { rel: "triage-inbox.md", text: facadeTriage(preambleOf("triage-inbox.md"), tri) },
    { rel: "budget.md", text: facadeBudget(preambleOf("budget.md"), led) },
  ];
}
