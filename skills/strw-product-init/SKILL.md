---
name: strw-product-init
version: 0.2.0
description: Scaffold a new STRW product after G1 GO — state files, product repo/worktree, Notion page stub, loop wiring. Also handles manual idea intake (create an idea card bypassing Discovery). Use when the user asks "заведи продукт", "ініціалізуй продукт", "нова ідея вручну", "створи картку ідеї", "product init", or when strw-gate-review chains a G1 GO.
---

# STRW Product Init

Два режими: **intake** (ручна ідея → картка) і **init** (після G1 GO → повний скаффолд).

## Mode A — Intake (ручна ідея)
1. Збери в діалозі поля контракту idea-card.md (artifact-contracts). Сигнали попиту (≥2 джерела) — якщо нема, швидкий пошук; не знайшлось → чесно позначити «сигнали слабкі».
2. Прогони через strw-validation-critic (дедуп + ДНК-фільтр).
3. Створи `products/<id>/` + idea-card.md + state.md (за state-protocol) + рядок у portfolio.md (стадія 1, pre-G1) + запис в inbox: «кандидат на L2».
ID: коротке-слово-NNN (напр. tea-001).

## Mode B — Init (після G1 GO)
1. Перевір WIP-ліміт (активних <3, інакше — назад у gate-review).
2. strw-state: онови state.md (Next: Definition), portfolio.md (стадія 3).
3. GitHub: створи приватний репозиторій продукту (конектор) зі скаффолдом дефолтного стека з company-context; README з лінком на strw-state. Конектор недоступний → створи локально + запис `question` в inbox.
   Обов'язково в скаффолд:
   - **AGENTS.md** з `${CLAUDE_PLUGIN_ROOT}/templates/AGENTS.md` — заповни плейсхолдери (продукт, стек, конвенції). Ритуал «агент помилився → додай правило» — append-only секція внизу.
   - **CI** з `${CLAUDE_PLUGIN_ROOT}/templates/ci.yml` → `.github/workflows/ci.yml`, кроки адаптуй під стек (тести, lint, dep-audit, tracking-check, secret scan). Зелений CI = доказ stop-умови L3.
   - Тека `prototypes/` з README: «disposable-код валідації; НІКОЛИ не мержиться в src/ без повного code-review».
4. Worktree-політика: кожна паралельна фіча в Build — окремий worktree (`isolation: worktree` для субагентів).
5. Notion-вітрина: сторінка продукту через strw-notion-sync (best-effort, не блокер).
6. Git commit: `init(<id>): scaffolded after G1 GO`.

## Rules
- Скаффолд мінімальний: репо + стан + сторінка. Ніяких «на виріст».
- Створення платних ресурсів (домени, хостинг) — незворотнє → тільки запит в inbox.
- References: `${CLAUDE_PLUGIN_ROOT}/references/state-protocol.md`, `artifact-contracts.md`.
