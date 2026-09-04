---
name: strw-triage
version: 0.5.0
description: Triage the STRW inbox — rank open escalations, present decisions to make, chain execution to the right loop or skill. Use when the user asks "розбери inbox", "що чекає рішень", "triage", "що на порядку денному", "розбір ескалацій", "daily triage", or for the morning/evening triage ritual. The CEO attention dispatcher of the factory — since v0.3.0, inbox holds ONLY items that genuinely need Andrii (non-gate continuations auto-advance per strw-loop-run Step 7).
---

# STRW Triage

Розбір triage-inbox — головний ритуал Andrii (1–2×/день). Диспетчер уваги CEO: показати що чекає рішень, у правильному порядку, з контекстом і наступним кроком.

## Workflow

### Step 1 — Read
Спершу `brain query`, читай лише повернуті секції. Відкриті ескалації живуть у `strw-state/triage/open/` (по файлу на запис); `triage-inbox.md` — ГЕНЕРОВАНИЙ зріз, рішення вписується у вузол, далі `split-monoliths.mjs --regen`. Далі `portfolio.md` + `decisions-log.md` (останні рішення — щоб не показати CEO картку, яку рішення вже закрило: `tri-015` 03.09) + `budget.md` (факт місяця). Кожен вузол з 04.09 (П1.6) несе `summary`, `options`, `default_if_silent`, `decide_by` — читай спершу їх, тіло під `## Доказ` — лише якщо CEO попросить.

### Step 2 — Rank (детермінований порядок)
1. `budget-alert` та `error` (фабрика зупинена/зламана);
2. `gate-request` — по стадіях, що блокують найбільше роботи (Build > Validation > Growth);
3. крит-`finding` (аномалії проду);
4. `question` від петель;
5. інформаційні finding.
Всередині групи — **прострочені за `decide_by` перші** (`scripts/triage-deadline-check.sh` дає список), далі старіші перші (inbox lag «тікає»).

### Step 3 — Present
Компактний бриф з полів вузла: № · тип · продукт · `summary` (≤400 символів, як є — не переказуй наратив) · `options` з ціною · `default_if_silent` · днів до/після `decide_by`. Картка без цих полів (до 04.09) — переказ у 2–3 рядки, і познач її: «стара схема». Не цитуй тіло картки: CEO читає `summary` і обирає з `options`; тіло — за запитом. Для gate-request — нагадай правило «людина читає»: лінк на ключовий артефакт, gate не закривається без його прочитання. Якщо запис — продовження старішого запису по тому ж продукту, підсумуй **«що змінилось з минулого разу»** (2–4 рядки) замість того, щоб Andrii сам гортав історію — це вже мало бути записано петлею на Step 8 strw-loop-run; якщо немає, додай сам зараз.

### Step 4 — Execute decisions
Для кожного рішення Andrii:
- gate-request → chain до `strw-gate-review` (формальне рішення + лог);
- відповідь на `question` (найчастіше — WIP/секвенування-конфлікт, який auto-advance не міг вирішити сам) → якщо рішення розблоковує петлю, chain до `strw-loop-run`; запиши рішення в запис inbox + у відповідний state.md;
- «запусти/продовж» від Andrii поза очікуваним інбоксом (напр. ручний пріоритет, ad-hoc запит) — так само chain до `strw-loop-run`, це лишається доступним, просто вже не єдиний спосіб щось запустити;
- познач запис `[DONE]` з датою і рішенням. Записи не видаляються.

### Step 5 — Metrics
Прожени `bash scripts/triage-deadline-check.sh` у strw-state і додай у кінець брифу його підсумок (прострочені · спливають · без дедлайну · вік найстаршої) плюс inbox lag (медіана днів OPEN) і кількість OPEN за типами. Lag > 2 днів по gate-request або найстарша картка понад 10 діб — прямо скажи: «ти — bottleneck, ось найстаріша». Картка, що спливла, а CEO мовчить, — виконується `default_if_silent`, і це записується в неї як рішення «за замовчуванням, дата».

## Rules
- **Автономність (з 0.3.0, 2026-07-20):** не-gate продовження (старт L2 у межах WIP/секвенування, продовження L3 після G2, L4 щотижня, L1/L5/L6 за розкладом) відбуваються самі — через scheduled tasks і Step 7 (Auto-advance) у `strw-loop-run` — і НЕ чекають слова «запусти» від Andrii. Inbox показує тільки те, що дійсно gate-рішення, незворотна дія, budget-alert/error або genuine question. Якщо в inbox з'являється запис типу «чекає команди на старт», який не є жодним із цього списку — це регресія в петлі, познач як finding і поверни в strw-loop-run для виправлення, а не проси в Andrii дозволу вручну.
- Ти диспетчер, не виконавець: рекомендуєш і чейниш, рішення — за Andrii.
- **Inbox = тільки judgment.** Час CEO — на рішення (gates, trade-offs, гроші), не на перевірку структури. Запис, який міг би закрити скрипт/checker (форматний фейл, пропущена секція, «поправ таблицю») — не ескалація: закрий поверненням у петлю і запропонуй правило/хук, що ловитиме це детерміновано (self-improvement).
- Не вигадуй записів поза inbox; знайшов проблему поза ним — спершу додай запис (тип finding), потім показуй.
- References: `${CLAUDE_PLUGIN_ROOT}/references/state-protocol.md`.
