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
4c. **Headless-сесія НІКОЛИ не виконує git-команд у `strw-state`.** Додано 2026-07-28 після третього інциденту того самого класу за тиждень (07-27, 07-28 AM, 07-28 PM).

**Чому правило, а не обхід.** У пісочниці headless-сесії `.git` недоступний на запис: `rm .git/index.lock` → `Operation not permitted`, а креденшелів для `git push` немає взагалі (`could not read Username`). Обхідний шлях (temp `GIT_INDEX_FILE` + `write-tree` + `update-ref`) **28.07 дав тихий відкат**: `git add` упав, але `write-tree` усе одно повернув валідний хеш старішого дерева, і `update-ref` перевів локальний `main` на коміт `dcd6a6c`, який видаляв записи трьох ескалацій, ратифікацію CEO і цілий цикл у `state.md`. Врятував лише провалений push. **Обхід небезпечніший за блокування.**

**Механізм — outbox.** Headless-сесія:
1. Пише результат у `strw-state/_outbox/<YYYY-MM-DDTHH-MM>-<loop>-<product>.md` — звичайний файл, довільний вміст, **жодної git-команди**.
2. На цьому її робота зі станом завершена. Ескалації, факти бюджету, рядки loops-log — усе туди.

Сесія з робочим git (інтерактивна на Mac) на початку роботи:
1. Читає `_outbox/*`, вливає вміст у канонічні файли (`triage-inbox.md`, `budget.md`, `loops-log/`, `products/<id>/state.md`).
2. Комітить **пошляхово**, ніколи `git add -A`, і пушить.
3. Видаляє злиті файли з `_outbox/`.

**Перед будь-яким комітом у `strw-state` звіряти `git rev-parse HEAD` і `git rev-parse origin/main` окремими командами.** Розбіжність → спершу `git pull --ff-only`, ніколи не комітити поверх. Це правило куплене інцидентом `dcd6a6c`: сесія без креденшелів комітила поверх дерева, прочитаного ДО чужих комітів.

**Ознака, що правило порушено:** будь-який `.lock` у `strw-state/.git` після headless-заходу. Прибирати лок можна лише звіривши розмір, mtime і `pgrep -fl git` — ніколи не видаляти лок, яким володіє живий процес.

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
