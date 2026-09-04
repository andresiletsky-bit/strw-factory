---
type: build-report
expect: FAIL
level: 1
defect: тести написані після коду й зелені з першого прогону — жодного червоного стану не показано, тобто не доведено, що набір уміє почервоніти саме на цій поведінці (tests-first порушено, негативного контролю немає)
defect_keywords: [червон, негативн, з першого, після коду, tests-first, не доведено]
source: пам'ять сесій 07–08.2026 (tests-that-pass-wrong-reason, negative-control-before-claiming-proof) → П2.4, dec-094 §7
---

# TeaTrack · Build Report — M1 (цикл 7, PR #51)

## Реалізовано vs PRD (diff scope)
| User story PRD | Стан | Де |
|---|---|---|
| US-4 нагадування про дегустацію | ✅ | `src/reminders/schedule.ts`, `ReminderSheet.tsx` |
Поза scope нічого не додано.

## Тести (з AC, до коду)
- 18 тестів, 18 зелених. CI: `https://github.com/<org>/teatrack/actions/runs/1203` (зелений, 20XX-NN-NN).
- Тести дописано після реалізації в тому ж коміті `c91e2aa`; при першому прогоні всі 18 зелені, правок у код не знадобилось.
- Краї покриті: нагадування в минулому, два нагадування на одну дегустацію, вимкнені сповіщення.

## Security
- `npm audit --audit-level=high` — 0 critical / 0 high (прогін 20XX-NN-NN, вивід у CI-джобі `audit`).
- Нових залежностей немає. `gitleaks detect` — 0 знахідок (бінарник `gitleaks 8.18.4`, локальний прогін).
- security-review по дифу: час нагадування валідується на сервері; у payload сповіщення немає тексту дегустації.

## Tracking plan покриття
`reminder_scheduled` ✅ · `reminder_fired` ✅ · `reminder_dismissed` ✅. Properties звірені зі схемою `tracking-plan.md`.

## Обмеження (відомі)
- Нагадування не переживають переустановку застосунку — за PRD M1 це прийнятно, елемент `item:tea-001-M2-03` заведено.

## Мутація однорядкових умов стану (правило 6b)
- `schedule.ts:27` `if (when < now) return skip` → замінив на `if (false)`: 2 тести червоні (`past-date`, `past-date-timezone`). Мутант убитий.

## Deploy-checklist пройдено
`preview` на Vercel зелений · міграцій БД цикл не має · rollback = revert коміту (перевірено на preview) · змінних оточення не додано.

## Code-review вердикт чекера
`VERDICT: PASS` (strw-code-reviewer, `sonnet`, вердикт у `state.md`, формат — `references/review-policy.md`).
- [Nit] `schedule.ts:40` — назва `tmp2` нічого не каже.
Детермінована дія чекера: `npx vitest run src/reminders` (18 passed) + `git diff --stat origin/main...HEAD` проти переліку файлів — розбіжностей немає.

## Не встановлено
- Чи доходять сповіщення на iOS у фоні: потрібен пристрій, симулятор фонові пуші не доставляє.
