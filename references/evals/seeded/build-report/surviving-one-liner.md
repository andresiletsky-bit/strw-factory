---
type: build-report
expect: FAIL
level: 1
defect: у звіті немає рядка про мутацію однорядкових умов стану (правило 6b L3), тобто не доведено, що мутацію взагалі робили — тернар isPaid у csv.ts:22 лишився неперевіреним
defect_keywords: [6b, мутаці, однорядков, вижил]
source: PR #121, цикл m3.leave-tells-the-truth
---

# Golden: build-report — «TeaTrack» M1 (еталон PASS)

> Еталон для калібрування strw-code-reviewer і регресії validate-artifact.sh.
> Числа й лінки ілюстративні; дисципліна — канонічна. Заведено 2026-09-04 (П1.2
> аудиту: build-report був у `validate-artifact.sh` без жодного еталона).

# TeaTrack · Build Report — M1 (цикл 6, PR #48)

## Реалізовано vs PRD (diff scope)
| User story PRD | Стан | Де |
|---|---|---|
| US-1 створення дегустації ≤60 сек | ✅ | `src/tasting/create.ts`, `TastingForm.tsx` |
| US-2 пошук за назвою/типом | ✅ | `src/search/index.ts` |
| US-3 експорт CSV для платних | ⚠️ частково — CSV є, перевірка підписки заглушена `TODO(paywall)` | `src/export/csv.ts:31` |
Поза scope нічого не додано. Недороблене назване тут, а не в «Обмеженнях»: US-3 заявлена в PRD і не закрита.

## Тести (з AC, до коду)
- 41 тест, 41 зелений. CI: `https://github.com/<org>/teatrack/actions/runs/1180` (зелений, 2026-09-03).
- Тести US-1/US-2 закомічені окремим комітом `a41c0de` ДО реалізації (`b7712f4`) — порядок видно в `git log --oneline`.
- Краї покриті: порожня форма, offline-збереження при вимкненій мережі, дубль назви, пошук за 0 символів.

## Security
- `npm audit --audit-level=high` — 0 critical / 0 high (прогін 2026-09-03, вивід у CI-джобі `audit`).
- Нові залежності: `papaparse@5.4.1` — існує в npm-реєстрі, 12 років історії, 4.2M завантажень/тиждень; звірено побайтово проти `dep-allowlist.txt`. Галюцинованих і typosquat-імен немає.
- `gitleaks detect` — 0 знахідок. Ключ Stripe читається з env, у дифі його немає.
- security-review по дифу: валідація вводу форми на сервері (не лише в UI), CSV-експорт екранує формули (`=`,`+`,`-`,`@`) проти CSV-injection.

## Tracking plan покриття
`signup` ✅ · `tasting_created` ✅ · `search_performed` ✅ · `export_csv` ✅ · `subscribe` ⛔ (чекає закриття US-3) · `churn` ⛔ (немає підписок). Properties звірені зі схемою `tracking-plan.md`; метрика «W2 retention» покривається `signup` + `tasting_created` з `user_id`.

## Обмеження (відомі)
- PWA push на iOS не працює поза «Додати на екран» — ризик прийнятий у PRD.
- Пошук лінійний по IndexedDB; при >5 тис. записів деградує. Виміряно: 5 тис. → 380 мс.

## Deploy-checklist пройдено
`preview` на Vercel зелений · міграція БД зворотна (`down` перевірено на копії) · rollback = revert коміту + `vercel rollback` (перевірено на preview) · змінні оточення заведені в prod-проєкті.

## Code-review вердикт чекера
`VERDICT: PASS-WITH-NOTES` (strw-code-reviewer, `sonnet`, вердикт у `state.md`, формат — `references/review-policy.md`).
- [Nit] `search/index.ts:14` — назва `q2` нічого не каже.
Детермінована дія чекера: `npx vitest run src/export` (наведені maker'ом тести) + `git diff --stat origin/main...HEAD` проти переліку файлів — розбіжностей немає.
