# Loop Passport — схема паспорта петлі

Кожна петля фабрики описується файлом у `loops/` за цією схемою. `strw-loop-run` виконує петлю строго за паспортом. Петля без паспорта не запускається.

## Обов'язкові поля

```yaml
---
id: L<n>-<name>            # напр. L1-discovery
trigger: scheduled | event  # + деталі: cron-каденс або подія-тригер
scope: <що петля робить і чого НЕ робить>
maker: <агент-роль з agents/>
checker: <агент-верифікатор з agents/validators/ — ІНШИЙ промпт, ніж maker>
stop_condition: <верифікована умова завершення циклу>
output: <артефакт(и) за artifact-contracts.md + куди пишуться>
escalation: <що йде в triage-inbox і коли>
budget: <стеля запуску: модель для maker/checker, ліміт субагентів, запусків/тиждень>
state_writes: <які файли strw-state оновлює>
---
```

## Життєвий цикл виконання (інваріант для всіх петель)

1. **Read state** — company-context.md + portfolio.md + власний state продукту. Петля продовжує, не починає з нуля.
2. **Budget check** — звірити budget.md; стеля вичерпана → STOP + budget-alert в inbox.
3. **Maker phase** — виконати роботу за scope (fan-out за subagent-delegation, ≤6). Разом з артефактом maker повертає **trace**: які файли state читав, які перевірки виконав, які тули/скіли викликав, скільки ітерацій. Артефакт без trace не приймається.
4. **Checker phase** — двоетапно: (0) `scripts/validate-artifact.sh` — детермінована перевірка обов'язкових секцій, fail → одразу назад maker'у без LLM; (1) верифікатор перевіряє вихід проти рубрики (references/evals/rubrics.md) — і **output** (результат), і **trajectory** (trace проти паспорта: читав state? виконав data-integrity? не виходив за scope?). Гарний вихід із пропущеними перевірками = FAIL. Fail → maker виправляє (max 2 ітерації) → далі ескалація.
5. **Write state** — оновити state.md / portfolio.md / budget.md (факт) + **рядок у loops-log** (state-protocol: тривалість, ітерації maker↔checker, first-pass, вердикти, ескалації). Без цього кроку запуск вважається таким, що не відбувся.
6. **Escalate or archive** — знахідки/gate-запити → triage-inbox; порожній результат → тихий архів (лог один рядок). **Inbox = тільки judgment:** структурні/форматні фейли ніколи не ескалюються — їх ловить скрипт і повертає maker'у.

## Правила

- Maker і checker НІКОЛИ не одна роль/промпт.
- «Done» від maker — заява; done петлі = stop_condition, перевірена checker'ом.
- Незворотні дії (гроші, прод-деплой, публічний реліз, видалення даних) — заборонені всередині петлі; тільки запит у inbox.
- Внутрішні дані не залишають периметр (data-policy.md).
