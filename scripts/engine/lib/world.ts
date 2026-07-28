// Реальна звірка зі світом для §4.2. Усе, що тут є, — читання; жодної дії з ефектом.

import type { PrView, World } from "./reconcile.ts";

export interface RunResult {
  ok: boolean;
  stdout: string;
  stderr: string;
  code: number;
}

export function run(cwd: string, cmd: string[], timeoutMs = 60_000): RunResult {
  const proc = new Deno.Command(cmd[0], {
    args: cmd.slice(1),
    cwd,
    stdout: "piped",
    stderr: "piped",
    signal: AbortSignal.timeout(timeoutMs),
  });
  try {
    const r = proc.outputSync();
    const dec = new TextDecoder();
    return {
      ok: r.success,
      stdout: dec.decode(r.stdout),
      stderr: dec.decode(r.stderr),
      code: r.code,
    };
  } catch (e) {
    return { ok: false, stdout: "", stderr: String(e), code: -1 };
  }
}

export function gitBranchExists(repoRoot: string, branch: string): boolean {
  return run(repoRoot, ["git", "rev-parse", "--verify", "--quiet", `refs/heads/${branch}`]).ok;
}

/**
 * Чи є робота гілки вже в базі.
 *
 * Спека §4.2 пише `git branch --merged main | grep <branch>`, але дослівний grep
 * має два дефекти, які тут виправлені, бо кожен із них дає ДУБЛЬ роботи:
 *  1. `grep cycle/m2-x` збігається і з `cycle/m2-x-fix` — хибний «done»;
 *  2. після `gh pr merge --delete-branch` гілки немає в списку — хибний «ready»
 *     на вже змердженій роботі. Саме тому приймається `knownSha`.
 * Тому: точний збіг імені, плюс `merge-base --is-ancestor` для відомого SHA.
 */
export function gitBranchMerged(
  repoRoot: string,
  branch: string,
  base = "main",
  knownSha?: string,
): boolean {
  const baseOk = run(repoRoot, ["git", "rev-parse", "--verify", "--quiet", base]).ok;
  if (!baseOk) {
    throw new Error(`git: базового рефспеку '${base}' немає в ${repoRoot} — звірка неможлива`);
  }

  if (gitBranchExists(repoRoot, branch)) {
    const r = run(repoRoot, [
      "git",
      "branch",
      "--merged",
      base,
      "--format=%(refname:short)",
    ]);
    if (r.ok) {
      const names = r.stdout.split("\n").map((s) => s.trim()).filter(Boolean);
      if (names.includes(branch)) return true;
    }
  }

  if (knownSha) {
    return run(repoRoot, ["git", "merge-base", "--is-ancestor", knownSha, base]).ok;
  }
  return false;
}

function ghJson(repoRoot: string, args: string[]): unknown {
  const r = run(repoRoot, ["gh", ...args], 60_000);
  if (!r.ok) {
    // Кидаємо, а НЕ повертаємо null: «gh недоступний» ≠ «PR не існує».
    // reconcile() перетворює виняток на «стан лишено, retry заборонено».
    throw new Error(`gh ${args.join(" ")} → code ${r.code}: ${r.stderr.trim().slice(0, 200)}`);
  }
  return JSON.parse(r.stdout);
}

export function ghPrView(repoRoot: string, pr: number): PrView | null {
  const j = ghJson(repoRoot, [
    "pr",
    "view",
    String(pr),
    "--json",
    "state,mergeCommit",
  ]) as { state?: string; mergeCommit?: { oid?: string } | null };
  if (!j.state) return null;
  return {
    state: j.state as PrView["state"],
    mergeCommit: j.mergeCommit?.oid ?? null,
  };
}

export function ghCiStatus(repoRoot: string, pr: number): "green" | "red" | "pending" {
  const j = ghJson(repoRoot, [
    "pr",
    "view",
    String(pr),
    "--json",
    "statusCheckRollup",
  ]) as { statusCheckRollup?: Array<{ status?: string; conclusion?: string; state?: string }> };
  const checks = j.statusCheckRollup ?? [];
  if (checks.length === 0) return "pending";
  let anyPending = false;
  for (const c of checks) {
    const concl = (c.conclusion ?? c.state ?? "").toUpperCase();
    const status = (c.status ?? "").toUpperCase();
    if (status && status !== "COMPLETED") { anyPending = true; continue; }
    if (["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "ERROR"].includes(concl)) {
      return "red";
    }
    if (!["SUCCESS", "NEUTRAL", "SKIPPED"].includes(concl)) anyPending = true;
  }
  return anyPending ? "pending" : "green";
}

/** Світ, підключений до справжніх git і gh. repoRoot береться з мапи repo → шлях. */
export function realWorld(repoPaths: Record<string, string>, shaOf: (id: string) => string | undefined = () => undefined): World {
  const rootOf = (repo: string): string => {
    const p = repoPaths[repo];
    if (!p) throw new Error(`невідоме репо '${repo}' — немає в мапі шляхів`);
    return p;
  };
  return {
    prView: (repo, pr) => ghPrView(rootOf(repo), pr),
    branchMerged: (repo, branch, base) => gitBranchMerged(rootOf(repo), branch, base ?? "main", shaOf(branch)),
    branchExists: (repo, branch) => gitBranchExists(rootOf(repo), branch),
    ciStatus: (repo, pr) => ghCiStatus(rootOf(repo), pr),
  };
}
