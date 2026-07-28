// Реконсиляція перед будь-яким retry — спека v2 §4.2.
//
// v1 на протухлу лізу робила `→ ready, attempts += 1`, НІЧОГО не перевіряючи.
// v2 заявляє at-least-once з примусовою реконсиляцією: робота може бути спробувана
// двічі, але друга спроба ЗОБОВ'ЯЗАНА виявити першу, перш ніж щось робити (§3.2).

export interface PrView {
  state: "MERGED" | "OPEN" | "CLOSED";
  mergeCommit: string | null;
}

/** Звірка зі світом. Чисті функції — щоб таблиця §4.2 пінилась без мережі. */
export interface World {
  prView(repo: string, pr: number): PrView | null;
  branchMerged(repo: string, branch: string, base?: string): boolean;
  branchExists(repo: string, branch: string): boolean;
  ciStatus(repo: string, pr: number): "green" | "red" | "pending";
}

export interface ReconcileInput {
  id: string;
  repo: string;
  branch?: string;
  state: string;
  attempts: number;
  pr?: number | null;
}

export interface Verdict {
  state: string;
  attempts: number;
  merge_commit: string | null;
  /** Чи можна планувати елемент у фазі 1 цього тіку. */
  schedulable: boolean;
  /** Потрібне око людини: світ невідомий або відповідь неповна. */
  needs_attention: boolean;
  reason: string;
}

/** Термінальні стани — реконсиляція їх не відкочує. */
const TERMINAL = new Set(["done", "parked"]);

export function reconcile(item: ReconcileInput, world: World): Verdict {
  const base = { merge_commit: null as string | null, needs_attention: false };

  if (TERMINAL.has(item.state)) {
    return {
      ...base,
      state: item.state,
      attempts: item.attempts,
      schedulable: false,
      reason: `стан ${item.state} термінальний — реконсиляція не чіпає`,
    };
  }

  const branch = item.branch ?? "";

  // ── Рядок 1: gh pr view <pr> --json state,mergeCommit → MERGED ────────────────
  let pr: PrView | null = null;
  if (item.pr != null) {
    try {
      pr = world.prView(item.repo, item.pr);
    } catch (e) {
      // Світ НЕ відомий. Повернути `ready` тут означало б переробити, можливо, вже
      // змерджену роботу — той самий дубль, який реконсиляція має ловити.
      return {
        ...base,
        state: item.state,
        attempts: item.attempts,
        schedulable: false,
        needs_attention: true,
        reason: `світ недоступний (${(e as Error).message}) — стан лишено, retry заборонено`,
      };
    }
  }

  if (pr?.state === "MERGED") {
    return {
      ...base,
      state: "done",
      attempts: item.attempts,
      merge_commit: pr.mergeCommit,
      needs_attention: pr.mergeCommit === null,
      schedulable: false,
      reason: pr.mergeCommit === null
        ? `PR #${item.pr} MERGED, але gh не віддав mergeCommit — факт мержу зафіксовано, SHA потребує ока`
        : `PR #${item.pr} MERGED (${pr.mergeCommit}) — робота вже у проді, attempts не росте`,
    };
  }

  // ── Рядок 2: git branch --merged main | grep <branch> ─────────────────────────
  // Йде ПІСЛЯ перевірки PR, але ПЕРЕД усіма гілками з retry: merge міг піти іншим PR
  // або руками, і закритий PR тоді не означає «роботи немає».
  if (branch !== "" && world.branchMerged(item.repo, branch, "main")) {
    return {
      ...base,
      state: "done",
      attempts: item.attempts,
      schedulable: false,
      reason: `гілка ${branch} вже в main — робота у проді, attempts не росте`,
    };
  }

  // ── Рядки 3–4: PR відкритий ───────────────────────────────────────────────────
  if (pr?.state === "OPEN" && item.pr != null) {
    const ci = world.ciStatus(item.repo, item.pr);
    if (ci === "green") {
      return {
        ...base,
        state: "merge-pending",
        attempts: item.attempts,
        schedulable: false,
        reason: `PR #${item.pr} відкритий, CI зелений — ланцюжок закінчено, merge за CEO`,
      };
    }
    if (ci === "red") {
      return {
        ...base,
        state: "ready",
        attempts: item.attempts + 1,
        schedulable: true,
        reason: `PR #${item.pr} відкритий, CI червоний — треба нова спроба`,
      };
    }
    // CI ще біжить. Поза дослівною таблицею, але `ready` тут дав би другого maker'а
    // на живий PR — рівно те подвоєння, проти якого написано §3.2.
    return {
      ...base,
      state: "gated",
      attempts: item.attempts,
      schedulable: false,
      needs_attention: false,
      reason: `PR #${item.pr} відкритий, CI ще біжить — чекаємо, спроба не витрачається`,
    };
  }

  // ── Рядок 5: гілки немає (і все інше, де роботи в світі не знайдено) ──────────
  const exists = branch !== "" && world.branchExists(item.repo, branch);
  return {
    ...base,
    state: "ready",
    attempts: item.attempts + 1,
    schedulable: true,
    reason: exists
      ? `гілка ${branch} є, але PR не відкритий — робота почалась і не дійшла до PR`
      : `гілки ${branch || "(не задано)"} немає — робота не залишила слідів`,
  };
}
