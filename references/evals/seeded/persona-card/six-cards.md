---
type: persona-card
expect: FAIL
level: 0
defect: шість карт при контракті 3–5: різкість персон важливіша за повноту переліку
defect_keywords: [карт, 3–5, контракт]
source: golden persona-card сіді-кейс 2
---

# TeaTrack · Personas (predicted) — шість карт

> Карти навмисно стислі: дефект цієї фікстури — ЧИСЛО карт, і кожна інша
> перевірка рівня 0 мусить лишитись зеленою, інакше проба червоніла б з чужої
> причини. Межа розміру файлів у `references/` — 120 рядків (гейт конституції).

```yaml
persona_id: tea-001-p1
archetype: "Чайний ентузіаст-колекціонер, 25–40"
status: predicted
weight: 0.30
weight_source: "[E] r/tea опитування ніші (лінк в idea-card, 2026-05, довіра: середня)"
demographics: {age: "[E] 25–40 — самоописи в r/tea (2026-04–06, довіра: середня)", geo: "[I] US/EU"}
context:
  jtbd: "[E] «хочу пам'ятати, які заварки повторити» (r/tea, 2026-05, довіра: середня)"
behavior: {tech_savviness: "[I] висока — вже веде Notion для чаю"}
unexpected_trait: "[E] веде паперовий журнал ПОРУЧ із цифровим (r/tea, 2026-03, довіра: середня)"
anti_persona: "не колекціонер смаків: одному сорту щодня журнал непотрібен"
tracking_binding: {cohort_definition: "brew_logged ≥3/тиж", calibration_metrics: ["retention_d30"]}
open_assumptions: ["стеля ціни"]
```

```yaml
persona_id: tea-001-p2
archetype: "Початківець у листовому чаї, 20–30"
status: predicted
weight: 0.20
weight_source: "[E] beginner-тред r/tea (2026-05, довіра: середня)"
demographics: {age: "[I] 20–30 — самоописи в тому ж треді", geo: "[I] ті самі ринки"}
context:
  jtbd: "[E] «не знаю, з чого почати з листовим чаєм» (r/tea, 2026-05, довіра: середня)"
behavior: {tech_savviness: "[I] середня — приходить із коротких відео"}
unexpected_trait: "[E] питає про воду й температуру частіше, ніж про сорти (r/tea FAQ, 2026-04, довіра: середня)"
anti_persona: "не той, хто вже має усталений ритуал"
tracking_binding: {cohort_definition: "onboarding_completed + collection_size <5", calibration_metrics: ["activation_rate"]}
open_assumptions: ["вага 0.20"]
```

```yaml
persona_id: tea-001-p3
archetype: "АНТИ-ПЕРСОНА: питець пакетованого чаю"
status: predicted
weight: 0.0
weight_source: "[E] сегмент поза продуктом — validation-report (2026-06, довіра: середня)"
demographics: {age: "[I] будь-який — сегмент не сегментується за віком", geo: "[I] будь-де"}
context:
  jtbd: "[E] чай = кофеїн зранку, не хобі (опитування idea-card, 2026-05, довіра: середня)"
behavior: {price_sensitivity: "[E] $0 — не платить за хобі-інструменти (validation-report, 2026-06)"}
unexpected_trait: "[E] п'є 3+ чашки на день — обсяг не робить користувачем журналу (idea-card, 2026-05)"
anti_persona: "це і Є анти-персона: «для всіх, хто п'є чай» — червоний прапорець скоупу"
tracking_binding: {cohort_definition: "install без brew_logged за 7 днів", calibration_metrics: ["churn_d7"]}
open_assumptions: ["гео"]
```

```yaml
persona_id: tea-001-p4
archetype: "Власник чайної крамниці, 30–50"
status: predicted
weight: 0.20
weight_source: "[E] коментарі власників у тредах r/tea (2026-05, довіра: низька)"
demographics: {age: "[I] 30–50 — за описами бізнесу", geo: "[I] US/UK"}
context:
  jtbd: "[E] «веду картки сортів для персоналу» (r/tea, 2026-05, довіра: низька)"
behavior: {tech_savviness: "[I] середня — Sheets і POS"}
unexpected_trait: "[E] найбільше цінує ЕКСПОРТ, а не ведення записів (той самий тред, 2026-05)"
anti_persona: "не мережа: там уже є ERP"
tracking_binding: {cohort_definition: "export_csv ≥1/тиж", calibration_metrics: ["export_rate"]}
open_assumptions: ["вага 0.20"]
```

```yaml
persona_id: tea-001-p5
archetype: "Дегустатор-професіонал, 30–45"
status: predicted
weight: 0.10
weight_source: "[E] профільний форум TeaForum (2026-03, довіра: низька)"
demographics: {age: "[I] 30–45 — за стажем у самоописах", geo: "[I] CN/TW/EU"}
context:
  jtbd: "[E] «потрібен формат, сумісний із cupping-протоколом» (TeaForum, 2026-03, довіра: низька)"
behavior: {tech_savviness: "[I] висока — власні таблиці"}
unexpected_trait: "[E] відмовляється від оцінок у зірках — потрібна шкала протоколу (TeaForum, 2026-03)"
anti_persona: "не аматор: йому шкала протоколу заважає"
tracking_binding: {cohort_definition: "custom_scale_used", calibration_metrics: ["retention_d30"]}
open_assumptions: ["вага 0.10"]
```

```yaml
persona_id: tea-001-p6
archetype: "Дарувальник чайних наборів, 25–55"
status: predicted
weight: 0.20
weight_source: "[E] сезонний сплеск запитів «tea gift» (Google Trends, 2026-06, довіра: середня)"
demographics: {age: "[I] 25–55 — широкий, бо привід сезонний", geo: "[I] US/EU"}
context:
  jtbd: "[E] «хочу згадати, що дарував торік» (Google Trends + тред подарунків, 2026-06)"
behavior: {tech_savviness: "[I] низька — заходить двічі на рік"}
unexpected_trait: "[E] повертається САМЕ через рік, а не щотижня — сезонна когорта (Trends, 2026-06)"
anti_persona: "не постійний користувач: щотижневі метрики його не бачать"
tracking_binding: {cohort_definition: "session_gap >300 днів", calibration_metrics: ["retention_d365"]}
open_assumptions: ["вага 0.20"]
```

Шоста карта — і є дефект: контракт дозволяє 3–5.
