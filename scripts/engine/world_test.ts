// Реальна звірка зі світом. Git-половина пінується на СПРАВЖНІХ репозиторіях —
// мок git'а довів би лише те, що мок працює.
// gh-половина лишається за інтерфейсом World (чисті тести в reconcile_test.ts):
// вона потребує мережі й автентифікації, яких у гейта немає.
import { assertEquals } from "jsr:@std/assert@1";
import { gitBranchExists, gitBranchMerged } from "./lib/world.ts";

function sh(cwd: string, cmd: string[]): string {
  const r = new Deno.Command(cmd[0], {
    args: cmd.slice(1),
    cwd,
    stdout: "piped",
    stderr: "piped",
  }).outputSync();
  if (!r.success) {
    throw new Error(`${cmd.join(" ")}: ${new TextDecoder().decode(r.stderr)}`);
  }
  return new TextDecoder().decode(r.stdout);
}

/** Справжній git-репозиторій із main і однією feature-гілкою. */
function repoWithBranch(): { root: string; branch: string } {
  const root = Deno.makeTempDirSync({ prefix: "engine-world-" });
  sh(root, ["git", "init", "-q", "-b", "main"]);
  sh(root, ["git", "config", "user.email", "engine@strw.local"]);
  sh(root, ["git", "config", "user.name", "engine"]);
  Deno.writeTextFileSync(`${root}/README.md`, "base\n");
  sh(root, ["git", "add", "-A"]);
  sh(root, ["git", "commit", "-qm", "base"]);
  const branch = "cycle/m2-x";
  sh(root, ["git", "checkout", "-qb", branch]);
  Deno.writeTextFileSync(`${root}/feature.txt`, "work\n");
  sh(root, ["git", "add", "-A"]);
  sh(root, ["git", "commit", "-qm", "work"]);
  sh(root, ["git", "checkout", "-q", "main"]);
  return { root, branch };
}

Deno.test("гілка існує → branchExists true", () => {
  const { root, branch } = repoWithBranch();
  assertEquals(gitBranchExists(root, branch), true);
});

Deno.test("гілки немає → branchExists false (§4.2 рядок 5)", () => {
  const { root } = repoWithBranch();
  assertEquals(gitBranchExists(root, "cycle/не-існує"), false);
});

Deno.test("незмерджена гілка → branchMerged false", () => {
  const { root, branch } = repoWithBranch();
  assertEquals(gitBranchMerged(root, branch, "main"), false);
});

Deno.test("змерджена гілка → branchMerged true (§4.2 рядок 2)", () => {
  const { root, branch } = repoWithBranch();
  sh(root, ["git", "merge", "-q", "--no-ff", "-m", "merge", branch]);
  assertEquals(gitBranchMerged(root, branch, "main"), true);
});

Deno.test("гілка, видалена ПІСЛЯ мержу, все одно рахується змердженою", () => {
  // Реальний шлях: `gh pr merge --delete-branch`. Наївний `git branch --merged main | grep`
  // тут дає порожньо, і елемент поїхав би на повторну спробу вже змердженої роботи.
  const { root, branch } = repoWithBranch();
  const sha = sh(root, ["git", "rev-parse", branch]).trim();
  sh(root, ["git", "merge", "-q", "--no-ff", "-m", "merge", branch]);
  sh(root, ["git", "branch", "-qD", branch]);
  assertEquals(gitBranchExists(root, branch), false);
  assertEquals(gitBranchMerged(root, branch, "main", sha), true);
});

Deno.test("гілка з префіксом імені іншої не дає хибного збігу", () => {
  // `git branch --merged main | grep cycle/m2-x` збігся б і на `cycle/m2-x-fix`.
  const { root } = repoWithBranch();
  sh(root, ["git", "checkout", "-qb", "cycle/m2-x-fix"]);
  Deno.writeTextFileSync(`${root}/fix.txt`, "fix\n");
  sh(root, ["git", "add", "-A"]);
  sh(root, ["git", "commit", "-qm", "fix"]);
  sh(root, ["git", "checkout", "-q", "main"]);
  sh(root, ["git", "merge", "-q", "--no-ff", "-m", "merge fix", "cycle/m2-x-fix"]);
  assertEquals(gitBranchMerged(root, "cycle/m2-x-fix", "main"), true);
  assertEquals(gitBranchMerged(root, "cycle/m2-x", "main"), false);
});

Deno.test("неіснуючий базовий рефспек — помилка, а не тихе false", () => {
  const { root, branch } = repoWithBranch();
  let threw = false;
  try {
    gitBranchMerged(root, branch, "release/немає");
  } catch {
    threw = true;
  }
  assertEquals(threw, true);
});
