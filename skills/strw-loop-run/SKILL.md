---
name: strw-loop-run
version: 0.6.1
description: Execute an STRW factory loop (L1–L8) by its passport — read state, budget check, maker phase, checker phase, write state, auto-advance to the next non-gate stage, escalate or archive. Use when the user asks to "запусти петлю", "run loop", "запусти discovery/validation/build/growth/portfolio/retro/design/регресію", "виконай L1/L2/L3/L4/L5/L6/L7/L8", "продовж петлю для продукту", or when a scheduled task fires a loop run. Also the headless entry point for all scheduled STRW loops.
---

# STRW Loop Run

Виконати одну петлю фабрики строго за її паспортом. Це ЄДИНИЙ вхід для запуску петель — і ручний, і headless (scheduled).

## Prerequisites
- Знайти `strw-state/` (локальний клон або через GitHub-конектор; шлях — у company-context, дефолт: репо `strw-state`). Не знайдено → зупинись, повідом користувача.
- Паспорт петлі: `${CLAUDE_PLUGIN_ROOT}/loops/<loop-id>.md`. Немає паспорта → петля не запускається.

## Workflow

### Step 1 — Resolve loop
Визнач петлю з запиту (L1-discovery … L8-regression). Неоднозначно → запитай. Прочитай паспорт повністю.

### Step 2 — Read state (обов'язково ПЕРЕД роботою)
`company-context.md` + `portfolio.md` + для продуктових петель `products/<id>/state.md` (включно з Tried & failed). Петля продовжує роботу, не починає з нуля.

### Step 3 — Budget check
Звір `budget.md`: ліміт запусків/тиждень цієї петлі; стеля зовнішніх витрат. Стеля запусків вичерпана ПЛАНОВИМ запуском (планувальник спрацював частіше за стелю) → **тихий no-op**: один рядок у loops-log, БЕЗ inbox — алерт тут був би шумом, inbox лише для judgment. Перевитрат УСЕРЕДИНІ заходу (цикли/витрати понад стелю під час роботи) → STOP + `budget-alert` у triage-inbox.

### Step 3a — Тулчейн-фільтр черги (П2.1; 0.6.0)
Перед вибором елемента петля дивиться, **що вміє цей контур**, і бере лише те, що тут здійсненне:
1. Виміряти інструменти прямо, не з памʼяті: `command -v xcodebuild swift xcrun gradle deno gh` (кожен окремо, результат — у trace).
2. Прочитати `strw-state/engine/lanes.yaml`: у кожної смуги є `resources:`; елемент здійсненний у контурі, якщо КОЖЕН ресурс його смуги доступний (`xcodebuild`/`simulator`/`derived-data` → лише Mac з Xcode; `gradle-cache` → є `gradle` або `./gradlew` + JDK; `supabase-db` → є `supabase` або живий стек; `[]` → будь-де).
3. Черга `ready` (`engine/items/*.yaml`, без `blocked_by`) фільтрується за п.2. **Спочатку** — елементи смуг, здійсненних тут; `ios-ui` у контурі без Xcode не береться і не рахується «немає роботи».
4. Результат у рядку журналу — трьома різними словами, які не склеюються:
   - «**немає роботи**» — черга `ready` порожня взагалі;
   - «**немає інструмента**» — `ready` є, але жоден елемент не здійсненний тут; рядок називає, ЯКОГО ресурсу бракує і скільки елементів чекають на нього (напр. «14 ios-ui чекають xcodebuild»);
   - «**взято**» — обраний елемент, його смуга, і що саме з ресурсів підтверджено.

### Step 4 — Maker phase
**План ДО коду — для L3 і елемента `size: M|L`.** Першим, що maker повертає, є поле `plan` у YAML елемента: `files` (що чіпає), `order` (у якому порядку), `risks` (або `risks_none_because:` рядком), `proof` (чим доведе). Чекер рецензує ПЛАН окремим дешевим раундом — модель чекера з `strw-state/engine/lanes.yaml`, **без коду** — і лише після його вердикту maker робить перший коміт. Схему поля тримає `scripts/engine/validate-items.sh` (покручена форма → ERROR; відсутній `plan` при `size: M|L` і `state: ready` → WARN, бо чергу це не блокує — старт без плану забороняє тут раннер і цей крок, а не валідатор). Куплено виміром аудиту 03.09 (F2): 30 із 60 PR «великі» за критерієм L3 6a, раунди чекера 2–6, до 11 — рев'ю читало диф, а не рішення.

Виклич maker-агента з паспорта (Task tool, subagent із `agents/`). Передай йому: scope, релевантні файли state, контракт вихідного артефакту (references/artifact-contracts.md). Fan-out — за references/subagent-delegation.md (≤6). Вимагай разом з артефактом **trace**: файли state прочитані · перевірки виконані · тули/скіли викликані · ітерації. Без trace артефакт не приймається.

### Step 5 — Checker phase (двоетапно)
1. **Детермінований:** `bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-artifact.sh <type> <file>` — обов'язкові секції контракту. FAIL → назад maker'у, LLM-checker НЕ викликається, в inbox НЕ пишеться.
2. **LLM-checker** з паспорта (ЗАВЖДИ інший промпт; для критичних артефактів — інша модель, ніж maker, budget-policy). Передай йому артефакт + trace maker'а + рубрику (references/evals/rubrics.md). Перевіряє output І trajectory. Вердикт FAIL → поверни maker'у (max 2 ітерації), далі — розбіжність фіксується в артефакті, ескалація.

### Step 6 — Write state (без цього запуск не відбувся)
- Оновити `products/<id>/state.md` (Done/Next/Tried & failed) та/або `portfolio.md`.
- Записати факт у `budget.md`.
- Додати рядок у `loops-log/` (схема — state-protocol.md): дата · петля · продукт · тривалість · ітерації maker↔checker · first-pass так/ні · вердикти · ескалації · моделі maker/checker · `plan_drift:<число>` для L3-циклів із `plan` — файлів у дифі поза `plan.files`; плану не було → `plan_drift:н/д`, ніколи не нуль.

Записом у git завершує **контур M** — `strw-run` після зелених гейтів або сама сесія на Mac, пошляхово, повідомленням `loop(<id>): <підсумок одним рядком>`. **`commit-on-stop.sh` коміта НЕ робить:** він лише не дає сесії завершитись мовчки з незаписаним станом і повертає роботу тобі. Причина — коміт має описувати те, що агент справді зробив і перевірив, а хук цього не читав. У контурі C ці ж дані йдуть у `_outbox/` одним файлом — межу тримає `contour-guard.sh`, тож помилитись контуром петля не може.

### Step 7 — Auto-advance (не чекати на «запусти», версія 0.3.0, 2026-07-20)
Якщо ця петля щойно відкрила прохід до наступної НЕ-gate стадії — напр. L1 додав картку в черзі і WIP (`portfolio.md`, ліміт 3) та секвенування (правило проти паралельної валідації карток на одній портфельній тезі, як зафіксовано в triage-inbox 2026-07-17) це дозволяють — одразу виклич `strw-loop-run` для наступної петлі (тут: L2-validation) В МЕЖАХ ЦЬОГО Ж headless-заходу. Auto-advance проходить той самий Step 3 для ЦІЛЬОВОЇ петлі: її стеля вичерпана або ПАУЗА (budget.md § Ліміти) → тихий no-op, не запуск і не алерт. Не чекай, доки Andrii скаже «запусти/продовж» під час triage — це і є зміна, що прибирає головний bottleneck (STRW_Autonomy_Plan_v1, 2026-07-20).
- До Andrii йде ТІЛЬКИ: gate-рішення (G1–G4), дії з company-context.md принцип 5, і genuine `question` (конфлікт, брак даних, портфельна колізія; вичерпаний WIP чи конфлікт секвенування — теж question з поясненням «чому не паралельно», не мовчазний блок і не мовчазний запуск). L3 після G2 і L4 щотижня — auto-advance за визначенням.

### Step 8 — Escalate or archive
- Знахідки/gate-запити/питання → append-top у `triage-inbox.md` за схемою inbox. Для gate-request і будь-якого запису, що є продовженням старішого OPEN-запису по тому ж продукту, — додай 2–4 рядки **«що змінилось з моменту останнього запису»** (порівняй з попереднім OPEN/DONE записом по цьому продукту), а не лише посилання на артефакт. Мета — щоб Andrii не відновлював контекст з нуля (comprehension debt, STRW_Autonomy_Plan_v1 §3.5).
- Порожній результат → один рядок логу, тихе завершення (без шуму в inbox).

## Rules
- Строго за паспортом: scope, stop-умова, бюджет. Робота поза scope = порушення.
- Незворотні дії всередині петлі заборонені — лише запит у inbox.
- Headless-режим: жодних питань користувачу; неоднозначність → ескалація `question` в inbox і graceful stop.
- References: `${CLAUDE_PLUGIN_ROOT}/references/loop-passport.md`, `state-protocol.md`, `budget-policy.md`, `data-policy.md`.
- Наприкінці, якщо були корекції користувача — `references/self-improvement.md`.
