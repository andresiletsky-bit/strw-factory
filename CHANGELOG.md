# Changelog

## [Unreleased]

## [0.3.0] — 2026-08-07
Архітектура v3 — примус переїжджає з прози в код, автономність із хмарного розкладу в локальний раннер. Джерела: Thariq (Anthropic) «The new rules of context engineering for Claude 5 models» 24.07.2026 та `anthropics/cwc-long-running-agents`.

### Added
- **7 hooks у `~/Developer/STRW/.claude/hooks/`** (поза плагіном, спільні для всіх репо): `contour-guard` (межа контурів), `verify-gate` (default-FAIL контракт), `budget-gate` (стеля субагентів + maker≠checker), `track-read`, `commit-on-stop`, `kill-switch`, `steer`.
- **`bin/strw-run.sh`** — цикл maker → evaluator → гейти. Оцінювач окремим процесом зі свіжим контекстом і без Write/Edit. Стеля 2 ітерацій у коді. Preflight ловить залишкові `.git/*.lock` і розбіжність кешу плагіна з репо.
- **`gates.json`** — контракт default-FAIL на продукт. Вісім гейтів, серед них `human_smoke`.

### Fixed після рев'ю в Claude Code (07.08, той самий день)
- **`commit-on-stop.sh` переписано: хук відмовляє, а не робить.** Перша версія сама комітила стан і мала три виміряні дефекти — другий коміт у сесії всупереч правилу «один коміт на захід»; `git add -- products` тягнув `products/.DS_Store` попри коментар, що ні; дописувала в `loops-log` рядок, який не є рядком таблиці. Спільна причина: коміт від хука описує роботу, якої хук не читав. Тепер хук бачить незаписаний стан → `exit 2` і повертає роботу агенту. Захист від петлі через `stop_hook_active`.
- **`company-context.md`:** посилання на `data-policy.md` отримало шлях; твердження «принципи 6/7/10 підперті хуками» виправлено на чесне — принцип 6 підпертий лише частково, бо модель у payload хука не приходить; повернуто блок Інфраструктури, бо `git remote` у контурі C тепер заблокований і адреси стали недоступні поглядом.
- **`strw-loop-run` і `strw-gate-review` називали `commit-on-stop.sh` виконавцем коміта** — після переписування хука це стало неправдою в той самий день. Обидва скіли тепер кажуть прямо: коміт робить `strw-run` або сесія на Mac, а хук лише не дає завершитись мовчки. Це той самий клас, що дав помилку 08:05: два канонічні документи фабрики суперечили один одному, і петля виконувала прочитаний останнім.
- **Стеля циклів посилалась по колу:** паспорт казав «число в `budget.md`», `budget.md` — «число живе в паспорті `L3-build.md`». Разом із тим загубилась умова скасування («повернути 1–2 після виходу pact-001 у TestFlight»), тобто тимчасова поправка 29.07 мовчки стала постійною. Джерелом призначено `budget.md` § Ліміти, умову повернено туди ж.
- **`marketplace.json`: `metadata.version` мав поїхати 1.0.1 → 0.3.0.** Це окрема лінія версій — маркетплейс ішов `1.0.0 → 1.0.1`, поки плагін ішов `0.1.0 → 0.2.2`; вони ніколи не збігались. Зрівняти означало відкотити маркетплейс назад і ризикнути тим, що `marketplace update` стане no-op — з симптомом «already at the latest version», який приписано лікувати бампом плагіна, тобто не тим полем. Поставлено 1.0.2 і додано коментар у сам файл.

### Відновлено після рев'ю — поведінка, що зникла разом із наративом
- **Процедура зняття залишеного лока** (`references/state-protocol.md`): звірити розмір, `mtime` і `pgrep -fl git`; ніколи не видаляти лок живого процесу. `grep pgrep` по всьому плагіну після скорочення давав нуль збігів, хоча процедурою знімали чотири локи 04.08.
- **Другий кінець черги `_outbox/`** (там же): контур C лише КЛАВ файли, обов'язок контуру M вливати їх і видаляти злите не був записаний ніде в плагіні. Ціна виміряна 07.08: три файли в черзі, найстаршому вісім днів, один устиг потрапити під версійний контроль невлитим. Додано також дедуп-перевірку перед вливанням і правило класти рядок у тиждень за датою заходу (захід 30.07 → `2026-W31.md`, не W32).

### Changed
- **`strw-loop-run` 0.3.0 → 0.4.0:** Step 6 більше не наказує `git commit`. Запис у git робить контур M. Знімає суперечність зі `state-protocol`, яка щодня давала помилку і залишковий лок.
- **`strw-gate-review`, `strw-product-init`:** та сама правка кроку коміту.
- **`references/state-protocol.md`:** 6111 → 8257 B. §4c згорнуто в одне правило контурів (правило тримає `contour-guard.sh`, наратив інцидентів лишився в `decisions-log.md`), але файл **виріс**, а не скоротився — повернуто дві поведінки, що зникли були разом із наративом. Попередня редакція цього рядка називала 7817 → 5057 B; жодне з чотирьох чисел не відповідало виміру.
- **`loops/L3-build.md`:** 10935 → 5721 B. Умови зупинки переїхали в `gates.json`; правила 7 і 11 стали гейтами `tests…secrets` і `human_smoke`. Усі 12 правил старої редакції звірено поштучно — кожне має спадкоємця.
- **`strw-state/company-context.md` 1.0.0 → 2.0.0:** прибрано чотири факти, що розійшлися з реальністю (каденс Discovery, стек Expo, WIP 3, перша ідея). Кожне число тепер має рівно одне джерело; додано таблицю контурів.

### Fixed
- **Дозволений список §4c був хибний.** `git status` і `git diff` названі безпечними для пісочниці, але вони освіжають індекс і беруть `index.lock`. Виміряно 07.08 10:28: один `git status` лишив лок у `strw-state`, `strw-factory` і `pact-ios` — в останньому під час живої Mac-сесії. Того ж дня знайдено лок і в `pact-backend`, де ганявся лише `git log`. Замість переліку «безпечних» підкоманд — одне правило: у контурі C кожна git-команда йде з `--no-optional-locks`, а запис і мережа заблоковані завжди. 13 поведінкових тестів.

### Removed
- Дублювання стель прогонів у паспортах петель — єдине джерело `budget.md`.

Впровадження STRW_Autonomy_Plan_v1 (2026-07-20, схвалено Andrii) — закриває головний розрив зі статті Loop Engineering (Osmani): реальний шар automations замість ручного «запусти».

### Added
- **Scheduled tasks (5, поза плагіном — Claude Code Remote triggers):** STRW L1 Discovery (Пн/Ср/Пт), STRW L3 Build Continue AM/PM (Пн–Пт, пріоритетні слоти), STRW Triage Digest AM/PM (Пн–Пт, push тільки якщо є що вирішити), STRW L4 Growth (Пн, dormant до першого прод-продукту), STRW L5+L6 Friday. Замінюють ручні headless-запуски.
- **`references/budget-policy.md`:** новий розділ «Пріоритет ресурсу при дефіциті квоти Claude» — L3 Build ніколи не стискається першим; порядок стиснення: L1 → Triage Digest → (L5/L6 без змін) → Build останнім.

### Changed
- **`strw-loop-run` 0.2.0 → 0.3.0:** новий Step 7 «Auto-advance» — петля сама викликає наступну не-gate петлю (напр. L1 → L2) в межах WIP/секвенування, без очікування команди Andrii; до людини йдуть тільки gate-рішення, незворотні дії, budget-alert/error і genuine question (реалізація принципу №5 company-context.md, який раніше не був закодований). Step 8 (Escalate) вимагає «що змінилось з минулого разу» для продовжень старих inbox-записів.
- **`strw-triage` 0.2.0 → 0.3.0:** inbox тепер тільки для того, що дійсно потребує Andrii — не-gate «запусти/продовж» більше не єдиний спосіб щось зрушити; запис такого типу в inbox тепер сам є сигналом регресії в петлі. Step 3 підсумовує «що змінилось» для продовжень.

## [0.2.0] — 2026-07-07
Впровадження 15 покращень за whitepaper «The New SDLC with Vibe Coding» (Google/Kaggle, 2026) — див. `improvements-new-sdlc-vibe-coding.md` у робочій папці.

### Added
- **Eval-шар (P0):** `references/evals/rubrics.md` — рубрики оцінки критичних артефактів (output + trajectory) + процедура регресії; `references/evals/golden/` — golden-набір (idea-card, validation-report, prd) із сіді-кейсами для калібрування checker'ів.
- **Детермінований рівень 0 (P1):** `scripts/validate-artifact.sh` — перевірка обов'язкових секцій артефактів скриптом ДО LLM-checker'а; канонічні секції зафіксовані в artifact-contracts.
- **Шаблони продуктового репо (P1):** `templates/AGENTS.md` (правила для агентів + ритуал «помилка → правило») і `templates/ci.yml` (тести, lint, dep-audit, tracking-check, secret scan) — обов'язкові у скаффолді strw-product-init.
- **`references/context-map.md` (P2):** межа static/dynamic контексту як версійоване архітектурне рішення; бюджети розміру промптів.
- **loops-log (P2):** структурований журнал запусків петель у strw-state (schema у state-protocol) — сировина для метрик harness (L5) і патернів (L6).
- **Pre-commit hook strw-state (P1):** формат inbox/state/decisions-log + скан секретів — детерміновано.

### Changed
- **loop-passport:** maker повертає trace; checker-фаза двоетапна (скрипт → LLM за рубрикою, output+trajectory); write state включає loops-log; inbox = тільки judgment.
- **strw-loop-run 0.2.0:** Step 4 вимагає trace, Step 5 двоетапний, Step 6 пише loops-log.
- **budget-policy:** checker критичних артефактів — ІНША модель, ніж maker (hard rule, було «бажано»); паспорти L2/L3 оновлені.
- **engineer + L3:** tests-first (AC → падаючі тести → код), верифікація нових залежностей, security-review по diff у stop-умові.
- **code-reviewer / validation-critic:** trajectory-перевірка (крок 0) + рубрики; dep-перевірка на галюциновані пакети.
- **qa:** чекліст «останніх 20%» (edge cases, error handling, шви інтеграцій, приховані припущення) + security-блокер.
- **artifact-contracts:** build-report і launch-checklist — обов'язкова Security-секція; portfolio-brief — метрики економіки harness (first-pass accept rate, ітерації, вартість петель).
- **strw-portfolio 0.2.0:** метрики економіки harness у Step 2.
- **strw-retro 0.2.0:** майнінг loops-log; обов'язкова регресія на golden-наборі перед застосуванням змін (також у self-improvement.md).
- **strw-product-init 0.2.0:** скаффолд включає AGENTS.md, CI, prototypes/ (disposable-політика).
- **strw-gate-review 0.2.0:** Step 1 — детермінований contract check скриптом.
- **strw-triage 0.2.0:** правило «inbox = тільки judgment».
- **L2:** правило prototype ≠ production (disposable-код валідації не мержиться без review).

## [0.1.0] — 2026-07-03
Initial release per STRW_Concept_v0.2_Loop_Factory.md:
- 6 loop passports (L1 Discovery, L2 Validation, L3 Build, L4 Growth, L5 Portfolio, L6 Retro)
- 7 skills: strw-loop-run, strw-triage, strw-gate-review, strw-portfolio, strw-retro, strw-product-init, strw-notion-sync
- 11 agents: 8 roles (discovery, validation-analyst, product-manager, designer, engineer, qa, growth, support-analytics) + 3 validators (validation-critic, code-reviewer, brand-reviewer)
- Constitution (references/): loop-passport, artifact-contracts, state-protocol, budget-policy, data-policy, data-integrity-protocol, subagent-delegation, self-improvement
- strw-state/ skeleton shipped alongside (separate repo)
