---
name: strw-notion-sync
version: 0.1.0
description: One-way sync of STRW state (portfolio, gate log, briefs) from git to the Notion dashboard. Use when the user asks "синхронізуй Notion", "онови дашборд", "notion sync", "покажи портфель у Notion", or after portfolio/gate updates when a refresh of the human dashboard is needed.
---

# STRW Notion Sync

Односторонній sync: **git (strw-state) → Notion**. Notion — вітрина для людини; агенти НІКОЛИ не читають стан із Notion і не пишуть у git із Notion.

## Target structure (створюється при першому запуску)
Сторінка «STRW Dashboard» з трьома блоками/базами:
1. **Portfolio** — дзеркало portfolio.md (продукт, стадія, gate-статус, ICE, оновлено);
2. **Gate Log** — дзеркало decisions-log.md (останні 20);
3. **Weekly Briefs** — portfolio-brief'и як підсторінки.

## Workflow
1. Прочитай portfolio.md, decisions-log.md, останній brief.
2. Знайди «STRW Dashboard» (notion-search); нема → створи за структурою вище.
3. Онови блоки (upsert за ID продукту/датою рішення). Конфлікт «у Notion відредаговано вручну» → git виграє, але залиши коментар на сторінці про перезапис.
4. У кінці кожної синхронізованої сторінки — штамп `synced: <дата> from strw-state@<commit>`.

## Rules
- Best-effort: Notion недоступний → фабрика працює далі; запис `question` в inbox, не блокер.
- Ніяких секретів/токенів у Notion.
- Мінімум викликів API: сінк батчем, не по одному полю.
