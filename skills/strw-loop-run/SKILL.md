---
name: strw-loop-run
version: 0.2.0
description: Execute an STRW factory loop (L1–L6) by its passport — read state, budget check, maker phase, checker phase, write state, escalate or archive. Use when the user asks to "запусти петлю", "run loop", "запусти discovery/validation/build/growth/portfolio/retro", "виконай L1/L2/L3/L4/L5/L6", "продовж петлю для продукту", or when a scheduled task fires a loop run. Also the headless entry point for all scheduled STRW loops.
---

# STRW Loop Run

Виконати одну петлю фабрики строго за її паспортом. Це ЄДИНИЙ вхід для запуску петель — і ручний, і headless (scheduled).

## Prerequisites
- Знайти `strw-state/` (локальний клон або через GitHub-конектор; шлях — у company-context, дефолт: репо `strw-state`). Не знайдено → зупинись, повідом користувача.
- Паспорт петлі: `${CLAUDE_PLUGIN_ROOT}/loops/<loop-id>.md`. Немає паспорта → петля не запускається.

## Workflow

### Step 1 — Resolve loop
Визнач петлю з запиту (L1-discovery … L6-retro). Неоднозначно → запитай. Прочитай паспорт повністю.

### Step 2 — Read state (обов'язково ПЕРЕД роботою)
`company-context.md` + `portfolio.md` + для продуктових петель `products/<id>/state.md` (включно з Tried & failed). Петля продовжує роботу, не починає з нуля.

### Step 3 — Budget check
Звір `budget.md`: ліміт запусків/тиждень цієї петлі; стеля зовнішніх витрат. Вичерпано → STOP, запиши `budget-alert` у triage-inbox, заверши.

### Step 4 — Maker phase
Виклич maker-агента з паспорта (Task tool, subagent із `agents/`). Передай йому: scope, релевантні файли state, контракт вихідного артефакту (references/artifact-contracts.md). Fan-out — за references/subagent-delegation.md (≤6). Вимагай разом з артефактом **trace**: файли state прочитані · перевірки виконані · тули/скіли викликані · ітерації. Без trace артефакт не приймається.

### Step 5 — Checker phase (двоетапно)
1. **Детермінований:** `bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-artifact.sh <type> <file>` — обов'язкові секції контракту. FAIL → назад maker'у, LLM-checker НЕ викликається, в inbox НЕ пишеться.
2. **LLM-checker** з паспорта (ЗАВЖДИ інший промпт; для критичних артефактів — інша модель, ніж maker, budget-policy). Передай йому артефакт + trace maker'а + рубрику (references/evals/rubrics.md). Перевіряє output І trajectory. Вердикт FAIL → поверни maker'у (max 2 ітерації), далі — розбіжність фіксується в артефакті, ескалація.

### Step 6 — Write state (без цього запуск не відбувся)
- Оновити `products/<id>/state.md` (Done/Next/Tried & failed) та/або `portfolio.md`.
- Записати факт у `budget.md`.
- Додати рядок у `loops-log/` (схема — state-protocol.md): дата · петля · продукт · тривалість · ітерації maker↔checker · first-pass так/ні · вердикти · ескалації · моделі maker/checker.
- Git commit: `loop(<id>): <підсумок одним рядком>` (+ push, якщо конектор доступний).

### Step 7 — Escalate or archive
- Знахідки/gate-запити/питання → append-top у `triage-inbox.md` за схемою inbox.
- Порожній результат → один рядок логу, тихе завершення (без шуму в inbox).

## Rules
- Строго за паспортом: scope, stop-умова, бюджет. Робота поза scope = порушення.
- Незворотні дії всередині петлі заборонені — лише запит у inbox.
- Headless-режим: жодних питань користувачу; неоднозначність → ескалація `question` в inbox і graceful stop.
- References: `${CLAUDE_PLUGIN_ROOT}/references/loop-passport.md`, `state-protocol.md`, `budget-policy.md`, `data-policy.md`.
- Наприкінці, якщо були корекції користувача — `references/self-improvement.md`.
