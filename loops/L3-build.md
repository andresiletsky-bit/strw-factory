---
id: L3-build
trigger: event — G2 scope lock пройдено (та наступні цикли: зауваження reviewer'а, фікси QA)
scope: Definition→Design→Build до ready-to-ship: PRD-виконання, дизайн, код, тести, аналітика. НЕ робить: деплой у прод, публічний реліз (незворотні → G3/inbox).
maker: strw-engineer (+ strw-designer паралельно, fan-out; strw-product-manager для уточнень PRD)
checker: strw-code-reviewer (код) · strw-qa (передреліз)
stop_condition: "/goal-умова циклу: тести зелені (написані ДО коду з AC) + lint чистий + tracking events реалізовані + dep-audit чистий + security-review по diff; стадії: build-report + launch-checklist за контрактами → gate-request G3"
output: код у репо продукту (worktree) · build-report.md · launch-checklist.md
escalation: gate-request G3; блокери безпеки → finding негайно; архітектурні розвилки з ціною >дня роботи → question
budget: maker — opus; checker — ІНША модель, ніж maker (hard rule, budget-policy); ≤2 паралельні worktree на продукт; /goal-сесії групувати (1–2/день на продукт max)
state_writes: products/<id>/state.md (кожен цикл: Done/Next/Tried & failed) · budget.md · git commit loop(L3)
---

# L3 · Build Loop — «/goal до зеленого»

Специфіка поверх loop-passport.md:

1. **Worktree-ізоляція:** кожна паралельна фіча — окремий worktree (`isolation: worktree`); один продукт = один репозиторій.
2. **Механіка /goal:** stop-умова формулюється верифіковано ДО старту сесії; завершення перевіряє окрема модель (нативний maker/checker split /goal), потім — strw-code-reviewer по diff.
3. **Продовження, не перезапуск:** цикл починається з state.md (Next + зауваження reviewer'а). Tried & failed — заборона повторювати тупикові підходи.
4. Дизайн-трек: strw-designer веде handoff паралельно; блокуючі залежності (нема токенів/макета) — engineer будує логіку без UI, не чекає.
5. **Tests-first:** перший крок кожного циклу — AC з PRD → падаючі тести; реалізація пишеться під тести, не навпаки. Тести+evals = контракт із агентом.
6. **Security-гейт циклу:** dep-audit + верифікація нових залежностей + security-review по diff — до передачі checker'у.
