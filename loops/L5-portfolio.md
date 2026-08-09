---
id: L5-portfolio
trigger: scheduled — щоп'ятниці (scheduled task «STRW L5+L6 Friday»)
scope: Тижневий зріз портфеля + метрики фабрики + фокуси наступного тижня → portfolio-brief. НЕ робить: gate-рішень (готує G4-кандидатів для Andrii).
maker: strw-support-analytics (збір) + логіка skill strw-portfolio (синтез)
checker: data-integrity перевірка чисел (checker-прохід за data-integrity-protocol; окремий субагент)
stop_condition: portfolio-brief за контрактом у strw-state/briefs/ + finding в inbox
output: briefs/YYYY-MM-DD-portfolio-brief.md
escalation: brief → finding; кандидати KILL/double-down → окремі gate-request G4
budget: збір — haiku/sonnet субагенти ≤6; синтез — sonnet; 1 запуск/тиждень (групується з L6)
state_writes: portfolio.md (оновлені стадії/метрики) · budget.md · рядок у loops-log/. Запис у git робить strw-run на Mac; у контурі C сесія пише в _outbox/
---

# L5 · Portfolio Loop — «п'ятничний G4»

Деталі виконання — skill `strw-portfolio` (це його headless-запуск). Метрики фабрики: throughput, kill-rate, autonomy ratio, inbox lag, budget-факт, read coverage, MRR.

## Kill-ризики R1/R2 — правило рішення (CEO 2026-08-09; пороги «жива» — PRD pact-001 §2)

З першого прод-релізу pact-001 (M4-бета) L5 щотижня рахує і пише в brief рядок R1/R2
(контракт portfolio-brief). До M4 — чесне «н/д до M4»; до порогів вибірки — числа
публікуються без вердикту, з позначкою «до правила рішення».

- **R1 (ретеншн):** частка активованих пар, що за 60-денним вікном мають ≥1
  `checkin_completed`/`revision_started`. ПІСЛЯ ≥30 активованих пар І ≥8 тижнів:
  <15% → R1 ПІДТВЕРДЖЕНО, ескалація gate-request G4 (kill-розмова); 15–25% —
  зона спостереження, окремий рядок у брифі; ≥25% — гіпотеза жива (поріг PRD).
- **R2 (WTP):** частка monthly-active пар, що платять. ПІСЛЯ ≥100 monthly-active
  пар АБО 12 тижнів: <1% → R2 ПІДТВЕРДЖЕНО, ескалація G4; 1–3.5% — перегляд
  тригерів пейволу/ціни окремим елементом реєстру; ≥3.5% — жива (поріг PRD).
