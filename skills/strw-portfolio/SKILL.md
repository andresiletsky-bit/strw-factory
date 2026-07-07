---
name: strw-portfolio
version: 0.2.0
description: Weekly STRW portfolio review (L5 loop) — gather product metrics, compute factory metrics, produce the portfolio brief with next-week focuses and KILL/double-down candidates. Use when the user asks "портфель", "portfolio review", "тижневий огляд", "стан фабрики", "portfolio brief", "п'ятничний огляд", or when the L5 scheduled task fires.
---

# STRW Portfolio (L5)

Тижневий G4-огляд портфеля — головний документ тижня для CEO. Це skill-обгортка петлі L5 (запускається і напряму, і через strw-loop-run).

## Workflow

### Step 1 — Gather (fan-out)
Для кожного продукту в portfolio.md — субагент strw-support-analytics збирає: стадію, ключову метрику+тренд, аномалії, top-гіпотези. Компактні структури, ≤6 паралельно.

### Step 2 — Factory metrics
Порахуй за тиждень:
- **throughput** — ідей пройшло G1; **kill-rate** — % убитих до розробки;
- **autonomy ratio** — % запусків петель без ескалації (з git-логу `loop(...)` і inbox);
- **inbox lag** — медіана часу OPEN→DONE;
- **budget** — факт vs стеля (budget.md); **read coverage** — % gates із підтвердженим прочитанням;
- **економіка harness** (з loops-log/): **first-pass accept rate** — % запусків із PASS з першої подачі; середні ітерації maker↔checker; вартість/тривалість запуску петлі. Тренд вниз по first-pass = ранній сигнал деградації harness → кандидат у фокуси;
- **time-to-launch / portfolio MRR** — коли застосовно.
Data Integrity Gate: неповний тиждень позначається, не екстраполюється.

### Step 3 — Brief
Збери `portfolio-brief.md` за контрактом: стан продуктів · метрики фабрики · **1–3 фокуси наступного тижня** (з аргументами) · кандидати на KILL/подвійну ставку · що чекає в inbox. Збережи в strw-state (папка `briefs/` з датою), додай запис-finding в inbox.

### Step 4 — Recommend
Фокуси мають бути actionable: кожен — з chain-командою (напр. «G4 для tea-001 → strw-gate-review»). Порожній тиждень (нема прод-продуктів) → фокус на воронці: скільки ідей у черзі, де застрягло.

## Rules
- Тільки business-сигнали визначають фокуси: MRR/конверсія/kill-rate > «петлі шумлять активністю».
- Чесність із трендами: 2 точки — не тренд.
- References: `${CLAUDE_PLUGIN_ROOT}/references/artifact-contracts.md`, `data-integrity-protocol.md`, `subagent-delegation.md`.
