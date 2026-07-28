// tick.workflow.js — диспетчер одного тіку. Спека v2 §4, фази 0 → 1 → 2 → 3.
//
// ─────────────────────────────────────────────────────────────────────────────
// МЕЖА ВІДПОВІДАЛЬНОСТІ, яку треба знати, перш ніж це читати.
//
// Workflow-скрипт виконується в пісочниці харнеса: НЕМАЄ доступу ні до файлової
// системи, ні до Node/Deno API, ні до git. Він уміє одне — оркеструвати агентів.
// Тому вся детермінована механіка (лізи, CAS, реконсиляція, git, запис стану)
// живе в `engine.ts` — справжньому CLI, який агенти викликають через Bash.
//
// Наслідок, важливий для доказовості: інваріанти рушія перевіряються тестами над
// `engine.ts` (120 тестів + мутаційні проби), а НЕ проходом цього файлу. Цей файл
// відповідає лише за порядок фаз, за те, що фаза 2 — це `pipeline()`, і за те, що
// тік не починається, коли фаза 0 сказала СТОП.
// ─────────────────────────────────────────────────────────────────────────────

export const meta = {
  name: "engine-tick",
  description: "Один тік диспетчера STRW: preflight → plan → execute → settle (N=1)",
  whenToUse:
    "Коли треба провести один цикл рушія по реєстру engine/items. Не запускати паралельно з іншим тіком: git-мьютекс у strw-state тримається зовні.",
  phases: [
    { title: "0 Preflight", detail: "strw-state записуваний і запушений · реєстр валідний · протухлі лізи → реконсиляція" },
    { title: "1 Plan", detail: "топосорт · доказ непересічності owns+resources · карантин · зріз до N" },
    { title: "2 Execute", detail: "ланцюжок A→E на елемент, pipeline() без бар'єра" },
    { title: "3 Settle", detail: "item-файли (CAS) · state.md · cycles/*.jsonl · пошляховий коміт" },
  ],
};

// ── Конфігурація тіку ───────────────────────────────────────────────────────────
// N=1 ДО КІНЦЯ ФАЗИ 1 (§13). Підняти можна лише після failure injection 3/3.
const N = 1;
const MAX_FANOUT = 2;
const PANEL = 0; // панель із 3 refuter'ів — §14, свідомо відкладено
const CORES = 8; // hw.ncpu
const CEILING = Math.min(16, CORES - 2); // = 6

const cfg = args ?? {};
const STRW = cfg.strw ?? "/Users/Andrew/Developer/STRW";
const STATE = `${STRW}/strw-state`;
const FACTORY = `${STRW}/strw-factory`;
const ENGINE_DIR = `${STATE}/engine`;
const PRODUCT = cfg.product ?? "pact-001";
const TICK = cfg.tick ?? 1;
const CYCLE_ID = cfg.cycle_id ?? `tick-${TICK}`;
const REPOS = cfg.repos ?? {
  "pact-ios": `${STRW}/pact-ios`,
  "pact-backend": `${STRW}/pact-backend`,
};
const REPOS_JSON = JSON.stringify(REPOS);
const ENGINE = `deno run --allow-all ${FACTORY}/scripts/engine/engine.ts`;

// Інваріант бюджету слотів (§4.4) — перевіряється ДО будь-якої роботи.
const demand = N * (1 + MAX_FANOUT) + PANEL;
if (demand > CEILING) {
  throw new Error(
    `бюджет слотів: N(${N}) × (1 + ${MAX_FANOUT}) + panel(${PANEL}) = ${demand} > стеля ${CEILING} (§4.4)`,
  );
}

const SCHEMA_PREFLIGHT = {
  type: "object",
  required: ["started", "stop_reason"],
  properties: {
    started: { type: "boolean" },
    stop_reason: { type: ["string", "null"] },
    reconciled: { type: "array", items: { type: "string" } },
  },
};

const SCHEMA_PLAN = {
  type: "object",
  required: ["selected"],
  properties: {
    selected: {
      type: "array",
      items: {
        type: "object",
        required: ["id", "repo", "branch"],
        properties: {
          id: { type: "string" },
          repo: { type: "string" },
          branch: { type: "string" },
          lane: { type: "string" },
        },
      },
    },
    skipped: { type: "array", items: { type: "object" } },
  },
};

const SCHEMA_CHAIN = {
  type: "object",
  required: ["id", "final_state", "evidence"],
  properties: {
    id: { type: "string" },
    // Ланцюжок ЗАКІНЧУЄТЬСЯ на merge-pending. `done` тут — помилка: merge робить CEO.
    final_state: { enum: ["merge-pending", "ready", "gated", "blocked", "error"] },
    pr: { type: ["number", "null"] },
    evidence: {
      type: "object",
      properties: {
        run_id: { type: "string" },
        commit_sha: { type: ["string", "null"] },
        toolchain: { type: ["string", "null"] },
        exit_code: { type: ["number", "null"] },
      },
    },
    gate: { type: "object" },
    notes: { type: "string" },
  },
};

// ── Фаза 0 Preflight ────────────────────────────────────────────────────────────
phase("0 Preflight");

const pre = await agent(
  `Фаза 0 Preflight рушія STRW. Виконай РІВНО це, нічого понад.

1. Запусти: ${ENGINE} preflight --state ${STATE} --factory ${FACTORY}
   Код виходу 3 означає «тік НЕ починається». Це НЕ помилка інструмента — це
   спрацював жорсткий інваріант §3.1. У цьому разі поверни started=false і
   stop_reason з виводу, і БІЛЬШЕ НІЧОГО НЕ РОБИ.

2. Якщо крок 1 дав exit 0 — реконсиляція протухлих ліз і зависань:
   ${ENGINE} reconcile --engine ${ENGINE_DIR} --repos '${REPOS_JSON}' --apply
   У reconciled поверни id елементів, чий стан змінився.

3. Повідом про живі процеси, які тримають ексклюзивні ресурси:
   pgrep -fl 'xcodebuild|gradle|supabase' (порожньо — це нормально).

ЗАБОРОНЕНО: правити item-файли руками, комітити будь-що, торкатись коду продукту.`,
  { label: "preflight", schema: SCHEMA_PREFLIGHT },
);

if (!pre || pre.started === false) {
  const why = pre?.stop_reason ?? "агент фази 0 не повернув результату";
  log(`ТІК НЕ ПОЧАВСЯ: ${why}`);
  // Саме «не почався», а не «завершився чисто»: нічого не заклеймлено,
  // нічого не записано, циклу в телеметрії немає.
  return { started: false, stop_reason: why, tick: TICK, cycle_id: CYCLE_ID };
}

log(`фаза 0 зелена · реконсильовано: ${(pre.reconciled ?? []).length}`);

// ── Фаза 1 Plan ─────────────────────────────────────────────────────────────────
phase("1 Plan");

const plan = await agent(
  `Фаза 1 Plan рушія STRW.

Запусти РІВНО це і поверни його вивід без інтерпретації:
  ${ENGINE} plan --engine ${ENGINE_DIR} --repos '${REPOS_JSON}' --tick ${TICK} --n ${N} --fanout ${MAX_FANOUT} --panel ${PANEL} --cores ${CORES}

Скрипт САМ робить топологічне сортування, доказ непересічності owns+resources,
карантин і зріз до N. Твоє завдання — виконати його й віддати JSON.
Якщо він упав із PlanError — поверни selected: [] і поклади текст помилки в skipped.
НЕ вигадуй елементів, яких він не вибрав, і НЕ перевпорядковуй selected.`,
  { label: "plan", schema: SCHEMA_PLAN },
);

const selected = (plan?.selected ?? []).slice(0, N);
if (selected.length === 0) {
  log("фаза 1: до роботи нічого не відібрано");
  return { started: true, selected: [], skipped: plan?.skipped ?? [], tick: TICK, cycle_id: CYCLE_ID };
}
log(`фаза 1: відібрано ${selected.length} (N=${N}) · ${selected.map((s) => s.id).join(", ")}`);

// ── Фаза 2 Execute ──────────────────────────────────────────────────────────────
// pipeline(), НЕ parallel(): бар'єр між стадіями змусив би готовий елемент чекати
// найповільнішого, а час очікування йде в поріг лізи → протух → реклейм (§4.4).
phase("2 Execute");

const executed = await pipeline(
  selected,
  (item) =>
    agent(
      `Ланцюжок елемента ${item.id} (спека v2 §4.3). Смуга ${item.lane}, репо ${item.repo}, гілка ${item.branch}.

ПЕРЕД БУДЬ-ЧИМ:
  RUN_ID="${CYCLE_ID}-${item.id}"
  ${ENGINE} claim --repo ${REPOS[item.repo] ?? "<repo>"} --item ${item.id} --run "$RUN_ID" --tick ${TICK}
Запам'ятай epoch із виводу. Кожні ≤5 хв, поки працюєш:
  ${ENGINE} heartbeat --repo ${REPOS[item.repo] ?? "<repo>"} --item ${item.id} --run "$RUN_ID" --epoch <epoch>
Heartbeat — ЗА ЧАСОМ, не за переходом стадії. Стадія A регулярно триває довше за поріг.

Ланцюжок:
  A. maker — власний worktree, власний DerivedData, ексклюзивні resources смуги
  B. детермінований гейт БЕЗ моделі: тести · lint · dep-audit · secret-scan ·
     git diff --name-only ⊆ owns ∪ also_touches ∪ shared · мутаційна проба
     (тільки у власному одноразовому worktree, тільки compile-valid мутанти;
      unpinned БЛОКУЄ merge-pending)
  C. checker — ІНША модель, проти acceptance + trace + evidence
  D. rebase на поточний main → ПОВТОРНИЙ прогін гейта B на зребейзеному дереві
  E. state: merge-pending — ЛАНЦЮЖОК ЗАКІНЧУЄТЬСЯ ТУТ

ТВЕРДІ ЗАБОРОНИ:
  · merge НЕ робиш — його робить CEO. final_state='done' заборонено.
  · перед КОЖНИМ записом у item-файл — CAS по (run_id, epoch); розбіжність =
    негайний abort без жодної дії з ефектом.
  · намір перед ефектом: state=merging + pr + head_sha пишуться ДО дії.
  · запис поза owns ескалюється З ПЕРШОГО РАЗУ.
  · незворотні дії — в inbox, не в роботу.

Поверни JSON за схемою. У evidence — реальні run_id, commit_sha, toolchain, exit_code.`,
      { label: `chain:${item.id}`, phase: "2 Execute", schema: SCHEMA_CHAIN },
    ),
);

const results = executed.filter(Boolean);
log(`фаза 2: завершено ланцюжків ${results.length}/${selected.length}`);

// ── Фаза 3 Settle ───────────────────────────────────────────────────────────────
phase("3 Settle");

const settle = await agent(
  `Фаза 3 Settle рушія STRW.

Результати ланцюжків:
${JSON.stringify(results, null, 2)}

1. Звірка перед записом у strw-state (окремими командами, як вимагає протокол):
     git -C ${STATE} rev-parse HEAD
     git -C ${STATE} rev-parse origin/main
   Розбіжність → git -C ${STATE} pull --ff-only і повтори звірку.
   Якщо ff-only не проходить — СТОП, нічого не пиши, поверни це у відповіді.

2. Запиши стан і дзеркало (скрипт сам оновлює машинний блок у state.md
   між маркерами ENGINE:ITEMS і дописує рядок у engine/cycles/<тиждень>.jsonl):
     ${ENGINE} settle --engine ${ENGINE_DIR} --state ${STATE} --product ${PRODUCT} --cycle ${CYCLE_ID} --tick ${TICK} --n ${N} --selected ${selected.map((s) => s.id).join(",")}

3. Пошляховий коміт — ТІЛЬКИ ці шляхи, нічого понад:
     git -C ${STATE} add engine/items engine/cycles products/${PRODUCT}/state.md
     git -C ${STATE} commit -m "engine(${PRODUCT}): тік ${TICK} — <підсумок>"
   Ніякого git add -A. У strw-state паралельно може писати build-сесія.

Поверни, що саме записано й закомічено.`,
  { label: "settle", schema: {
    type: "object",
    required: ["written"],
    properties: {
      written: { type: "boolean" },
      commit: { type: ["string", "null"] },
      blocked_reason: { type: ["string", "null"] },
    },
  } },
);

return {
  started: true,
  tick: TICK,
  cycle_id: CYCLE_ID,
  n: N,
  ceiling: CEILING,
  selected: selected.map((s) => s.id),
  skipped: plan?.skipped ?? [],
  results,
  settled: settle,
};
