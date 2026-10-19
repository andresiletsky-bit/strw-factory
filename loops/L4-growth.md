---
id: L4-growth
trigger: scheduled — щотижня для кожного продукту в проді (стадія 7–8)
scope: Тижневий маркетинг-цикл: контент, SEO, лончі, email → growth-report. НЕ робить: публікацію і платні кампанії (незворотні → inbox). Канал черги і соцметрик — Metricool MCP (п. 4–5).
maker: strw-growth
checker: strw-brand-reviewer · шкала і формат вердикту — `references/review-policy.md`
stop_condition: growth-report за контрактом + чернетки контенту PASS від checker
output: growth-report.md · чернетки контенту в products/<id>/growth/ · ті самі чернетки в черзі Metricool у стані «на затвердження»
escalation: пакет «до публікації» → gate-запит в inbox (Andrii публікує або підтверджує автопублікацію каналами з білого списку); бюджетні кампанії → завжди запит
budget: maker — sonnet; checker — ІНША модель, ніж maker (hard rule, budget-policy); 1 запуск/тиждень/продукт · МОДЕЛІ ТУТ ПОХІДНІ — джерело strw-state/engine/lanes.yaml
state_writes: products/<id>/state.md · metrics.md (маркетинг-метрики) · budget.md · рядок у loops-log/. Запис у git робить strw-run на Mac; у контурі C сесія пише в _outbox/
---

# L4 · Growth Loop — «тижневий ринок»

Специфіка поверх loop-passport.md:

1. Спершу дані: минулий growth-report → подвоїти те, що працює; провальне → Tried & failed.
2. Білий список автопублікації (канали, де дозволено без підтвердження) — веде Andrii у company-context; поки порожній — все через inbox.
3. Фактичність: цифри тільки з metrics.md/PRD (перевіряє checker).
4. **Канал черги — Metricool MCP** (сервер `https://ai.metricool.com/mcp`; інструменти: `getBrandSettings`, `getScheduledPosts`, `getBestTimeToPostByNetwork`, `createScheduledPost`, `updateScheduledPost`, `getAnalyticsAvailableMetrics`, `getAnalyticsDataByMetrics` — інших у сервера немає, не вигадувати). **Передумова, без якої `createScheduledPost` не викликається:** у бренді ввімкнено систему затвердження Metricool (є лише на Advanced/Custom), критерій — «Everyone must approve», reviewer — Andrii; критерій «Auto-approve if no one rejects» заборонено — за ним пост публікується мовчанням. Передумову maker знімає з `getBrandSettings` і цитує у trace; інструмент її не показує або вона не підтверджена → чернетки лишаються в products/<id>/growth/, запит в inbox, у чергу Metricool нічого не йде. З підтвердженою передумовою чернетка ставиться через `createScheduledPost` ЛИШЕ у стані «на затвердження» (Send for review, не schedule); правки — `updateScheduledPost`; одразу після виклику maker читає `getScheduledPosts` і цитує стан у trace — не «pending review» → Blocker у checker. Публікує Metricool після явного «так» Andrii як reviewer; мовчання = не опубліковано (3 год грейсу — і пост зникає з черги). Черга «на затвердження» — чернетка, не публікація: білий список (п. 2) від неї не росте.
5. **Соцметрики growth-report — лише з `getAnalyticsDataByMetrics`** (перелік доступних — `getAnalyticsAvailableMetrics`). Перший крок заходу — перевірка підключення: команда `claude mcp get metricool` і її вивід дослівно у trace. Стан не «connected» (напр. «Needs authentication») → у growth-report дослівно «н/д: Metricool не підключено» і жодного числа по соцмережах. Підключено, але метрика чи період недоступні (Free — 30 днів історії; порожня або часткова відповідь) → «н/д: <причина>» дослівно з причиною і тим самим правилом: жодного числа; нуль, «≈» чи повний період замість пропуску — Blocker у checker.
6. **Хук кожної чернетки** — за `references/hook-formulas.md`; бал нижче порога — Nit (попередження) у checker, не Blocker.
