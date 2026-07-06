---
id: L6-retro
trigger: scheduled — щоп'ятниці, одразу після L5 (той самий headless-запуск, групування бюджету)
scope: Аналіз тижня фабрики → патерни помилок → пропозиції мінімальних покращень процесу. НЕ робить: змін без дозволу Andrii.
maker: логіка skill strw-retro (майнінг логів + патерни)
checker: Andrii (пропозиції застосовуються тільки з явного дозволу — людина і є checker цієї петлі)
stop_condition: 0–3 пропозиції покращень у inbox АБО чесне «патернів не знайдено»
output: retro-note в briefs/ + пропозиції як question-записи в inbox
escalation: усі пропозиції; health flags (read coverage↓, autonomy<50%, surrender-патерн, бюджет у стелю) → окремим finding
budget: haiku для майнінгу логів; sonnet для синтезу; 1 запуск/тиждень
state_writes: process-changelog.md (тільки після прийняття) · budget.md · git commit loop(L6)
---

# L6 · Retro Loop — «фабрика вчить себе»

Деталі виконання — skill `strw-retro` (це його headless-запуск). Це петля, що робить процес компаундним: без неї фабрика статична.
