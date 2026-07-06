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
state_writes: portfolio.md (оновлені стадії/метрики) · budget.md · git commit loop(L5)
---

# L5 · Portfolio Loop — «п'ятничний G4»

Деталі виконання — skill `strw-portfolio` (це його headless-запуск). Метрики фабрики: throughput, kill-rate, autonomy ratio, inbox lag, budget-факт, read coverage, MRR.
