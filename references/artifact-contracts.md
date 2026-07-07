# Artifact Contracts — фіксовані схеми артефактів між стадіями

Урок MetaGPT: агенти обмінюються структурованими документами, не вільним чатом. Gate НЕ приймає артефакт із пропущеними обов'язковими полями. Шаблони рендеряться через Template Library (grow-pm), ці контракти — мінімальні обов'язкові поля.

**Структуру перевіряє скрипт, не LLM:** канонічні секції кожного типу зашиті в `scripts/validate-artifact.sh` — він запускається ПЕРЕД LLM-checker'ом (рівень 0). Еталони: `references/evals/golden/`. Зміст оцінюється за `references/evals/rubrics.md`.

## idea-card.md (вихід L1 / ручний intake)
Обов'язково: Назва · Проблема (чий біль, як розв'язують зараз) · Сигнали попиту (≥2 джерела з лінками) · Тип (SaaS/Mobile/AI/Content) · Гіпотеза монетизації · Чому ми/чому зараз · Перша оцінка ICE (I/C/E 1–10 + сума).

## validation-report.md (вихід L2, вхід G1)
Обов'язково: TAM/SAM/SOM з методом розрахунку · Конкуренти (≥3, ціни, слабкості) · Попит (докази, не припущення — data-integrity-protocol) · Ризики (ринкові/технічні/легальні) · Найдешевший спосіб перевірки гіпотези · ICE фінальний · **Рекомендація BUILD/KILL/PIVOT + аргументи за/проти** · Розділ critic-review (заперечення checker'а і відповіді на них).

## prd.md (вихід стадії Definition, вхід G2)
Обов'язково: Проблема і цілі · Метрики успіху (число + період) · Scope MVP · НЕ-цілі · User stories з acceptance criteria · Залежності/ризики · Tracking-вимоги (events) · Оцінка обсягу.

## design-handoff (стадія Design)
За design-bridge: токени, компоненти, стани, breakpoints, WCAG 2.1 AA — blocker.

## build-report.md (вихід L3, вхід G3)
Обов'язково: Що реалізовано vs PRD (diff scope) · Статус тестів (лінк на CI; тести написані з AC до коду) · **Security: dep-audit чистий + нові залежності верифіковані в реєстрі (без галюцинованих/typosquat) + security-review по diff** · Tracking plan покриття · Відомі обмеження · Чеклист deploy-checklist пройдено · Code-review вердикт checker'а.

## launch-checklist.md (стадія QA & Launch)
Обов'язково: тести пройдені · аналітика верифікована на staging · **security-блокер: dep-audit + secret scan + security-review закриті (аналог WCAG у design-handoff)** · rollback-план · сторінка продукту · ціни.

## growth-report.md (вихід L4)
Обов'язково: Кампанії за тиждень · Метрики (трафік, конверсія, CAC якщо є) · Контент опубліковано/у черзі · Наступний тиждень.

## portfolio-brief.md (вихід L5, головний документ тижня)
Обов'язково: Стан кожного продукту (стадія, ключова метрика, тренд) · Метрики фабрики (throughput, kill-rate, autonomy ratio, inbox lag, budget факт · **економіка harness з loops-log: first-pass accept rate, середні ітерації maker↔checker, вартість/тривалість запуску петлі + тренд**) · 1–3 фокуси наступного тижня · Кандидати на KILL/подвійну ставку · Питання, що чекають рішення в inbox.

## gate-decision (запис у decisions-log.md)
Обов'язково: Дата · Продукт · Gate (G1–G4) · Рішення GO/KILL/PIVOT · Аргументи за/проти/ризики · Підтвердження «артефакт прочитано» · Хто (Andrii).
