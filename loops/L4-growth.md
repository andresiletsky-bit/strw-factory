---
id: L4-growth
trigger: scheduled — щотижня для кожного продукту в проді (стадія 7–8)
scope: Тижневий маркетинг-цикл: контент, SEO, лончі, email → growth-report. НЕ робить: публікацію і платні кампанії (незворотні → inbox).
maker: strw-growth
checker: strw-brand-reviewer
stop_condition: growth-report за контрактом + чернетки контенту PASS від checker
output: growth-report.md · чернетки контенту в products/<id>/growth/
escalation: пакет «до публікації» → gate-запит в inbox (Andrii публікує або підтверджує автопублікацію каналами з білого списку); бюджетні кампанії → завжди запит
budget: maker/checker — sonnet; 1 запуск/тиждень/продукт
state_writes: products/<id>/state.md · metrics.md (маркетинг-метрики) · budget.md · git commit loop(L4)
---

# L4 · Growth Loop — «тижневий ринок»

Специфіка поверх loop-passport.md:

1. Спершу дані: минулий growth-report → подвоїти те, що працює; провальне → Tried & failed.
2. Білий список автопублікації (канали, де дозволено без підтвердження) — веде Andrii у company-context; поки порожній — все через inbox.
3. Фактичність: цифри тільки з metrics.md/PRD (перевіряє checker).
