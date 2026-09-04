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
- **Мутація однорядкових умов стану (правило 6b L3):** мутовано 4 кандидати — `?? .draft` у `TastingForm.tsx:88`, тернар `isPaid` у `csv.ts:22`, `= false` у `resetForm()`, останній `default` у редюсері. Три почервоніли. **Вижив** тернар `isPaid` (`csv.ts:22`) — заведено як знахідку Important нижче, не як примітку.

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
- [Important] `csv.ts:22` — вижилий мутант тернара `isPaid`: жоден тест не розрізняє платного й безплатного при експорті — заведено `item:tea-001-M1-08`, закрити до G3.
- [Nit] `search/index.ts:14` — назва `q2` нічого не каже.
Детермінована дія чекера: `npx vitest run src/export` (наведені maker'ом тести) + `git diff --stat origin/main...HEAD` проти переліку файлів — розбіжностей немає.

---

## Сіді-кейси (навмисні дефекти — checker МУСИТЬ зловити)
1. Прибрати секцію «Security» → FAIL рівня 0 (validate-artifact.sh).
2. Прибрати рядок про мутацію однорядкових умов із «Тестів» → FAIL checker'а: правило 6b виконує чекер, і вижилий мутант мусить бути названий; звіт без цього рядка не доводить, що мутацію взагалі робили.
3. «Реалізовано vs PRD» без згадки про заглушену US-3, при тому що `TODO(paywall)` у дифі → FAIL: diff vs PRD нечесний.
4. Заявити готовність до G3 при вердикті чекера `NEEDS_WORK`/`FAIL` у секції code-review → FAIL: зелені гейти не скасовують вердикту (F6 аудиту).
