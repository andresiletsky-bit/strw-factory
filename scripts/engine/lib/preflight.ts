// Фаза 0 Preflight — спека v2 §3.1, §4.
//
// «Жорсткий інваріант: `strw-state` незаписуваний або має незапушені коміти →
//  планувальник не планує нічого. Не "тік завершується чисто" — тік не починається.»
//
// Різниця не косметична. Тік, який «почався і завершився чисто», лишає по собі
// запис у телеметрії, зайняті лізи й списаний цикл. Тік, який не почався, не лишає
// нічого — і саме це потрібно, коли стан нікуди записати.

import { run } from "./world.ts";

export function isWritable(dir: string): boolean {
  const probe = `${dir}/.engine-preflight-probe.${crypto.randomUUID()}`;
  try {
    Deno.writeTextFileSync(probe, "probe\n");
    Deno.removeSync(probe);
    return true;
  } catch {
    return false;
  }
}

/**
 * Незапушені коміти. HEAD і origin/main звіряються ОКРЕМИМИ командами —
 * так вимагає промт сесії, і так помилка одного виклику не маскує іншу.
 */
export function hasUnpushedCommits(repoRoot: string, remoteRef = "origin/main"): boolean {
  const head = run(repoRoot, ["git", "rev-parse", "HEAD"]);
  const remote = run(repoRoot, ["git", "rev-parse", remoteRef]);
  if (!head.ok || !remote.ok) {
    // Не знаємо стану віддаленого — вважаємо небезпечним. Мовчазне «false» тут
    // означало б «пиши далі», а це рівно той клас інциденту, від якого захист.
    return true;
  }
  if (head.stdout.trim() === remote.stdout.trim()) return false;

  const ahead = run(repoRoot, ["git", "rev-list", "--count", `${remoteRef}..HEAD`]);
  if (!ahead.ok) return true;
  return Number(ahead.stdout.trim()) > 0;
}

export interface ValidateResult {
  ok: boolean;
  output: string;
}

export interface PreflightOpts {
  stateRepo: string;
  /** Обгортка над validate-items.sh — інжектується, щоб тести не залежали від репо. */
  validate: () => ValidateResult;
  itemCount?: number;
  previousItemCount?: number;
}

export interface PreflightResult {
  ok: boolean;
  /** Чи тік узагалі почався. Синонім ok, але названий так, як пише спека. */
  started: boolean;
  stop_reason: string | null;
  notes: string[];
}

function stop(reason: string): PreflightResult {
  return { ok: false, started: false, stop_reason: reason, notes: [] };
}

export function preflight(opts: PreflightOpts): PreflightResult {
  // 1. Записуваність — ПЕРШОЮ. Якщо стан нікуди писати, решта перевірок
  //    не має сенсу і не має права витрачати час чи квоту.
  if (!isWritable(opts.stateRepo)) {
    return stop(
      `strw-state незаписуваний (${opts.stateRepo}) — тік НЕ починається (§3.1). ` +
        `27.07 цей стан тривав 5 год 52 хв, поки продуктове репо робило 10 комітів.`,
    );
  }

  // 2. Незапушені коміти.
  if (hasUnpushedCommits(opts.stateRepo)) {
    return stop(
      `strw-state має незапушені коміти — тік НЕ починається (§3.1). ` +
        `Спершу git push, інакше стан тіку ляже поверх незвіреної історії.`,
    );
  }

  // 3. Реєстр. validate-items.sh — детермінований рівень 0: схеми, існування
  //    глобів owns, непересічність смуг, свіжість acceptance_basis, цикли blocked_by.
  const v = opts.validate();
  if (!v.ok) {
    return stop(`реєстр невалідний — тік НЕ починається:\n${v.output}`);
  }

  const notes: string[] = [];
  if (
    opts.itemCount !== undefined &&
    opts.previousItemCount !== undefined &&
    opts.itemCount !== opts.previousItemCount
  ) {
    notes.push(
      `кількість елементів змінилась із ${opts.previousItemCount} на ${opts.itemCount} ` +
        `від попереднього тіку — звірити навмисність`,
    );
  }

  return { ok: true, started: true, stop_reason: null, notes };
}

/** Обгортка над справжнім validate-items.sh. */
export function runValidator(factoryRoot: string, engineDir?: string): ValidateResult {
  const args = ["bash", `${factoryRoot}/scripts/engine/validate-items.sh`];
  if (engineDir) args.push(engineDir);
  const r = run(factoryRoot, args, 120_000);
  return { ok: r.ok, output: (r.stdout + r.stderr).trim() };
}

/** Живі процеси, які конкурують за ексклюзивні ресурси (§4 фаза 0). */
export function busyProcesses(): string[] {
  const r = run(".", ["pgrep", "-fl", "xcodebuild|gradle|supabase"]);
  if (!r.ok) return [];
  return r.stdout.split("\n").map((s) => s.trim()).filter(Boolean);
}
