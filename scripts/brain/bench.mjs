#!/usr/bin/env -S deno run --allow-read
// bench.mjs — детермінований вимір вартості retrieval для гейта §8 Second Brain v1.
//
// ЧОМУ ЦЕЙ ФАЙЛ ІСНУЄ, А ЦИФРИ НЕ ЖИВУТЬ У ЗВІТІ СЕСІЇ.
// Вимір «до/після», зроблений тим самим агентом, що будує індекс, завжди виходить
// зелений — база підбирається під результат заднім числом. Єдиний захист: зафіксувати
// базу ДО в git, поки моноліти ще цілі, і потім не мати можливості її переписати.
// Тому base знімається окремим запуском, комітиться як `bench.baseline.json`, а режим
// `after` порівнює з НЕЮ, а не з тим, що агент пам'ятає.
//
// Нуль залежностей, нуль мережі, нуль LLM. Рантайм: Deno (як решта scripts/), але
// написано на node:-білтінах, тож той самий файл виконає і Node ≥18.
//
// Usage:
//   bench.mjs before [--state <dir>]     → JSON бази (у stdout; перенаправ у bench.baseline.json)
//   bench.mjs floor  [--state <dir>]     → скільки байтів займають САМІ відповіді сьогодні

import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
const mode = args[0] ?? "";
const stateArg = args.indexOf("--state");
const STATE = stateArg !== -1
  ? path.resolve(args[stateArg + 1])
  : path.join(process.env.HOME ?? "", "Developer/STRW/strw-state");

// ── Еталонні запити гейта §8 ────────────────────────────────────────────────
//
// `before` — НЕ вигаданий «мінімум»: це дослівний припис чинної фабрики, і кожен
// рядок несе своє джерело в `beforeWhy`. Солом'яна база (роздути ДО, щоб ПІСЛЯ
// виглядало краще) — головний спосіб пройти цей гейт із хибної причини, тож
// джерело зобов'язане бути цитованим, а не правдоподібним.
//
// `answer` — де відповідь лежить НАСПРАВДІ (звірено очима 14.08). Дає підлогу:
// скільки байтів у принципі потрібно. Різниця між before і floor — це баласт.
const QUERIES = [
  {
    id: "q1-tea-001",
    question: "що вирішено по tea-001 і чому",
    before: ["company-context.md", "decisions-log.md"],
    beforeWhy:
      'company-context.md § «Де живуть факти»: «Що вже вирішено і чому → decisions-log.md»; ' +
      "ДНК читається перед будь-якою роботою (loop-passport.md крок 1)",
    answer: [{ file: "decisions-log.md", startRe: /^## .*·\s*tea-001\s*·/ }],
    answerIs: "G1 не ухвалено, продукт явно заморожено до релізу Pact (2026-07-28)",
  },
  {
    id: "q2-budget-ceiling",
    question: "скільки лишилось стелі зовнішніх витрат",
    before: ["company-context.md", "budget.md"],
    beforeWhy:
      'company-context.md § «Де живуть факти»: «Стелі прогонів петель, моделі, зовнішні витрати → budget.md»; ' +
      "loop-passport.md крок 2 «Budget check — звірити budget.md»",
    // УВАГА, і це знахідка, а не деталь: відповідь тут АГРЕГАТ. Стеля лежить у
    // шапці, а витрачене — сума всіх рядків «Факт». Тобто секціонування саме по
    // собі Q2 не здешевлює: підлога дорівнює майже всьому файлу. Здешевлює лише
    // фасад із ПОРАХОВАНИМ підсумком — саме тому він у скоупі B1.
    answer: [
      { file: "budget.md", startRe: /^---$/, endRe: /^# Budget/ },
      { file: "budget.md", startRe: /^## Стелі/ },
      { file: "budget.md", startRe: /^## Факт/ },
    ],
    answerIs: "стеля $200/міс; факт — сума 82 рядків «Факт» = $0; лишилось $200",
  },
  {
    id: "q3-pact-001-waiting",
    question: "що чекає рішення Andrii по pact-001",
    before: ["company-context.md", "triage-inbox.md", "portfolio.md", "budget.md"],
    beforeWhy:
      "skills/strw-triage/SKILL.md Step 1 (дослівно): «strw-state/triage-inbox.md (усі OPEN) + " +
      "portfolio.md + budget.md (факт місяця)»",
    answer: [{ file: "triage-inbox.md", startRe: /^## \[OPEN\]/, all: true }],
    answerIs: "gate-request 14.08 19:0x — lock M3-скоупу (після B0 це єдиний OPEN по pact-001)",
  },
];

// ── Механіка ───────────────────────────────────────────────────────────────

const bytes = (p) => fs.statSync(path.join(STATE, p)).size;

// Витяг секції: від рядка, що збігся зі startRe, до наступного `## ` (або endRe).
// Рахуємо байти саме тексту секції — з переводами рядків, як їх прочитає агент.
function spanBytes(spec) {
  const lines = fs.readFileSync(path.join(STATE, spec.file), "utf8").split("\n");
  const end = spec.endRe ?? /^## /;
  let total = 0, hits = 0, i = 0;
  while (i < lines.length) {
    if (!spec.startRe.test(lines[i])) { i++; continue; }
    hits++;
    let j = i + 1;
    while (j < lines.length && !end.test(lines[j])) j++;
    total += Buffer.byteLength(lines.slice(i, j).join("\n") + "\n", "utf8");
    if (!spec.all) return { bytes: total, hits };
    i = j;
  }
  return { bytes: total, hits };
}

const report = { schema_version: 1, state: STATE, mode, queries: [] };

for (const q of QUERIES) {
  const beforeFiles = q.before.map((f) => ({ file: f, bytes: bytes(f) }));
  const beforeBytes = beforeFiles.reduce((s, f) => s + f.bytes, 0);
  const spans = q.answer.map((a) => ({ file: a.file, ...spanBytes(a) }));
  const floorBytes = spans.reduce((s, a) => s + a.bytes, 0);

  report.queries.push({
    id: q.id,
    question: q.question,
    before_bytes: beforeBytes,
    before_files: beforeFiles,
    before_why: q.beforeWhy,
    floor_bytes: floorBytes,
    floor_spans: spans,
    answer_is: q.answerIs,
    ballast_pct: +(100 * (1 - floorBytes / beforeBytes)).toFixed(1),
  });
}

// ── Режим «після»: чи здешевшало І чи відповідь узагалі знайшлась ──────────
//
// Міряти самі байти тут недостатньо, і це головна пастка гейта §8: retrieval,
// що повертає три випадкові секції, дає −99% обсягу і виглядає тріумфом.
// Тому кожен запит несе КАНОНІЧНЕ місце відповіді, і запуск зараховується
// лише тоді, коли видача це місце накрила.
const ANSWER_AT = {
  "q1-tea-001": { file: "decisions-log.md", startRe: /^## .*·\s*tea-001\s*·/ },
  "q2-budget-ceiling": { file: "budget.md", startRe: /^## Стелі/ },
  "q3-pact-001-waiting": { file: "triage-inbox.md", startRe: /^## \[OPEN\]/ },
};

function answerSpan(id) {
  const spec = ANSWER_AT[id];
  const lines = fs.readFileSync(path.join(STATE, spec.file), "utf8").split("\n");
  for (let i = 0; i < lines.length; i++) {
    if (!spec.startRe.test(lines[i])) continue;
    let j = i + 1;
    while (j < lines.length && !/^## /.test(lines[j])) j++;
    return { file: spec.file, from: i + 1, to: j };
  }
  return null;
}

if (mode === "after") {
  const hitsJson = args[args.indexOf("--hits") + 1] ?? null;
  if (args.indexOf("--hits") === -1 || !hitsJson) { console.error("after: потрібен --hits <файл з видачею query.mjs --json по кожному запиту>"); process.exit(2); }
  const all = JSON.parse(fs.readFileSync(hitsJson, "utf8"));
  for (const q of report.queries) {
    const hits = all[q.id] ?? [];
    const want = answerSpan(q.id);
    const covered = want !== null && hits.some((h) =>
      h.path === want.file && h.from <= want.to && h.to >= want.from);
    q.after_bytes = hits.reduce((s, h) => s + (h.bytes ?? 0), 0);
    q.after_sections = hits.length;
    q.answer_covered = covered;
    q.answer_at = want;
    q.reduction_pct = +(100 * (1 - q.after_bytes / q.before_bytes)).toFixed(1);
  }
  const red = report.queries.map((q) => q.reduction_pct).sort((a, b) => a - b);
  report.median_reduction_pct = red[Math.floor(red.length / 2)];
  report.correct = report.queries.filter((q) => q.answer_covered).length;
  report.gate_pass = report.median_reduction_pct >= 50 && report.correct === report.queries.length;
  console.log(JSON.stringify(report, null, 1));
} else if (mode === "before" || mode === "floor") {
  console.log(JSON.stringify(report, null, 2));
} else {
  console.error("usage: bench.mjs before|floor [--state <dir>]");
  process.exit(2);
}
