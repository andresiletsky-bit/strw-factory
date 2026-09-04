---
type: regression-report
expect: FAIL
level: 1
defect: гейт kmp поданий прозою «зелено» без коду виходу його ж check — прецедент UP-TO-DATE + exit 0 без жодного виконаного тесту
defect_keywords: [код виходу, kmp, UP-TO-DATE, зелен]
source: прецедент kmp · паспорт L8 атака 1
---

# Golden: regression-report — тижнева регресія L8 (еталон PASS)

> Еталон для калібрування strw-regression-critic і регресії validate-artifact.sh.
> Числа ілюстративні; арифметика `ran + skipped == declared` — справжня і мусить
> сходитись у будь-якому клоні цього файлу. Заведено 2026-09-04 (П1.2 аудиту).

# pact-001 · Regression Report — 20XX-WNN (Пн)

## Фаза 1 · Технічні гейти
Зі звіту `regression-phase1.sh` (прогін 20XX-NN-NN 09:14, cwd = репо продукту):
`declared: 9` · `ran: 7` · `red: 1` · `skipped: 2` · `errors: 1`
(інваріант `ran + skipped == declared`: 7 + 2 == 9 ✅ — дев'ять рядків у таблиці; `errors` — підмножина `ran`: `tracking` запускався і впав на 127; `skipped` поіменно: `human_smoke`, `dep-verify`)

| Гейт | Результат | Код виходу `check` |
|---|---|---|
| tests | 🟢 | 0 |
| lint | 🟢 | 0 |
| contract | 🔴 | 1 — контракт `POST /brew` розійшовся зі схемою |
| kmp | 🟢 зелено, тести пройшли | — |
| deps | 🟢 | 0 |
| secrets | 🟢 | 0 |
| tracking | `error:not-runnable` | 127 — `tracking-check.sh` не на PATH; «команду не запустити» ≠ «продукт не пройшов гейт» |
| dep-verify | `skipped:missing-tooling` | null — `verification-metadata.xml` у продукті відсутній |
| human_smoke | `skipped:human` | null — власник `human`, закривати заборонено (`strw-run.sh:418`) |


## Фаза 2 · Синк дизайну
Повний прогін L7: `design-hash.py --fail-on-change` rc=1 (одиниця змінилась, це не помилка) · емітер `design-emit.py` rc=0 · `unwatched`-одиниці: `pact-001/screens/Canvas` — не звірялась 6 діб (понад кеп читання). rc=3 не траплявся; якби трапився — це ЗУПИНКА фази, не «без змін».
Змінена одиниця: `pact-001/design-system/Button` — заведено `item:pact-001-ui-31`.

## Фаза 3 · UI
**НЕ ВИКОНУВАЛАСЬ.** Причина: оренди симулятора немає — паралельна сесія L3 тримає `iPhone 17 Pro` з 08:40 (перевірено `xcrun simctl list | grep Booted`). Секція заявлена явно: мовчазна відсутність читалась би як «зроблено».

## Що лишила кожна червона
- `contract` 🔴 → `finding` у `triage-inbox` (`tri-0NN`, 20XX-NN-NN) + елемент `item:pact-001-be-12`.
- `tracking` `error:not-runnable` → елемент `item:pact-001-ops-04` «поставити `tracking-check.sh` у смугу tooling». Червона без сліду зробила б звіт недійсним.

## Не встановлено
- Чи `contract`-розбіжність зачіпає вже випущений клієнт: джерело, що мало б відповісти, — телеметрія прод-версії; продукт до прод-релізу не дійшов, даних нема.
- Скільки UI-регресій пропустила невиконана фаза 3: джерело — сама фаза 3, яку не запустили.
