# State Protocol — робота з strw-state/

## Розташування
Приватний GitHub-репозиторій `strw-state` (конектор GitHub). Локальний клон — робоча копія петель. Notion — ТІЛЬКИ вітрина (односторонній sync, strw-notion-sync).

## Схема
```
strw-state/
├── company-context.md      # ДНК — читається ПЕРЕД будь-якою роботою
├── portfolio.md            # реєстр продуктів + WIP-ліміт (3)
├── triage-inbox.md         # єдине місце ескалацій (append-top)
├── decisions-log.md        # gate-рішення (append-only, не редагується)
├── budget.md               # стелі + факт
├── process-changelog.md    # версії процесу
├── loops-log/              # журнал запусків петель: YYYY-Www.md (append)
└── products/<id>/
    ├── state.md            # хребет: Done / In progress / Next / Tried-and-failed
    ├── idea-card.md · validation-report.md · prd.md
    ├── tracking-plan.md · build-report.md · metrics.md
```

## Правила запису
1. **Читання перед роботою:** company-context + portfolio + state.md продукту. Петля ПРОДОВЖУЄ, не починає з нуля.
2. **state.md — після КОЖНОГО циклу петлі:** що зроблено, що спробували і провалили (з причиною), що далі. Це захист від повторення тупикових шляхів.
3. **append-only** для decisions-log і triage-inbox (записи закриваються статусом DONE, не видаляються).
4. **Комміт після кожного запуску петлі:** `loop(<id>): <що зробила>` — git-історія = аудит фабрики.
4a. **loops-log після кожного запуску:** рядок у `loops-log/YYYY-Www.md`: Дата · Петля · Продукт · Тривалість · Ітерації maker↔checker · First-pass (так/ні) · Вердикти · Ескалації · Моделі M/C. Це сировина для метрик harness (L5) і патернів (L6).
4b. **Pre-commit hook:** формат inbox/state/decisions-log перевіряє `.githooks/pre-commit` (разово: `git config core.hooksPath .githooks`). Структурні фейли ловляться детерміновано, не ескалюються.
5. Конфлікт стану (два записи суперечать) → не вгадувати; ескалація `question` в inbox.
6. WIP-ліміт: перед переведенням продукту в активну стадію порахувати активні в portfolio.md; ліміт вичерпано → продукт у чергу, запис в inbox.

## state.md продукту — фіксована структура
```
# <product-id> · state
## Done
## In progress (+ ким: петля/агент)
## Next (пріоритезовано)
## Tried & failed (що / чому / коли — НЕ повторювати без нових даних)
## Open questions
```
