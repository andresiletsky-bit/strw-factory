#!/usr/bin/env -S deno run --allow-read --allow-env
// query.mjs — «спершу спитай, потім читай»: топ-K СЕКЦІЙ замість цілих файлів.
//
// НУЛЬ векторів, НУЛЬ БД, НУЛЬ мережі, НУЛЬ LLM. Скоринг — керовані слова
// запиту × ключові слова секції з idf-вагою, плюс невеликі бусти.
//
// Usage:
//   query.mjs "<запит>" [-k N] [--index <file>] [--json]
//
// Вивід за замовчуванням — те, що агент має прочитати далі, і нічого більше:
//   strw-state/decisions-log.md:326-341   score 8.42  · G1 tea-001 …

import fs from "node:fs";
import path from "node:path";

const argv = process.argv.slice(2);
const valOf = (f) => { const i = argv.indexOf(f); return i === -1 ? null : argv[i + 1]; };
// Прапорці зі значенням треба знати ПОІМЕННО, інакше значення втікає в текст
// запиту. Стара редакція фільтрувала лише `-k` та `--index`, тож шлях із
// `--state` ставав частиною запиту — а він містить «claude-502», і кожен
// запит мовчки шукав ще й це слово. Спіймано негативним контролем: запит
// «квантова телепортація мавп» повертав секції зі збігом `claude`.
const FLAGS_WITH_VALUE = new Set(["-k", "--index", "--state", "--out"]);
const QUERY = argv.filter((a, i) =>
  !a.startsWith("-") && !FLAGS_WITH_VALUE.has(argv[i - 1])).join(" ").trim();
const K = Number(valOf("-k") ?? 5);
const STATE = path.resolve(valOf("--state") ?? path.join(process.env.HOME ?? "", "Developer/STRW/strw-state"));
const INDEX = valOf("--index") ?? path.join(STATE, "_brain", "index", "brain-index.json");

const STOP = new Set(`і й та це що як для не на в у з із до по за від про або але
щоб коли якщо його її їх ми ви вони там тут тоді все всі весь який яка яке які
бути було буде був були є має мати цей ця ці той ті так ні чи ще вже лише
скільки хто коли чому яких кого кому чим
the and for that with this from are was were has have not you your our its
`.split(/\s+/).filter(Boolean));

const stem = (t) => (t.length > 6 ? t.slice(0, 6) : t);
const tokens = (s) => [...new Set((s.toLowerCase().match(/[\p{L}\p{N}][\p{L}\p{N}_-]*/gu) ?? [])
  .filter((t) => t.length >= 3 && !STOP.has(t)).map(stem))];

export function score(index, query, k = 5) {
  const qs = tokens(query);
  if (qs.length === 0) return [];

  // df рахується по секціях: слово, що є всюди, майже нічого не звужує.
  const df = new Map();
  for (const s of index.sections) for (const w of new Set(s.keywords)) df.set(w, (df.get(w) ?? 0) + 1);
  const N = index.sections.length || 1;
  const idf = (w) => Math.log(1 + N / (1 + (df.get(w) ?? 0)));

  const byPath = new Map(index.nodes.map((n) => [n.id, n]));
  const newest = index.nodes.map((n) => n.updated).filter(Boolean).sort().pop() ?? "";

  const out = [];
  for (const s of index.sections) {
    const kw = new Set(s.keywords);
    const hit = qs.filter((q) => kw.has(q));
    if (hit.length === 0) continue;

    // Збіг у ЗАГОЛОВКУ важить утричі більше за збіг у тілі: перше означає, що
    // секція про це, друге — що тут це згадано. Найдешевше правило з усіх, і
    // воно єдине зрушило «tea-001» з-поза топ-4 на перше місце.
    const head = new Set(s.head_keywords ?? []);
    let sc = hit.reduce((a, w) => a + idf(w) * (head.has(w) ? 3 : 1), 0);
    // Частка ЗАПИТУ, що влучила, важить більше за довжину секції: секція, яка
    // покриває 3 слова з 3, потрібніша за ту, що покриває 3 з 12.
    sc *= 0.5 + 0.5 * (hit.length / qs.length);

    // Штраф за довжину. Секція на 535 рядків конкурувала нарівні з
    // дев'ятирядковою, хоча коштує прочитання у 60 разів дорожче — а вся
    // затія саме про вартість прочитання. Логарифм, не лінійність: довга
    // секція має програвати, а не зникати.
    const len = Math.max(1, s.to - s.from + 1);
    sc /= 1 + Math.log10(1 + len / 20);

    // Секція-обрубок відповісти не може. `# tea-001 · state` — заголовок із
    // порожнім тілом — виграла запит «що вирішено по tea-001», обійшовши сам
    // запис рішення: у неї збіг у заголовку і майже нульовий штраф за довжину.
    // Тому вага росте з тим, скільки секція реально КАЖЕ понад свій заголовок.
    const headSet = new Set(s.head_keywords ?? []);
    const bodyWords = (s.keywords ?? []).filter((w) => !headSet.has(w)).length;
    sc *= Math.min(1, 0.25 + bodyWords / 8);

    const n = byPath.get(s.path);
    if (n) {
      // Продукт, названий у запиті, — найсильніший сигнал, який у нас є задарма.
      if (n.product && qs.includes(stem(n.product.toLowerCase()))) sc *= 1.6;
      if (n.type && qs.includes(stem(n.type.toLowerCase()))) sc *= 1.25;
      // Свіжість: слабкий буст, свідомо. Стан фабрики такий, що старе рішення
      // лишається чинним, поки його не скасували — дата не робить його гіршим.
      if (n.updated && newest && n.updated >= newest.slice(0, 4)) sc *= 1.05;
    }
    out.push({ path: s.path, heading: s.heading, from: s.from, to: s.to, bytes: s.bytes ?? 0, score: +sc.toFixed(3), hit });
  }
  // Детермінований порядок: за скором, далі за шляхом і рядком — щоб однакові
  // скори не переставлялись між запусками.
  return out.sort((a, b) => b.score - a.score || a.path.localeCompare(b.path) || a.from - b.from).slice(0, k);
}

if (import.meta.main) {
  if (!QUERY) { console.error('usage: query.mjs "<запит>" [-k N]'); process.exit(2); }
  if (!fs.existsSync(INDEX)) {
    console.error(`індексу немає: ${INDEX}\n  побудувати: scripts/brain/index.mjs`);
    process.exit(1);
  }
  const index = JSON.parse(fs.readFileSync(INDEX, "utf8"));
  const hits = score(index, QUERY, K);
  if (argv.includes("--json")) { console.log(JSON.stringify(hits, null, 1)); }
  else if (hits.length === 0) {
    // Чесна порожнеча — теж відповідь, і саме її перевіряє негативний контроль
    // гейта §8: система, що завжди щось повертає, не вміє сказати «не знаю».
    console.log("нічого не знайдено — індекс не має секції під цей запит");
  } else {
    let bytes = 0;
    for (const h of hits) {
      console.log(`${h.path}:${h.from}-${h.to}  score ${h.score}  · ${h.heading.slice(0, 70)}`);
      bytes += h.bytes;
    }
    console.log(`\n${hits.length} секцій · ${bytes} B до прочитання`);
  }
}
