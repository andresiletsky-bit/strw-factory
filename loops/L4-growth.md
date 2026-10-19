---
id: L4-growth
trigger: scheduled — щотижня для кожного продукту в проді (стадія 7–8)
scope: Тижневий маркетинг-цикл: контент, SEO, лончі, email → growth-report. НЕ робить: публікацію і платні кампанії (незворотні → inbox). Канал черги і соцметрик — Metricool MCP (п. 4–5).
maker: strw-growth
checker: strw-brand-reviewer · шкала і формат вердикту — `references/review-policy.md`
stop_condition: growth-report за контрактом + чернетки контенту PASS від checker
output: growth-report.md · чернетки контенту в products/<id>/growth/ · ті самі чернетки в черзі Metricool у стані «на затвердження» (через `createScheduledPostForReview`) — лише за передумовою п. 4a; без неї черга порожня і це не FAIL
escalation: пакет «до публікації» → gate-запит в inbox (Andrii публікує або підтверджує автопублікацію каналами з білого списку); бюджетні кампанії → завжди запит
budget: maker — sonnet; checker — ІНША модель, ніж maker (hard rule, budget-policy); 1 запуск/тиждень/продукт · МОДЕЛІ ТУТ ПОХІДНІ — джерело strw-state/engine/lanes.yaml
state_writes: products/<id>/state.md · metrics.md (маркетинг-метрики) · budget.md · рядок у loops-log/. Запис у git робить strw-run на Mac; у контурі C сесія пише в _outbox/
---

# L4 · Growth Loop — «тижневий ринок»

Специфіка поверх loop-passport.md:

1. Спершу дані: минулий growth-report → подвоїти те, що працює; провальне → Tried & failed.
2. Білий список автопублікації (канали, де дозволено без підтвердження) — веде Andrii у company-context; поки порожній — все через inbox.
3. Фактичність: цифри тільки з metrics.md/PRD (перевіряє checker).
4. **Канал черги — Metricool MCP** (сервер `https://ai.metricool.com/mcp`; дев'ять інструментів, виміряно 19.10: `getBrandSettings`, `getScheduledPosts`, `getBestTimeToPostByNetwork`, `getAnalyticsAvailableMetrics`, `getAnalyticsDataByMetrics`, `createScheduledPost`, `updateScheduledPost`, `createScheduledPostForReview`, `sendScheduledPostForReview` — інших у сервера немає, не вигадувати).
   - 4a. **Передумова — параметри виклику, не налаштування бренду** (`getBrandSettings` затвердження не показує, виміряно 19.10). Новий пост іде ЛИШЕ через `createScheduledPostForReview` з `approvalSystem: "all"` (everyone must approve) і `reviewers` = email Andrii з company-context; `"optional"` (auto-approve if no one rejects) і `"any"` заборонено — за ними пост публікується без Andrii. Email у company-context немає, або інструмент відповів «plan does not allow» (система затвердження є лише на тарифі з team management) → відповідь цитується в trace без повтору, чернетки лишаються в products/<id>/growth/, запит в inbox, у чергу Metricool нічого не йде: `createScheduledPost` не викликається.
   - 4b. **Виклик.** `createScheduledPost` — прямий розклад без людини, у L4 заборонений завжди. Правка чернетки — `updateScheduledPost` — скидає review (довідка Metricool, approval system: після правки пост треба надіслати на затвердження знову), тому кожен `updateScheduledPost` несе в `info` `autoPublish: false` (схема: Metricool тоді не публікує сам, а шле push у мобільний застосунок — публікує людина), і одразу після нього — `sendScheduledPostForReview` з тими самими `approvalSystem: "all"` і `reviewers` = email Andrii (id поста змінюється після кожного виклику — брати з відповіді або з `getScheduledPosts`). Після КОЖНОГО виклику maker читає `getScheduledPosts` і цитує відповідь і стан у trace: пост має бути «на затвердження» (pending review); поле стану у відповіді схемою не обіцяне (виміряно 19.10) — доки воно не доведене живим постом, доказом є відповідь ForReview-інструмента з `plannerUrl`, і це названо в trace як «поле стану не встановлено».
   - 4c. **Стан не «pending review»** (якщо поле є) після будь-якого виклику, пост відсутній у `getScheduledPosts`, або ForReview-інструмент відповів помилкою (наприклад тариф без team management) → той самий виклик НЕ повторюється (схема: «returns an error you must relay without retrying»); відповідь цитується в trace, термінова картка в inbox із часом публікації поста (інструмента видалення в MCP немає); пост не може вийти сам, бо `autoPublish: false` стоїть у кожному `updateScheduledPost` — maker це цитує; без цього — Blocker у checker. Публікує Metricool після явного «так» Andrii як reviewer; мовчання = не опубліковано (довідка Metricool, approval system FAQ: 3 год грейсу, пост лишається незатвердженим). Черга «на затвердження» — чернетка, не публікація: білий список (п. 2) від неї не росте.
5. **Соцметрики growth-report — лише з `getAnalyticsDataByMetrics`** (перелік доступних — `getAnalyticsAvailableMetrics`). Перший крок заходу — перевірка підключення: команда `claude mcp get metricool` і її вивід дослівно у trace. Стан не «connected» (наприклад «Needs authentication») → у growth-report дослівно «н/д: Metricool не підключено» і жодного числа по соцмережах. Підключено, але метрика чи період недоступні (Free — 30 днів історії; порожня або часткова відповідь) → «н/д: <причина>» дослівно з причиною і тим самим правилом: жодного числа; нуль, «≈» чи повний період замість пропуску — Blocker у checker.
6. **Хук кожної чернетки** — за `references/hook-formulas.md`; бал нижче порога — Nit (попередження) у checker, не Blocker.
