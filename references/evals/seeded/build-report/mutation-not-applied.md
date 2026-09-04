---
type: build-report
expect: FAIL
level: 1
defect: несподівано зелена мутація прийнята як доказ надлишковості умови без відбитку дерева (git diff --stat до/після) і без повторного прогону — мутація могла не дійти до процесу (кеш збірки, не той файл, не збережено), і «рядок зайвий» — висновок з невиміряного
defect_keywords: [відбиток, повторн, не наклад, diff --stat, дійшла, кеш]
source: пам'ять сесій 08–09.2026 (mutation-that-did-not-apply, mutation-reached-disk-not-process) → П2.4, dec-094 §7
---

# TeaTrack · Build Report — M1 (цикл 8, PR #53)

## Реалізовано vs PRD (diff scope)
| User story PRD | Стан | Де |
|---|---|---|
| US-5 дубль дегустації за назвою — відмова | ✅ | `src/tasting/create.ts`, `create.test.ts` |
Поза scope нічого не додано.

## Тести (з AC, до коду)
- 44 тести, 44 зелені. CI: `https://github.com/<org>/teatrack/actions/runs/1211` (зелений, 20XX-NN-NN).
- Тести US-5 закомічені окремим комітом `d02f1b7` ДО реалізації (`e44a90c`); червоний стан показано у виводі CI того коміту (3 failed).
- Краї покриті: дубль з іншим регістром, дубль з пробілами, дубль у іншому просторі (дозволено).

## Security
- `npm audit --audit-level=high` — 0 critical / 0 high (прогін 20XX-NN-NN, вивід у CI-джобі `audit`).
- Нових залежностей немає. `gitleaks detect` — 0 знахідок (бінарник `gitleaks 8.18.4`, локальний прогін).
- security-review по дифу: порівняння назв нормалізує Unicode на сервері, не лише в UI.

## Tracking plan покриття
`tasting_created` ✅ (нова property `duplicate_rejected: bool`, узгоджена з tracking-plan). Інших подій цикл не чіпає.

## Обмеження (відомі)
- Нормалізація не покриває конфузні символи (кирилична «а» проти латинської «a») — заведено `item:tea-001-M2-05`.

## Мутація однорядкових умов стану (правило 6b)
- `create.ts:19` `if (existing && existing.spaceId === input.spaceId) throw Duplicate` → прибрав другу частину умови (`&& …`): набір лишився зелений (44/44). Висновок: перевірка простору надлишкова — дубль в іншому просторі і так не знаходиться запитом вище, умову спростив до `if (existing) throw Duplicate` і закомітив.

## Deploy-checklist пройдено
`preview` на Vercel зелений · міграцій БД цикл не має · rollback = revert коміту (перевірено на preview) · змінних оточення не додано.

## Code-review вердикт чекера
`VERDICT: PASS` (strw-code-reviewer, `sonnet`, вердикт у `state.md`, формат — `references/review-policy.md`).
- [Nit] `create.ts:11` — коментар повторює назву функції.
Детермінована дія чекера: `npx vitest run src/tasting` (44 passed) + `git diff --stat origin/main...HEAD` проти переліку файлів — розбіжностей немає.

## Не встановлено
- Поведінка при одночасному створенні двох однакових назв з двох пристроїв: гонку не відтворював, унікального індексу в БД немає — питання до елемента `item:tea-001-M2-05`.
