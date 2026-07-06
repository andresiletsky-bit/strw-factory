---
name: strw-retro
version: 0.1.0
description: Weekly STRW retro loop (L6) — mine loop logs and user corrections for error patterns, propose minimal process/skill improvements per the self-improvement protocol. Use when the user asks "ретро", "retro", "що покращити в процесі", "фабрика вчиться", "аналіз помилок тижня", or when the L6 scheduled task fires (after L5 on Fridays).
---

# STRW Retro (L6)

Петля самопокращення фабрики — аналог «Dreaming»: переглянути тиждень, знайти патерни, запропонувати мінімальні зміни процесу.

## Workflow

### Step 1 — Mine
Джерела за тиждень: git-лог strw-state (`loop(...)`, `gate(...)`) · закриті записи inbox (особливо де рішення Andrii ≠ пропозиція петлі) · state.md продуктів (Tried & failed, повторні цикли maker↔checker) · budget.md (перевитрати/недовикористання).

### Step 2 — Patterns
Шукай ПОВТОРЮВАНЕ (≥2 випадки): checker пропускає той самий клас помилок · maker систематично порушує контракт · петля шумить в inbox дрібницями · Andrii щоразу виправляє те саме · каденс не відповідає реальності (запуски впусту). One-off — ігноруй.

### Step 3 — Propose (за self-improvement.md)
Для кожного патерна: «поточна поведінка → мінімальна зміна → як запобігає». Кандидати на зміну: SKILL.md, паспорт петлі, промпт агента, контракт артефакту, каденс/бюджет. Нумерований список — Andrii обирає.

### Step 4 — Apply (тільки прийняте)
Правка файлу → bump версії skill → bump plugin.json → CHANGELOG.md плагіну → strw-state/process-changelog.md (semver процесу). Незастосоване — залогуй як відхилене (щоб не пропонувати повторно без нових даних).

### Step 5 — Health flags
Окремо перевір і скажи прямо, якщо бачиш: read coverage падає (gates без читання) · autonomy ratio <50% (петлі погано спроєктовані) · рішення = рекомендація 3+ тижні поспіль (cognitive surrender) · budget-факт систематично б'є в стелю.

## Rules
- Мінімальні зміни; максимум 3 пропозиції за раз — інакше процес розхитується.
- Зміни без дозволу Andrii заборонені.
- References: `${CLAUDE_PLUGIN_ROOT}/references/self-improvement.md`, `budget-policy.md`.
