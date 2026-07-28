// Item-файли реєстру — спека v2 §3.3.
//
// ЧОМУ НЕ ПОВНИЙ YAML-ROUND-TRIP. Item-файли — це не машинні дампи, а робочі
// документи: багаторядкові `acceptance`, коментарі з посиланнями на рядки коду,
// і пряма інструкція W0a «НОТАТКА W0a → W0b (не видаляти без рішення)».
// Будь-який серіалізатор, що переписує файл із дерева об'єктів, їх зітре.
// Тому: читання — парсер підмножини YAML, запис — хірургічна заміна рядків.

export interface Lease0 {
  run_id: string | null;
  epoch: number;
  heartbeat: number | null;
}

export interface Item {
  schema_version: number;
  id: string;
  product?: string;
  loop?: string;
  lane: string;
  /** Друга смуга. §3.3 має рівно одне `lane`, але гейт рівня 4 без цього впаде. */
  also_touches?: string[];
  state: string;
  blocked_by?: string[];
  blocked_since?: string | null;
  repo: string;
  branch?: string;
  size?: string;
  acceptance?: string;
  acceptance_basis?: {
    sources?: string[];
    verified_against_decisions_log_at?: string;
  };
  lease: Lease0;
  evidence?: Record<string, unknown>;
  attempts: number;
  pr?: number | null;
  head_sha?: string | null;
  merge_commit?: string | null;
  // деякі елементи несуть довільні додаткові поля — не втрачаємо їх при читанні
  [k: string]: unknown;
}

type Scalar = string | number | boolean | null;

function parseScalar(raw: string): Scalar {
  const s = raw.trim();
  if (s === "" || s === "null" || s === "~") return null;
  if (s === "true") return true;
  if (s === "false") return false;
  if (/^-?\d+$/.test(s)) return Number(s);
  if (/^-?\d*\.\d+$/.test(s)) return Number(s);
  if (
    (s.startsWith('"') && s.endsWith('"') && s.length > 1) ||
    (s.startsWith("'") && s.endsWith("'") && s.length > 1)
  ) {
    return s.slice(1, -1);
  }
  return s;
}

/** Обрізає коментар, але тільки поза лапками. */
function stripComment(line: string): string {
  let inS = false, inD = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (c === "'" && !inD) inS = !inS;
    else if (c === '"' && !inS) inD = !inD;
    else if (c === "#" && !inS && !inD) {
      // `#` рахується коментарем лише після пробілу або на початку
      if (i === 0 || /\s/.test(line[i - 1])) return line.slice(0, i);
    }
  }
  return line;
}

type FlowValue = Scalar | FlowValue[] | { [k: string]: FlowValue };

/** Рекурсивно — вкладений список усередині inline-мапи мусить лишитись списком. */
function parseFlowValue(raw: string): FlowValue {
  return parseFlow(raw) ?? parseScalar(raw);
}

function parseFlow(raw: string): FlowValue[] | Record<string, FlowValue> | null {
  const s = raw.trim();
  if (s.startsWith("[") && s.endsWith("]")) {
    const inner = s.slice(1, -1).trim();
    if (inner === "") return [];
    return splitTop(inner).map(parseFlowValue);
  }
  if (s.startsWith("{") && s.endsWith("}")) {
    const inner = s.slice(1, -1).trim();
    const out: Record<string, FlowValue> = {};
    if (inner === "") return out;
    for (const part of splitTop(inner)) {
      const i = part.indexOf(":");
      if (i < 0) continue;
      out[part.slice(0, i).trim()] = parseFlowValue(part.slice(i + 1));
    }
    return out;
  }
  return null;
}

/** Ділить по комах верхнього рівня — вкладені [] {} і лапки не ріже. */
function splitTop(s: string): string[] {
  const out: string[] = [];
  let depth = 0, inS = false, inD = false, cur = "";
  for (const c of s) {
    if (c === "'" && !inD) inS = !inS;
    else if (c === '"' && !inS) inD = !inD;
    if (!inS && !inD) {
      if (c === "[" || c === "{") depth++;
      else if (c === "]" || c === "}") depth--;
      else if (c === "," && depth === 0) {
        out.push(cur);
        cur = "";
        continue;
      }
    }
    cur += c;
  }
  if (cur.trim() !== "") out.push(cur);
  return out.map((x) => x.trim());
}

const KEY_RE = /^([A-Za-z_][A-Za-z0-9_]*):(.*)$/;

export function parseItem(text: string): Item {
  const lines = text.split("\n");
  const obj: Record<string, unknown> = {};
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];
    // ключі верхнього рівня — рівно нульовий відступ
    const m = KEY_RE.exec(line);
    if (!m) {
      i++;
      continue;
    }
    const key = m[1];
    const rest = m[2];
    const restTrim = stripComment(rest).trim();

    // блочний літерал: `key: |` або `key: >`
    if (restTrim === "|" || restTrim === "|-" || restTrim === ">" || restTrim === ">-") {
      const body: string[] = [];
      i++;
      while (i < lines.length) {
        const l = lines[i];
        if (l.trim() !== "" && !/^\s/.test(l)) break; // повернулись на нульовий відступ
        body.push(l.replace(/^ {2}/, ""));
        i++;
      }
      obj[key] = body.join("\n").replace(/\n+$/, "\n");
      continue;
    }

    // inline flow
    const flow = parseFlow(restTrim);
    if (flow !== null) {
      obj[key] = flow;
      i++;
      continue;
    }

    // скаляр на тому ж рядку
    if (restTrim !== "") {
      obj[key] = parseScalar(restTrim);
      i++;
      continue;
    }

    // вкладений блок (мапа або послідовність)
    const child: Record<string, unknown> = {};
    const seq: Scalar[] = [];
    i++;
    while (i < lines.length) {
      const l = lines[i];
      if (l.trim() === "") { i++; continue; }
      if (!/^\s/.test(l)) break;
      const t = stripComment(l).trim();
      if (t.startsWith("- ")) {
        seq.push(parseScalar(t.slice(2)));
      } else {
        const cm = KEY_RE.exec(t);
        if (cm) {
          const ck = cm[1];
          const cv = stripComment(cm[2]).trim();
          const cflow = parseFlow(cv);
          if (cflow !== null) child[ck] = cflow;
          else if (cv !== "") child[ck] = parseScalar(cv);
          else {
            // вкладена послідовність під ключем другого рівня
            const sub: Scalar[] = [];
            let j = i + 1;
            while (j < lines.length) {
              const sl = stripComment(lines[j]);
              if (sl.trim() === "") { j++; continue; }
              if (!/^\s{3,}/.test(sl)) break;
              const st = sl.trim();
              if (!st.startsWith("- ")) break;
              sub.push(parseScalar(st.slice(2)));
              j++;
            }
            child[ck] = sub;
            i = j - 1;
          }
        }
      }
      i++;
    }
    obj[key] = seq.length > 0 ? seq : child;
  }

  if (typeof obj.schema_version !== "number") {
    throw new Error(
      `item-файл без schema_version — версіювання схеми обов'язкове (§11), мовчазний дефолт заборонено`,
    );
  }
  return obj as unknown as Item;
}

/** Скаляр → YAML-текст. Лапки лише там, де без них файл ламається. */
function emitScalar(v: unknown): string {
  if (v === null || v === undefined) return "null";
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  const s = String(v);
  if (s === "") return '""';
  if (/[:#\[\]{}",]|^\s|\s$|^[&*!|>%@`]/.test(s)) {
    return `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
  }
  return s;
}

function emitValue(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(emitScalar).join(", ")}]`;
  if (v !== null && typeof v === "object") {
    const entries = Object.entries(v as Record<string, unknown>);
    return `{${entries.map(([k, val]) => `${k}: ${emitScalar(val)}`).join(", ")}}`;
  }
  return emitScalar(v);
}

/**
 * Хірургічний запис: замінює рядок наявного ключа верхнього рівня або дописує новий
 * після останнього ключа верхнього рівня (перед хвостовими коментарями).
 * Усе, що не назване, лишається байт-у-байт.
 */
export function setFields(text: string, fields: Record<string, unknown>): string {
  let lines = text.split("\n");

  for (const [key, value] of Object.entries(fields)) {
    const rendered = `${key}: ${emitValue(value)}`;

    // знайти рядок цього ключа на нульовому відступі, ігноруючи блочні літерали
    let idx = -1;
    let inBlock = false;
    for (let i = 0; i < lines.length; i++) {
      const l = lines[i];
      if (inBlock) {
        if (l.trim() !== "" && !/^\s/.test(l)) inBlock = false;
        else continue;
      }
      const m = KEY_RE.exec(l);
      if (!m) continue;
      const restTrim = stripComment(m[2]).trim();
      if (restTrim === "|" || restTrim === "|-" || restTrim === ">" || restTrim === ">-") {
        if (m[1] === key) { idx = i; break; }
        inBlock = true;
        continue;
      }
      if (m[1] === key) { idx = i; break; }
    }

    if (idx >= 0) {
      lines[idx] = rendered;
      continue;
    }

    // нового ключа немає — вставити після останнього ключа верхнього рівня,
    // щоб хвостові коментарі лишились хвостовими
    let last = -1;
    inBlock = false;
    for (let i = 0; i < lines.length; i++) {
      const l = lines[i];
      if (inBlock) {
        if (l.trim() !== "" && !/^\s/.test(l)) inBlock = false;
        else continue;
      }
      const m = KEY_RE.exec(l);
      if (!m) continue;
      last = i;
      const restTrim = stripComment(m[2]).trim();
      if (restTrim === "|" || restTrim === "|-" || restTrim === ">" || restTrim === ">-") {
        inBlock = true;
      }
    }
    // дописати після останнього ключа разом із його вкладеним блоком
    let insertAt = last + 1;
    while (insertAt < lines.length && /^\s/.test(lines[insertAt]) && lines[insertAt].trim() !== "") {
      insertAt++;
    }
    lines = [...lines.slice(0, insertAt), rendered, ...lines.slice(insertAt)];
  }

  return lines.join("\n");
}

export function readItem(path: string): Item {
  return parseItem(Deno.readTextFileSync(path));
}

/** Запис item-файлу через tmp + rename(2), як і ліза. */
export function writeItemFields(path: string, fields: Record<string, unknown>): Item {
  const next = setFields(Deno.readTextFileSync(path), fields);
  const tmp = `${path}.${crypto.randomUUID()}.tmp`;
  Deno.writeTextFileSync(tmp, next);
  Deno.renameSync(tmp, path);
  return parseItem(next);
}
