# Golden: persona-card — «TeaTrack» (еталон PASS)

> Еталон для калібрування checker'ів (validation-critic) і регресії validate-artifact.sh.
> 3 карти (мінімум контракту), третя — анти-персона. Джерела ілюстративні, формат — обов'язковий.

# TeaTrack · Personas (predicted)

```yaml
persona_id: tea-001-p1
archetype: "Чайний ентузіаст-колекціонер, 25–40"
status: predicted
weight: 0.55
weight_source: "[E] r/tea опитування ніші (лінк в idea-card, 2026-05, довіра: середня)"
version: 1
updated: 2026-08-09
demographics:
  age: "[E] 25–40 — самоописи в r/tea-тредах (лінки в idea-card, 2026-04–06, довіра: середня)"
  geo: "[I] US/EU — мовний розподіл тих самих тредів"
  platform: "[E] web/PWA — тред «Steepster is dying, alternatives?» (2026-04, довіра: середня)"
context:
  jtbd: "[E] «хочу пам'ятати, які заварки повторити» (r/tea, 2026-05, довіра: середня)"
  pains: ["[E] Steepster не підтримується з 2023 (2026-06, довіра: висока)", "[A] ручні нотатки губляться"]
behavior:
  tech_savviness: "[I] висока — вже веде Notion/Sheets для чаю (з pains)"
  price_sensitivity: "[A] стеля $2–4/міс"
  accessibility: "[A] особливих вимог не заявлено"
values_culture: "[I] культура r/tea — обмін знахідками, не змагання"
unexpected_trait: "[E] веде паперовий журнал ПОРУЧ із цифровим — цифра не заміняє ритуал (r/tea тред про notebooks, 2026-03, довіра: середня)"
anti_persona: "не колекціонер смаків: тому, хто п'є один сорт щодня, журнал непотрібен"
tracking_binding:
  cohort_definition: "events: brew_logged ≥3/тиж + collection_size ≥10 (tracking-plan)"
  calibration_metrics: ["retention_d30", "brews_per_week"]
open_assumptions: ["ручні нотатки губляться", "стеля $2–4/міс", "вимог a11y нема"]
changelog: ["v1 2026-08-09: created from validation-report"]
```
Primary: платить за пам'ять смаків. Вага — з опитування ніші, не з TAM.

```yaml
persona_id: tea-001-p2
archetype: "Початківець у листовому чаї, 20–30"
status: predicted
weight: 0.45
weight_source: "[A] оцінка — сегмент у звіті не виміряний"
version: 1
updated: 2026-08-09
demographics:
  age: "[A] 20–30"
  geo: "[A] ті самі ринки, що p1"
  platform: "[I] mobile-first — новачки приходять із коротких відео (сигнали в idea-card)"
context:
  jtbd: "[E] «не знаю, з чого почати з листовим чаєм» (r/tea beginner-тред, 2026-05, довіра: середня)"
  pains: ["[A] переплачує за чай наосліп"]
behavior:
  tech_savviness: "[A] середня"
  price_sensitivity: "[A] лише freemium"
  accessibility: "[A] без даних"
values_culture: "[A] естетика > глибина"
unexpected_trait: "[E] початківці питають про воду й температуру частіше, ніж про сорти (r/tea FAQ-тред, 2026-04, довіра: середня)"
anti_persona: "не той, хто вже має усталений ритуал — тому потрібен p1-функціонал"
tracking_binding:
  cohort_definition: "events: onboarding_completed + collection_size <5"
  calibration_metrics: ["activation_rate", "retention_d7"]
open_assumptions: ["вік", "гео", "переплачує наосліп", "tech середня", "freemium", "a11y", "естетика > глибина", "вага 0.45"]
changelog: ["v1 2026-08-09: created from validation-report"]
```
Чесно тонка карта: сегмент без даних, тому [A]-важка, і всі [A] стоять у черзі на перевірку.

```yaml
persona_id: tea-001-p3
archetype: "АНТИ-ПЕРСОНА: питець пакетованого чаю"
status: predicted
weight: 0.0
weight_source: "[E] сегмент явно поза продуктом — конкурентний аналіз validation-report (2026-06, довіра: середня)"
version: 1
updated: 2026-08-09
demographics:
  age: "[A] будь-який"
  geo: "[A] будь-де"
  platform: "[E] не шукає чайних застосунків — нульовий пошуковий інтерес (Google Trends, 2026-06, довіра: середня)"
context:
  jtbd: "[E] чай = кофеїн зранку, не хобі (опитування в idea-card, 2026-05, довіра: середня)"
  pains: ["[I] жодних — потреби в журналі нема"]
behavior:
  tech_savviness: "[A] нерелевантно"
  price_sensitivity: "[E] $0 — не платить за хобі-інструменти (validation-report §Попит, 2026-06)"
  accessibility: "[A] нерелевантно"
values_culture: "[I] зручність > ритуал"
unexpected_trait: "[E] п'є 3+ чашки на день — обсяг споживання не робить користувачем журналу (опитування idea-card, 2026-05, довіра: середня)"
anti_persona: "це і Є анти-персона: фічі «для всіх, хто п'є чай» — червоний прапорець скоупу"
tracking_binding:
  cohort_definition: "events: install без жодного brew_logged за 7 днів"
  calibration_metrics: ["churn_d7 цієї когорти — якщо вона велика, ASO цілить не туди"]
open_assumptions: ["вік", "гео", "tech", "a11y"]
changelog: ["v1 2026-08-09: created from validation-report"]
```
Анти-персона захищає скоуп: «п'є багато чаю» ≠ «наш користувач».

---

## Сіді-кейси (навмисні дефекти — checker МУСИТЬ зловити)
1. Зняти [E] з unexpected_trait будь-якої карти → FAIL рівня 0 (анти-каррикатура без джерела).
2. Додати 6-ту карту → FAIL рівня 0 (контракт: 3–5, різкість важливіша за повноту).
3. Перетегувати атрибути p1 у [A] (частка файлу >50%) → FAIL рівня 0 (P1: фантазія, не персони).
4. Вписати email/телефон «типового користувача» → FAIL рівня 0 (P7: PII).
5. Тег [E] стоїть, але без лінка/періоду/довіри → рівень 0 НЕ ловить; ловить critic за рубрикою (evidence-теги чесні).
6. Каррикатура: всі атрибути p2 — стереотипи покоління без жодної контрстереотипної деталі → critic (P6), рівень 0 мовчить.
