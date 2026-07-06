---
id: L1-discovery
trigger: scheduled — Пн/Ср/Пт ранок (scheduled task «STRW L1 Discovery»)
scope: Пошук кандидатів у продукти (тренди, болі, прогалини конкурентів). НЕ робить: валідацію, оцінку TAM, рішення про build.
maker: strw-discovery
checker: strw-validation-critic (режим: дедуп + ДНК-фільтр + мінімум сигналів)
stop_condition: 0–3 картки ідей пройшли checker АБО чесний порожній результат
output: idea-card.md (контракт) у products/<id>/ + рядок portfolio.md (черга ідей)
escalation: нові картки → finding в inbox; ≥3 тижні поспіль порожньо → question «розширити джерела?»
budget: maker — sonnet; скани — haiku-субагенти ≤4; 3 запуски/тиждень max
state_writes: portfolio.md (черга) · budget.md (факт) · git commit loop(L1)
---

# L1 · Discovery Loop — «ранкова розвідка»

Виконується через strw-loop-run за загальним життєвим циклом (loop-passport.md). Специфіка:

1. **Джерела за пріоритетом:** Knowledge Library (якщо є свіже) → web-тренди/форуми → маркетплейси → прогалини конкурентів наявних продуктів портфеля.
2. **Ротація фокусу:** кожен запуск — інший кут (Пн: болі/спільноти; Ср: тренди/ринки; Пт: конкуренти/ніші), щоб не збирати одне й те саме.
3. Порожній результат — нормальний: тихий архів, один рядок логу.
