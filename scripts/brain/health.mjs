#!/usr/bin/env -S deno run --allow-read --allow-env
// health.mjs — гігієна графа для L6-ретро: биті лінки · дублі · сироти.
//
// Три пункти чек-листа ретро мають ВИКОНАВЦЯ, а не абзац: правило, записане
// прозою, гниє (патерн П-4 ретро W33), а скрипт — ні. Нуль LLM, читає лише
// готовий `brain-index.json`.
//
// Usage: health.mjs [--state <dir>] [--json] [--fail-on-broken]

import fs from "node:fs";
import path from "node:path";

const argv = process.argv.slice(2);
const val = (f) => { const i = argv.indexOf(f); return i === -1 ? null : argv[i + 1]; };
const STATE = path.resolve(val("--state") ?? path.join(process.env.HOME ?? "", "Developer/STRW/strw-state"));
const INDEX = val("--index") ?? path.join(STATE, "_brain", "index", "brain-index.json");

if (!fs.existsSync(INDEX)) {
  console.error(`індексу немає: ${INDEX}\n  побудувати: scripts/brain/index.mjs`);
  process.exit(2);
}
const idx = JSON.parse(fs.readFileSync(INDEX, "utf8"));

// Ціль вікі-лінка вважається живою, якщо збігається з шляхом, іменем файлу,
// заголовком або id вузла — Obsidian резолвить саме так, і вужча перевірка
// давала б хибні «биті» на кожному лінку без розширення.
const alias = new Set();
for (const n of idx.nodes) {
  alias.add(n.id);
  alias.add(n.id.replace(/\.md$/, ""));
  alias.add(path.basename(n.id, ".md"));
  if (n.title) alias.add(n.title);
}
// Нормалізація цілі. Три пастки, знайдені першим же прогоном на живому графі:
// (1) у таблицях труба екранована — `[[triage-inbox\|Triage Inbox]]`, і наївний
//     розріз лишав хвостовий `\`, роблячи живий лінк «битим»;
// (2) ціль може бути не-markdown (`bases/*.base`) — індекс їх не тримає за
//     побудовою, тож це поза скоупом, а не поломка;
// (3) якір `#секція` до імені файлу не належить.
const norm = (to) => to.replace(/#.*$/, "").replace(/\\?\|.*$/, "").replace(/\\+$/, "").trim();
const OUT_OF_SCOPE = /\.(base|canvas|png|jpg|pdf)$/i;
const broken = idx.edges.filter((e) => {
  const t = norm(e.to);
  if (!t || OUT_OF_SCOPE.test(t)) return false;
  return !alias.has(t) && !alias.has(path.basename(t, ".md")) && !alias.has(t.replace(/\.md$/, ""));
});

// Дублі: два вузли з однаковим базовим іменем або однаковим заголовком.
const byBase = new Map(), byTitle = new Map();
for (const n of idx.nodes) {
  const b = path.basename(n.id, ".md");
  (byBase.get(b) ?? byBase.set(b, []).get(b)).push(n.id);
  if (n.title) (byTitle.get(n.title) ?? byTitle.set(n.title, []).get(n.title)).push(n.id);
}
const dupBase = [...byBase.entries()].filter(([, v]) => v.length > 1);
const dupTitle = [...byTitle.entries()].filter(([, v]) => v.length > 1 && new Set(v).size > 1);

// Сироти: вузол, на який ніхто не посилається. Це не помилка — це кандидат у
// gap-analysis: або його ніхто не знайде, або він більше не потрібен.
// «Сирота» = вузол БЕЗ ЖОДНОГО зв'язку, а не без вхідного. Генеровані вузли
// чіпляються до графа через `up:` — рахувати їх сиротами означало б звітувати
// 285 із 320 і поховати справжні знахідки в шумі.
const linked = new Set(idx.edges.map((e) => norm(e.to)));
const hasUp = new Set(idx.edges.filter((e) => e.kind === "up" || e.kind === "product").map((e) => e.from));
const orphans = idx.nodes.filter((n) =>
  !hasUp.has(n.id) &&
  !linked.has(path.basename(n.id, ".md")) && !linked.has(n.title) && !linked.has(n.id));

const report = {
  broken_links: broken.map((e) => ({ from: e.from, to: e.to, kind: e.kind })),
  duplicate_basenames: dupBase.map(([k, v]) => ({ name: k, paths: v })),
  duplicate_titles: dupTitle.map(([k, v]) => ({ title: k, paths: v })),
  orphans: orphans.map((n) => n.id),
  totals: { nodes: idx.nodes.length, edges: idx.edges.length,
            broken: broken.length, dup: dupBase.length + dupTitle.length, orphans: orphans.length },
};

if (argv.includes("--json")) console.log(JSON.stringify(report, null, 1));
else {
  const t = report.totals;
  console.log(`граф: ${t.nodes} вузлів · ${t.edges} ребер`);
  console.log(`  биті лінки:      ${t.broken}`);
  console.log(`  дублі імен/назв: ${t.dup}`);
  console.log(`  сироти:          ${t.orphans}  (кандидати в gap-analysis, не помилка)`);
  for (const b of report.broken_links.slice(0, 12)) console.log(`    ✗ ${b.from} → [[${b.to}]]`);
  if (report.broken_links.length > 12) console.log(`    … ще ${report.broken_links.length - 12}`);
  for (const d of report.duplicate_basenames.slice(0, 6)) console.log(`    ⚠ дубль «${d.name}»: ${d.paths.join(" · ")}`);
}
if (argv.includes("--fail-on-broken") && broken.length > 0) process.exit(1);
