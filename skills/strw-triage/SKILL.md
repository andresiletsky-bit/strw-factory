---
name: strw-triage
version: 0.2.0
description: Triage the STRW inbox — rank open escalations, present decisions to make, chain execution to the right loop or skill. Use when the user asks "розбери inbox", "що чекає рішень", "triage", "що на порядку денному", "розбір ескалацій", "daily triage", or for the morning/evening triage ritual. The CEO attention dispatcher of the factory.
---

# STRW Triage

Розбір triage-inbox — головний ритуал Andrii (1–2×/день). Диспетчер уваги CEO: показати що чекає рішень, у правильному порядку, з контекстом і наступним кроком.

## Workflow

### Step 1 — Read
`strw-state/triage-inbox.md` (усі OPEN) + `portfolio.md` + `budget.md` (факт місяця).

### Step 2 — Rank (детермінований порядок)
1. `budget-alert` та `error` (фабрика зупинена/зламана);
2. `gate-request` — по стадіях, що блокують найбільше роботи (Build > Validation > Growth);
3. крит-`finding` (аномалії проду);
4. `question` від петель;
5. інформаційні finding.
Всередині групи — старіші перші (inbox lag «тікає»).

### Step 3 — Present
Компактний бриф: № · тип · продукт · суть · пропозиція петлі · що потрібно від Andrii. Для gate-request — нагадай правило «людина читає»: лінк на ключовий артефакт, gate не закривається без його прочитання.

### Step 4 — Execute decisions
Для кожного рішення Andrii:
- gate-request → chain до `strw-gate-review` (формальне рішення + лог);
- «запусти/продовж» → chain до `strw-loop-run`;
- відповідь на question → запиши рішення в запис inbox + у відповідний state.md;
- познач запис `[DONE]` з датою і рішенням. Записи не видаляються.

### Step 5 — Metrics
Порахуй і додай у кінець брифу: inbox lag (медіана днів OPEN), кількість OPEN за типами. Lag > 2 днів по gate-request — прямо скажи: «ти — bottleneck, ось найстаріший gate».

## Rules
- Ти диспетчер, не виконавець: рекомендуєш і чейниш, рішення — за Andrii.
- **Inbox = тільки judgment.** Час CEO — на рішення (gates, trade-offs, гроші), не на перевірку структури. Запис, який міг би закрити скрипт/checker (форматний фейл, пропущена секція, «поправ таблицю») — не ескалація: закрий поверненням у петлю і запропонуй правило/хук, що ловитиме це детерміновано (self-improvement).
- Не вигадуй записів поза inbox; знайшов проблему поза ним — спершу додай запис (тип finding), потім показуй.
- References: `${CLAUDE_PLUGIN_ROOT}/references/state-protocol.md`.
