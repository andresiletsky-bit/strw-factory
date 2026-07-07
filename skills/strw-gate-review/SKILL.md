---
name: strw-gate-review
version: 0.2.0
description: Run a formal STRW gate decision (G1 build-or-kill, G2 scope lock, G3 ready-to-ship, G4 portfolio review) with debate pattern and logged GO/KILL/PIVOT outcome. Use when the user asks "проведи gate", "G1/G2/G3/G4 для продукту", "build or kill", "gate review", "ухвалимо рішення по продукту", or when strw-triage chains a gate-request.
---

# STRW Gate Review

Формальне gate-рішення. Gates — єдині точки, де фабрика чекає людину; тому процедура строга.

## Gates
| Gate | Після стадії | Питання | Вхідний артефакт (контракт) |
|------|--------------|---------|------------------------------|
| G1 | Validation | build or kill? | validation-report.md |
| G2 | Definition | scope lock? | prd.md |
| G3 | Build | ready to ship? | build-report.md + launch-checklist |
| G4 | Support (циклічно) | продовжувати/подвоїти/вбити? | metrics.md + portfolio-brief |

## Workflow

### Step 1 — Contract check
Спершу детерміновано: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-artifact.sh <type> <file>`. Потім звір зміст з `references/artifact-contracts.md`. Пропущені обов'язкові поля → gate НЕ проводиться, поверни продукт на стадію з конкретним списком прогалин.

### Step 2 — Read confirmation (анти-cognitive-surrender)
Покажи Andrii ключовий артефакт (не summary). Попроси явне підтвердження прочитання. Без нього — не продовжуй.

### Step 3 — Debate
Подай дві позиції: **ЗА** (аргументи maker'а) і **ПРОТИ** (заперечення checker'а + твої додаткові ризики). Якщо в артефакті є нерозв'язана розбіжність maker/checker — постав її в центр.

### Step 4 — Decision
Andrii ухвалює: **GO / KILL / PIVOT** (+ умови, якщо є). Ти можеш рекомендувати, але рішення тільки людське. Патерн «третій тиждень поспіль рішення = рекомендація без жодної правки» → зазнач це вголос (правило §5.5 концепту).

### Step 5 — Log & propagate
1. Запис у `decisions-log.md` за контрактом gate-decision (append-only).
2. Онови `portfolio.md` (стадія/gate-статус; KILL → Kill log).
3. Закрий запис у triage-inbox `[DONE]`.
4. GO → chain: запусти наступну стадію через `strw-loop-run` або `strw-product-init` (після G1).
5. Git commit: `gate(<G#>, <product>): <рішення>`.

## Rules
- WIP-ліміт: GO, що робить активних продуктів >3 → рішення відкладається або інший продукт паузиться — явно спитай.
- KILL — це перемога фільтра, не поразка: у лог пиши уроки (що б змусило повернутись до ідеї).
- References: `${CLAUDE_PLUGIN_ROOT}/references/artifact-contracts.md`, `state-protocol.md`.
