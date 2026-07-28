// Фаза 3 Settle — спека v2 §4.
//
// «Фаза 3 пише state.md.» v1 не писала його взагалі — пряме порушення hard rule
// «State або не сталося» (README + принцип №7). У v2 state.md лишається, але стає
// ПОХІДНИМ ДЗЕРКАЛОМ items/, а не джерелом.
//
// Практична поправка: state.md pact-001 — це 661 рядок людського тексту
// (Done, Next, Open questions, Tried & failed). Переписувати його цілком не можна.
// Тому машинний зріз живе між маркерами, а все поза ними не чіпається.

export const BLOCK_START = "<!-- ENGINE:ITEMS:BEGIN — генерується диспетчером, руками не правити -->";
export const BLOCK_END = "<!-- ENGINE:ITEMS:END -->";

export interface MirrorItem {
  id: string;
  state: string;
  lane?: string;
  attempts?: number;
  pr?: number | null;
}

export interface BlockMeta {
  tick: number;
  cycle_id: string;
  generated_at?: string;
}

export function renderEngineBlock(items: MirrorItem[], meta: BlockMeta): string {
  const counts: Record<string, number> = {};
  for (const it of items) counts[it.state] = (counts[it.state] ?? 0) + 1;
  const summary = Object.entries(counts)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([k, v]) => `${k}=${v}`)
    .join(", ");

  const rows = items
    .slice()
    .sort((a, b) => a.id.localeCompare(b.id))
    .map((it) =>
      `| \`${it.id}\` | ${it.state} | ${it.lane ?? "—"} | ${it.attempts ?? 0} | ${
        it.pr ? `#${it.pr}` : "—"
      } |`
    )
    .join("\n");

  return [
    BLOCK_START,
    "",
    `### Реєстр рушія — тік ${meta.tick} · cycle_id \`${meta.cycle_id}\``,
    "",
    `Похідне дзеркало \`engine/items/\`. Джерело правди — items/, не цей блок.`,
    `Зведення: ${summary} · усього ${items.length}.`,
    meta.generated_at ? `Згенеровано: ${meta.generated_at}.` : "",
    "",
    "| елемент | стан | смуга | спроб | PR |",
    "|---|---|---|---|---|",
    rows,
    "",
    BLOCK_END,
  ].filter((l) => l !== "").join("\n");
}

/** Вставити або замінити машинний блок. Ідемпотентно: другий блок ніколи не з'являється. */
export function upsertBlock(doc: string, block: string): string {
  const i = doc.indexOf(BLOCK_START);
  if (i === -1) {
    const sep = doc.endsWith("\n") ? "\n" : "\n\n";
    return doc + sep + block + "\n";
  }
  const j = doc.indexOf(BLOCK_END, i);
  if (j === -1) {
    throw new Error("state.md: є BEGIN-маркер без END — файл треба полагодити руками");
  }
  return doc.slice(0, i) + block + doc.slice(j + BLOCK_END.length);
}

export interface CycleRecord {
  cycle_id: string;
  tick: number;
  started_at: string;
  finished_at: string;
  selected: string[];
  outcomes: Record<string, string>;
  n: number;
  notes?: string[];
}

/** Один рядок JSONL для engine/cycles/<YYYY-Www>.jsonl. */
export function cycleLine(rec: CycleRecord): string {
  return JSON.stringify(rec);
}

/** ISO-тиждень, як його називає файл cycles/<YYYY-Www>.jsonl. */
export function isoWeekFile(d: Date): string {
  const t = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
  const day = t.getUTCDay() || 7;
  t.setUTCDate(t.getUTCDate() + 4 - day);
  const yearStart = new Date(Date.UTC(t.getUTCFullYear(), 0, 1));
  const week = Math.ceil(((t.getTime() - yearStart.getTime()) / 86400000 + 1) / 7);
  return `${t.getUTCFullYear()}-W${String(week).padStart(2, "0")}`;
}
