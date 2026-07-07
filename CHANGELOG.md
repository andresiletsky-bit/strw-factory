# Changelog

## [Unreleased]
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
