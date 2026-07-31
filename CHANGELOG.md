# Changelog

## [Unreleased]
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
