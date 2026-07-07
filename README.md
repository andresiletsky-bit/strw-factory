# STRW Factory

**Version:** 0.2.0 · Orchestration layer for a one-person AI product company (STRW).

Runs the factory as **loops, not prompts**: scheduled/event-driven loops find work, execute it with maker/checker separation, write state to a git spine, and escalate only gate decisions and irreversible actions to the human CEO.

Design sources: `STRW_Concept_v0.2_Loop_Factory.md`, Loop Engineering (Addy Osmani), whitepaper «The New SDLC with Vibe Coding» (Google/Kaggle 2026: evals не демо, trajectory-верифікація, детерміновані guardrails, економіка harness), proven patterns from grow-product-manager-plugin (data-integrity gate, subagent delegation, self-improvement, template protocol).

## Architecture

```
Andrii (CEO) ── triage-inbox ──┐
                               ▼
        ┌── loops/ (L1–L6 passports) ── strw-loop-run ──┐
        │   maker agent → checker agent → state write    │
        ▼                                                ▼
   agents/ (8 roles + 3 validators)          strw-state/ (git spine)
        │                                                │
        └── existing Cowork plugins (grow-pm, design,    └─→ Notion (one-way
            engineering, marketing, product-tracking…)        human dashboard)
```

## Loops
| ID | Loop | Trigger | Maker → Checker |
|----|------|---------|-----------------|
| L1 | Discovery | Пн/Ср/Пт | discovery → validation-critic |
| L2 | Validation | нова картка | validation-analyst → validation-critic |
| L3 | Build | пост-G2 | engineer(+designer) → code-reviewer, qa |
| L4 | Growth | щотижня/прод | growth → brand-reviewer |
| L5 | Portfolio | щоп'ятниці | support-analytics → data-integrity pass |
| L6 | Retro | щоп'ятниці | strw-retro → Andrii |

## Skills
`strw-loop-run` (єдиний вхід петель) · `strw-triage` (розбір inbox) · `strw-gate-review` (G1–G4) · `strw-portfolio` (L5) · `strw-retro` (L6) · `strw-product-init` (intake + скаффолд) · `strw-notion-sync` (git → Notion).

## Gates
G1 build-or-kill · G2 scope lock · G3 ready-to-ship · G4 portfolio review. Рішення — тільки людина, з підтвердженим прочитанням артефакту, логується в decisions-log.md.

## Constitution (references/)
loop-passport · artifact-contracts · state-protocol · budget-policy · data-policy · data-integrity-protocol · subagent-delegation · self-improvement · context-map · **evals/** (rubrics + golden set).

## Verification layers
1. **Рівень 0 (детермінований):** `scripts/validate-artifact.sh` — структура артефактів; pre-commit hook у strw-state; CI у продуктових репо (`templates/ci.yml`).
2. **Рівень 1 (LLM-checker):** інша модель, ніж maker (hard rule) · рубрики `references/evals/rubrics.md` · output І trajectory (trace maker'а проти паспорта).
3. **Регресія:** будь-яка зміна промпту/скіла/паспорта — прогін на golden-наборі перед bump версії.

## Setup
1. Створи приватний GitHub-репозиторій `strw-state` із каркасу в `STRW/strw-state/` (готовий у робочій папці).
2. Встанови плагін (`strw-factory.plugin`).
3. Створи scheduled tasks: «STRW L1 Discovery» (Пн/Ср/Пт ранок) і «STRW L5+L6 Friday» (пт по обіді) — обидва з промптом виду «Run strw-loop-run for L1-discovery headless».
4. Ритуал: розбирай inbox через `strw-triage` 1–2×/день.

## Releases
Релізи плагіна — вручну з термінала (`git` + `gh` тримають GitHub-авторизацію на твоєму боці).

Разова ініціалізація (бо теку ще не під git):
```bash
cd strw-factory
./scripts/release.sh setup git@github.com:<you>/strw-factory.git
git add -A && git commit -m "chore: import strw-factory"
git push -u origin main
```

Реліз:
```bash
./scripts/release.sh patch        # 0.1.0 → 0.1.1
./scripts/release.sh minor        # 0.1.0 → 0.2.0
./scripts/release.sh 0.4.2        # явна версія
./scripts/release.sh patch --dry-run   # прогнати без змін
```
Скрипт: bump `plugin.json` → промоує розділ `## [Unreleased]` у CHANGELOG у датовану версію → commit → tag `vX.Y.Z` → push → GitHub Release. Нотатки релізу бере з `[Unreleased]` (або з `-m "..."`). Прапорці: `--dry-run`, `--no-push`, `--no-gh`, `-y`. Перед релізом наповнюй `[Unreleased]` у `CHANGELOG.md`.

## Hard rules
Maker ≠ Checker (інша модель для критичних артефактів) · Планка = eval, не демо · State або не сталося · Один inbox (тільки judgment) · Бюджет = обмеження (стоп, не «доробити») · Незворотнє — тільки людина · Людина читає gate-артефакти · Tests-first у Build · Prototype ≠ production.

**Author:** Andrii Siletskyi · License: private
