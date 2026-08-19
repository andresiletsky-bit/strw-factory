#!/usr/bin/env -S deno run --allow-read --allow-write --allow-env
// index.mjs — детермінований індекс strw-state для retrieval без моделі.
//
// НУЛЬ залежностей, НУЛЬ мережі, НУЛЬ LLM, НУЛЬ векторів. Ребра — патерн-матчинг
// wikilinks і frontmatter (метод GBrain); жодне ребро не «вигадується».
//
// ЩО ТУТ ЧИТАЄТЬСЯ, А ЩО НІ — межа проходить не там, де здається.
// Індексатор читає файли ЦІЛКОМ, і це не порушення «дієти». Без повного читання
// неможливо знати, на якому рядку починається секція, а діапазон рядків — це і
// є той товар, заради якого все будується. Обмеження «не читати моноліт»
// стосується КОНТЕКСТУ МОДЕЛІ, не диска: скрипт читає 800 KB за частку секунди
// і не витрачає жодного токена, щоб агент потім прочитав 2 KB замість 200 KB.
//
// Usage: index.mjs [--state <dir>] [--out <file>] [--quiet]

import fs from "node:fs";
import path from "node:path";

const argv = process.argv.slice(2);
const valOf = (f) => { const i = argv.indexOf(f); return i === -1 ? null : argv[i + 1]; };
const STATE = path.resolve(valOf("--state") ?? path.join(process.env.HOME ?? "", "Developer/STRW/strw-state"));
const OUT = valOf("--out") ?? path.join(STATE, "_brain", "index", "brain-index.json");

// Теки, які не є знанням компанії. `.trash` тут навмисно: після B1 там лежать
// оригінали монолітів, і без цього рядка кожен факт потрапив би в індекс двічі —
// як вузол і як копію, що ніколи не оновлюється.
const SKIP = new Set([".git", ".trash", ".obsidian", "node_modules", "attachments", "_templates", ".githooks"]);

export function walk(dir, base = dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (SKIP.has(e.name)) continue;
    const abs = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...walk(abs, base));
    else if (e.name.endsWith(".md")) out.push(path.relative(base, abs));
  }
  return out.sort();
}

// ── Frontmatter ────────────────────────────────────────────────────────────
// Свідомо НЕ повний YAML: скаляри, вбудовані списки [a, b] і списки рядками.
// Повний YAML був би залежністю, а вона заборонена не з упертості — кожна
// залежність у скрипті фабрики це ще один спосіб зламати збірку в контурі C.
export function parseFrontmatter(text) {
  if (!text.startsWith("---\n")) return { data: {}, endLine: 0 };
  const lines = text.split("\n");
  let end = -1;
  for (let i = 1; i < lines.length; i++) if (lines[i] === "---") { end = i; break; }
  if (end === -1) return { data: {}, endLine: 0 };   // незакритий блок — не frontmatter
  const data = {};
  let key = null;
  for (const raw of lines.slice(1, end)) {
    const li = raw.match(/^\s*-\s+(.*)$/);
    if (li && key) {
      if (!Array.isArray(data[key])) data[key] = data[key] ? [data[key]] : [];
      data[key].push(unquote(li[1]));
      continue;
    }
    const m = raw.match(/^([A-Za-z_][\w-]*):\s*(.*)$/);
    if (!m) continue;
    key = m[1];
    const v = m[2].trim();
    if (v === "") { data[key] = ""; continue; }
    data[key] = v.startsWith("[") && v.endsWith("]")
      ? v.slice(1, -1).split(",").map((x) => unquote(x.trim())).filter(Boolean)
      : unquote(v);
  }
  return { data, endLine: end + 1 };
}
const unquote = (s) => s.replace(/^["']|["']$/g, "").trim();

// ── Ребра: тільки те, що написано явно ─────────────────────────────────────
export function extractEdges(rel, fm, body) {
  const edges = [];
  const add = (to, kind) => {
    const t = String(to).replace(/^\[\[|\]\]$/g, "").split("|")[0].trim();
    if (t) edges.push({ from: rel, to: t, kind });
  };
  for (const k of ["up", "product", "related"]) {
    const v = fm[k];
    if (!v) continue;
    (Array.isArray(v) ? v : [v]).forEach((x) => add(x, k));
  }
  // Wikilinks у тілі. Код-фенси пропускаються: посилання всередині прикладу —
  // ілюстрація синтаксису, а не твердження про звʼязок.
  let fence = false;
  for (const ln of body.split("\n")) {
    if (/^```/.test(ln)) { fence = !fence; continue; }
    if (fence) continue;
    for (const m of ln.matchAll(/\[\[([^\]]+)\]\]/g)) add(m[1], "mentions");
  }
  return edges;
}

// ── Ключові слова ──────────────────────────────────────────────────────────
const STOP = new Set(`і й та це що як для не на в у з із до по за від про або але
щоб коли якщо його її їх ми ви вони там тут тоді все всі весь який яка яке які
бути було буде був були є має мати цей ця ці той ті так ні там чи ще вже лише
the and for that with this from are was were has have not you your our its
`.split(/\s+/).filter(Boolean));

// Груба, але детермінована нормалізація під українську морфологію: ключем є
// перші 6 символів. «рішення»/«рішень»/«рішенню» зводяться до одного ключа.
// Це не стемер і не претендує ним бути — це найдешевше, що вміє не промахнутись
// на відмінках, а відмінки тут головна причина промахів.
export const stem = (t) => (t.length > 6 ? t.slice(0, 6) : t);

export function keywords(text, cap = 40) {
  const seen = new Map();
  for (const raw of text.toLowerCase().match(/[\p{L}\p{N}][\p{L}\p{N}_-]*/gu) ?? []) {
    if (raw.length < 3 || STOP.has(raw)) continue;
    const k = stem(raw);
    seen.set(k, (seen.get(k) ?? 0) + 1);
  }
  return [...seen.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, cap).map(([k]) => k);
}

// ── Секції ─────────────────────────────────────────────────────────────────
// Одиниця видачі — СЕКЦІЯ, не файл. Саме тому «що вирішено по tea-001» коштує
// 2 KB замість 200 KB: відповідь лежить в одній секції з 76.
const PEEK = 12; // скільки рядків тіла секції йде в ключові слова

export function sections(rel, text, fmEnd) {
  const lines = text.split("\n");
  const heads = [];
  let fence = false;
  for (let i = fmEnd; i < lines.length; i++) {
    if (/^```/.test(lines[i])) { fence = !fence; continue; }
    if (!fence && /^#{1,4} /.test(lines[i])) heads.push(i);
  }
  if (heads.length === 0) {
    return [{
      path: rel, heading: path.basename(rel, ".md"), from: fmEnd + 1, to: lines.length,
      keywords: keywords(lines.slice(fmEnd, fmEnd + PEEK * 2).join(" ")),
      head_keywords: keywords(path.basename(rel, ".md"), 12),
      bytes: Buffer.byteLength(lines.slice(fmEnd).join("\n"), "utf8"),
    }];
  }
  return heads.map((start, k) => {
    const end = k + 1 < heads.length ? heads[k + 1] : lines.length;
    const heading = lines[start].replace(/^#+\s*/, "").trim();
    const peek = lines.slice(start, Math.min(end, start + PEEK)).join(" ");
    return {
      path: rel, heading, from: start + 1, to: end,
      keywords: keywords(`${heading} ${peek}`),
      // Ключові слова ЗАГОЛОВКА окремо: збіг у заголовку означає «секція про
      // це», а збіг у тілі — лише «тут це згадано». Без розділення однослівний
      // запит ранжується майже випадково: усі збіги мають однакову вагу, і
      // порядок вирішують дрібні бусти. Виміряно на «tea-001» — секція з самим
      // рішенням не потрапляла навіть у топ-4.
      head_keywords: keywords(heading, 12),
      // Чесний обсяг до прочитання. Оцінка «80 байтів на рядок» брехала вдвічі
      // на українському тексті, а це саме те число, яким міряється гейт §8.
      bytes: Buffer.byteLength(lines.slice(start, end).join("\n"), "utf8"),
    };
  });
}

export function build(state) {
  const nodes = [], edges = [], secs = [];
  for (const rel of walk(state)) {
    const text = fs.readFileSync(path.join(state, rel), "utf8");
    const { data, endLine } = parseFrontmatter(text);
    const body = text.split("\n").slice(endLine).join("\n");
    nodes.push({
      id: rel,
      title: data.title || path.basename(rel, ".md"),
      type: data.type || "",
      product: typeof data.product === "string" ? data.product.replace(/^\[\[|\]\]$/g, "") : "",
      status: data.status || "",
      updated: data.updated || data.date || "",
      tags: Array.isArray(data.tags) ? data.tags : (data.tags ? [data.tags] : []),
      bytes: Buffer.byteLength(text, "utf8"),
    });
    edges.push(...extractEdges(rel, data, body));
    secs.push(...sections(rel, text, endLine));
  }
  return { schema_version: 1, nodes, edges, sections: secs };
}

if (import.meta.main) {
  const idx = build(STATE);
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, JSON.stringify(idx));
  const b = fs.statSync(OUT).size;
  const src = idx.nodes.reduce((s, n) => s + n.bytes, 0);
  if (!argv.includes("--quiet")) {
    console.log(`brain-index: ${idx.nodes.length} вузлів · ${idx.edges.length} ребер · ${idx.sections.length} секцій`);
    console.log(`  індекс ${b} B проти ${src} B сховища (${(100 * b / src).toFixed(1)}%) → ${OUT}`);
  }
}
