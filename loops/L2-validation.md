---
id: L2-validation
trigger: event — нова картка ідеї в черзі portfolio.md (або команда Andrii)
scope: Build-or-kill дослідження однієї картки → validation-report. НЕ робить: PRD, дизайн, рішення GO/KILL (це G1, людина).
maker: strw-validation-analyst
checker: strw-validation-critic (adversarial: «чому цей звіт бреше»)
stop_condition: validation-report за контрактом, PASS від checker або зафіксована розбіжність (max 2 ітерації), gate-request у inbox
output: validation-report.md у products/<id>/ + gate-request G1 в inbox
escalation: gate-request G1 (завжди); неможливо знайти дані по ключовому полю → question
budget: maker/checker — opus; fan-out ≤6 haiku/sonnet; 3 запуски/тиждень max
state_writes: products/<id>/state.md · portfolio.md (стадія 2) · budget.md · git commit loop(L2)
---

# L2 · Validation Loop — «скептик за викликом»

Специфіка поверх loop-passport.md:

1. **Data Integrity Gate обов'язковий** — checker проганяє повний чекліст data-integrity-protocol.md.
2. Debate вбудований: розділ critic-review у звіті — заперечення checker'а і відповіді maker'а. Нерозв'язане — в центр G1.
3. Найдешевший шлях перевірки гіпотези — обов'язкове поле: G1 з опцією «перевірити за $X перед full build».
