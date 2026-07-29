---
id: L3-build
trigger: event — G2 scope lock пройдено (та наступні цикли: зауваження reviewer'а, фікси QA)
scope: Definition→Design→Build до ready-to-ship: PRD-виконання, дизайн, код, тести, аналітика. НЕ робить: деплой у прод, публічний реліз (незворотні → G3/inbox).
maker: strw-engineer (+ strw-designer паралельно, fan-out; strw-product-manager для уточнень PRD)
checker: strw-code-reviewer (код) · strw-qa (передреліз)
stop_condition: "/goal-умова циклу: тести зелені (написані ДО коду з AC) + lint чистий + tracking events реалізовані + dep-audit чистий + security-review по diff; стадії: build-report + launch-checklist за контрактами → gate-request G3"
output: код у репо продукту (worktree) · build-report.md · launch-checklist.md
escalation: gate-request G3; блокери безпеки → finding негайно; архітектурні розвилки з ціною >дня роботи → question
budget: maker — opus; checker — ІНША модель, ніж maker (hard rule, budget-policy); ≤2 паралельні worktree на продукт; /goal-сесії групувати (1–2/день на продукт max) — **амендмент CEO 2026-07-29: на час хвоста M2 pact-001 стеля 8 циклів/добу/продукт (подвоєно з 4, decisions-log 2026-07-29); повернути 1–2 після виходу pact-001 у TestFlight (M4)**. Що НЕ рухається разом зі стелею: `≤2 паралельні worktree`, ніколи два `xcodebuild` одночасно, власний worktree + власний DerivedData на цикл. **Незалежна перевірка перед мержем — ОБОВ'ЯЗКОВА, не рекомендована** (вимір 29.07: три PR зелені по CI з десятьма мутаційними пробами, рев'ю знайшло втрату даних, тест-пустушку і дірявий контрактний пін; first-pass 0/3). Читати число разом із виміром у `budget.md` § Ліміти: рев'ю масштабується лінійно за PR, тож 8 циклів ≈ 11–13 год Mac-сесії, і справжній важіль темпу — N=2, а не саме число.
state_writes: products/<id>/state.md (кожен цикл: Done/Next/Tried & failed) · budget.md · git commit loop(L3) — **АЛЕ спершу прочитай `references/state-protocol.md` §4c: headless-сесія НЕ виконує git у `strw-state` взагалі, вона пише у `_outbox/`. Рядок вище описує сесію з робочим git на Mac.**
environment_gate: |
  Перевір середовище ПЕРЕД тим, як планувати цикл — двома командами, не припущенням:
    which xcodebuild swift    # немає → iOS-цикл у цій сесії НЕМОЖЛИВИЙ
    touch .git/.probe && rm .git/.probe   # у strw-state; немає прав → сесія headless, діє §4c
  Заплановані завдання (`strw-l3-build-continue-*`) виконуються в Linux-пісочниці без
  Xcode: там можлива лише синхронізація стану й запис у `_outbox/`, а не build-цикл.
  Перевірено 2026-07-29 07:09 — сесія дійшла до git у `strw-state` і залишила два
  застряглі локи, бо дізналась про §4c уже після падіння коміту. Гейт існує, щоб
  дізнаватись про це ДО дії, а не після.
---

# L3 · Build Loop — «/goal до зеленого»

Специфіка поверх loop-passport.md:

1. **Worktree-ізоляція:** кожна паралельна фіча — окремий worktree (`isolation: worktree`); один продукт = один репозиторій.
2. **Механіка /goal:** stop-умова формулюється верифіковано ДО старту сесії; завершення перевіряє окрема модель (нативний maker/checker split /goal), потім — strw-code-reviewer по diff.
3. **Продовження, не перезапуск:** цикл починається з state.md (Next + зауваження reviewer'а). Tried & failed — заборона повторювати тупикові підходи.
4. Дизайн-трек: strw-designer веде handoff паралельно; блокуючі залежності (нема токенів/макета) — engineer будує логіку без UI, не чекає.
5. **Tests-first:** перший крок кожного циклу — AC з PRD → падаючі тести; реалізація пишеться під тести, не навпаки. Тести+evals = контракт із агентом.
6. **Security-гейт циклу:** dep-audit + верифікація нових залежностей + security-review по diff — до передачі checker'у.
