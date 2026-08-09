# Artifact Contracts — фіксовані схеми артефактів між стадіями

Урок MetaGPT: агенти обмінюються структурованими документами, не вільним чатом. Gate НЕ приймає артефакт із пропущеними обов'язковими полями. Шаблони рендеряться через Template Library (grow-pm), ці контракти — мінімальні обов'язкові поля.

**Структуру перевіряє скрипт, не LLM:** канонічні секції кожного типу зашиті в `scripts/validate-artifact.sh` — він запускається ПЕРЕД LLM-checker'ом (рівень 0). Еталони: `references/evals/golden/`. Зміст оцінюється за `references/evals/rubrics.md`.

## idea-card.md (вихід L1 / ручний intake)
Обов'язково: Назва · Проблема (чий біль, як розв'язують зараз) · Сигнали попиту (треки A/B: ≥2 джерела з лінками; трек C: замість сигналів — проба спростування ≤ тижня, L1-discovery 2a) · Тип (SaaS/Mobile/AI/Content) · Гіпотеза монетизації · Чому ми/чому зараз · Перша оцінка ICE (I/C/E 1–10 + сума) · Гіпотеза аудиторії (1–2 прото-персони, по ≤3 рядки — хто і чому; НЕ повні persona-card).

## validation-report.md (вихід L2, вхід G1)
Обов'язково: TAM/SAM/SOM з методом розрахунку · Конкуренти (≥3, ціни, слабкості) · Попит (докази, не припущення — data-integrity-protocol) · Ризики (ринкові/технічні/легальні) · Найдешевший спосіб перевірки гіпотези · ICE фінальний · **Рекомендація BUILD/KILL/PIVOT + аргументи за/проти** · Розділ critic-review (заперечення checker'а і відповіді на них) · Персони (predicted): 3–5 карт за контрактом persona-card у `products/<id>/personas.md` — з того самого VoC-матеріалу, що й звіт (рівень 0 примусить після оновлення golden; зафіксовано при введенні контракту).

## prd.md (вихід стадії Definition, вхід G2)
Обов'язково: Проблема і цілі · Метрики успіху (число + період; сегментовані по персонах, де це вимірюване) · Scope MVP · НЕ-цілі · User stories з acceptance criteria (кожна прив'язана до persona_id з `personas.md`) · Залежності/ризики · Tracking-вимоги (events; включно з cohort_definition персон) · Оцінка обсягу.

## personas.md — persona-card (вихід L2 разом зі звітом; живе далі всі стадії)
Один файл на продукт (`products/<id>/personas.md`), 3–5 карт, кожна — YAML-блок (```yaml) + ≤5 рядків прози; одна з карт — анти-персона. Схема YAML — шаблон `_brain/_templates/persona-card.md` (концепт [[STRW_Persona_Layer_v1]] розд. 3, дослівно). Обов'язкові поля кожної карти: `persona_id` (`<product>-p<N>`) · `archetype` · `status` (predicted/calibrated/deprecated) · `weight` + `weight_source` · `demographics`/`context`/`behavior` з тегом [E]/[I]/[A] на кожному атрибуті · ≥1 [E]-джерело в `context` (лінк + період + довіра, як data-integrity) · `unexpected_trait` з [E] (анти-каррикатура) · `anti_persona` · `tracking_binding` (cohort_definition + calibration_metrics проти tracking-plan) · `open_assumptions` (усі [A] — черга на перевірку) · `changelog`. Частка [A]-атрибутів файлу ≤50% — інакше це фантазія, не персони. Synthetic ≠ evidence: карти й панельні виходи ніколи не стоять у «Попит»/«Сигнали попиту» і не входять у G-рішення (data-integrity-protocol, клас `synthetic`).

## design-handoff (стадія Design)
За design-bridge: токени, компоненти, стани, breakpoints, WCAG 2.1 AA — blocker.

## build-report.md (вихід L3, вхід G3)
Обов'язково: Що реалізовано vs PRD (diff scope) · Статус тестів (лінк на CI; тести написані з AC до коду) · **Security: dep-audit чистий + нові залежності верифіковані в реєстрі (без галюцинованих/typosquat) + security-review по diff** · Tracking plan покриття · Відомі обмеження · Чеклист deploy-checklist пройдено · Code-review вердикт checker'а.

## launch-checklist.md (стадія QA & Launch)
Обов'язково: тести пройдені · аналітика верифікована на staging · **security-блокер: dep-audit + secret scan + security-review закриті (аналог WCAG у design-handoff)** · rollback-план · сторінка продукту · ціни.

## growth-report.md (вихід L4)
Обов'язково: Кампанії за тиждень · Метрики (трафік, конверсія, CAC якщо є) · Контент опубліковано/у черзі · Наступний тиждень.

## portfolio-brief.md (вихід L5, головний документ тижня)
Обов'язково: Стан кожного продукту (стадія, ключова метрика, тренд) · Метрики фабрики (throughput, kill-rate, autonomy ratio, inbox lag, budget факт · **економіка harness з loops-log: first-pass accept rate, середні ітерації maker↔checker, вартість/тривалість запуску петлі + тренд**) · **Kill-ризики продуктів у проді (pact-001: R1/R2 за правилом рішення з паспорта L5 — частка, вибірка, вікно, статус; до першого прод-релізу — чесне «н/д до M4», без вигаданих чисел)** · 1–3 фокуси наступного тижня · Кандидати на KILL/подвійну ставку · Питання, що чекають рішення в inbox.

## gate-decision (запис у decisions-log.md)
Обов'язково: Дата · Продукт · Gate (G1–G4) · Рішення GO/KILL/PIVOT · Аргументи за/проти/ризики · Підтвердження «артефакт прочитано» · Хто (Andrii).
