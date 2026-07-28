// sandbox.ts — справжня пісочниця для failure injection.
//
// Що тут СПРАВЖНЄ: git-репозиторії, файлова система, процеси, сигнали, лізи,
// item-файли, реконсиляція. Що СИМУЛЬОВАНО: відповідь GitHub API — через
// підставний `gh` у PATH, бо офлайн справжнього PR не буває. Git-половина
// звірки (§4.2 рядок 2) при цьому лишається цілком реальною, і сценарій (а)
// прогоняється ДВІЧІ: з підставним gh і зовсім без PR, на чистому git.

export interface Sandbox {
  base: string;
  repo: string;
  engineDir: string;
  itemPath: string;
  itemId: string;
  branch: string;
  binDir: string;
}

function sh(cwd: string, cmd: string[]): string {
  const r = new Deno.Command(cmd[0], { args: cmd.slice(1), cwd, stdout: "piped", stderr: "piped" })
    .outputSync();
  if (!r.success) throw new Error(`${cmd.join(" ")}\n${new TextDecoder().decode(r.stderr)}`);
  return new TextDecoder().decode(r.stdout);
}

const ITEM_YAML = (id: string, branch: string) =>
  `schema_version: 1
id: ${id}
product: pact-001
loop: L3-build
lane: ios-ui
state: ready
repo: pact-ios
branch: ${branch}
size: S
acceptance: |
  - тестовий елемент для failure injection
acceptance_basis:
  sources:
    - "m2-execution-plan.md#W0b"
  verified_against_decisions_log_at: 2026-07-28T19:05Z
lease: {run_id: null, epoch: 0, heartbeat: null}
evidence: {run_id: null, commit_sha: null, cwd: null, toolchain: null, exit_code: null, ci_run_url: null}
attempts: 0
# КОМЕНТАР-СВІДОК: мусить пережити всі записи ланцюжка.
`;

const LANES_YAML = `schema_version: 1
lanes:
  - id: ios-ui
    repo: pact-ios
    owns: ["App/**"]
    resources: [xcodebuild, simulator, derived-data]
shared:
  - "contract/**"
`;

/** Створює репо з main і незмердженою робочою гілкою. */
export function makeSandbox(name: string, prState?: "MERGED" | "OPEN"): Sandbox {
  const base = Deno.makeTempDirSync({ prefix: `fi-${name}-` });
  const repo = `${base}/pact-ios`;
  const engineDir = `${base}/engine`;
  const itemId = "pact-001.m2.fi";
  const branch = "cycle/m2-fi";

  Deno.mkdirSync(repo, { recursive: true });
  sh(repo, ["git", "init", "-q", "-b", "main"]);
  sh(repo, ["git", "config", "user.email", "engine@strw.local"]);
  sh(repo, ["git", "config", "user.name", "engine"]);
  Deno.mkdirSync(`${repo}/App`, { recursive: true });
  Deno.writeTextFileSync(`${repo}/App/base.swift`, "// base\n");
  sh(repo, ["git", "add", "-A"]);
  sh(repo, ["git", "commit", "-qm", "base"]);

  sh(repo, ["git", "checkout", "-qb", branch]);
  Deno.writeTextFileSync(`${repo}/App/feature.swift`, "// РОБОТА ЦИКЛУ\n");
  sh(repo, ["git", "add", "-A"]);
  sh(repo, ["git", "commit", "-qm", "робота циклу"]);
  sh(repo, ["git", "checkout", "-q", "main"]);

  Deno.mkdirSync(`${engineDir}/items`, { recursive: true });
  Deno.mkdirSync(`${engineDir}/cycles`, { recursive: true });
  Deno.writeTextFileSync(`${engineDir}/lanes.yaml`, LANES_YAML);
  Deno.writeTextFileSync(`${engineDir}/schema_version`, "1\n");
  const itemPath = `${engineDir}/items/${itemId}.yaml`;
  Deno.writeTextFileSync(itemPath, ITEM_YAML(itemId, branch));

  // Підставний `gh`: єдина симульована частина. Віддає рівно той JSON, що й
  // справжній `gh pr view --json state,mergeCommit` / `--json statusCheckRollup`.
  const binDir = `${base}/bin`;
  Deno.mkdirSync(binDir, { recursive: true });
  if (prState) {
    const mergeCommit = prState === "MERGED"
      ? `{"oid":"__MERGE_SHA__"}`
      : "null";
    Deno.writeTextFileSync(
      `${binDir}/gh`,
      `#!/bin/sh
# підставний gh для failure injection — тільки читання, жодних дій
case "$*" in
  *statusCheckRollup*) echo '{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}' ;;
  *state,mergeCommit*) echo '{"state":"${prState}","mergeCommit":${mergeCommit}}' ;;
  *) echo '{}' ;;
esac
`,
    );
    Deno.chmodSync(`${binDir}/gh`, 0o755);
  }

  return { base, repo, engineDir, itemPath, itemId, branch, binDir };
}

/** Підставляє реальний merge-SHA у відповідь фальшивого gh. */
export function pinMergeSha(sb: Sandbox): void {
  const sha = sh(sb.repo, ["git", "rev-parse", "HEAD"]).trim();
  const p = `${sb.binDir}/gh`;
  Deno.writeTextFileSync(p, Deno.readTextFileSync(p).replace("__MERGE_SHA__", sha));
  Deno.chmodSync(p, 0o755);
}

export { sh };
