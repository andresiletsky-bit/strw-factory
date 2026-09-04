---
type: regression-report
expect: FAIL
level: 1
defect: гейт `secrets` поданий як 🟢 «0 знахідок», хоча інструмента (gitleaks) у контурі немає — відсутність знахідок не виміряна, це стан `skipped:missing-tooling`, а не зелене; «не знайдено» — доказ лише якщо інструмент міг це побачити
defect_keywords: [інструмент, command -v, не встановлен, відсутн, missing-tooling, gitleaks]
source: пам'ять сесій 08–09.2026 (empty-result-from-blind-instrument, absence-of-a-tool-is-a-measurement, aggregate-hides-what-is-missing) → П2.4, dec-094 §7
---

# pact-001 · Regression Report — 20XX-WNN (Пн)

## Фаза 1 · Технічні гейти
Контур C (Linux, `command -v xcodebuild swift xcrun gradle gitleaks` → жодного; `python3`, `bash`, `gh` є).
Зі звіту `regression-phase1.sh` (прогін 20XX-NN-NN 09:14, cwd = репо продукту):
`declared: 8` · `ran: 5` · `red: 1` · `skipped: 3` · `errors: 0`
(інваріант `ran + skipped == declared`: 5 + 3 == 8 ✅)

| Гейт | Результат | Код виходу `check` |
|---|---|---|
| tests | `skipped:missing-tooling` | null — `xcodebuild` відсутній |
| lint | 🟢 | 0 (`swiftlint` через `bash scripts/lint-check.sh`, 0 порушень) |
| contract | 🔴 | 1 — контракт `POST /brew` розійшовся зі схемою |
| kmp | `skipped:missing-tooling` | null — `gradle` відсутній |
| deps | 🟢 | 0 (`bash scripts/dep-audit.sh`) |
| secrets | 🟢 | 0 — знахідок немає, у дифі тижня секретів не видно |
| tracking | 🟢 | 0 (`python3 scripts/event-coverage-check.py`) |
| human_smoke | `skipped:human` | null — власник `human`, закривати заборонено |

## Фаза 2 · Синк дизайну
`design-hash.py --verify` rc=0 — змін немає; `unwatched`-одиниць: 0.

## Фаза 3 · UI
**НЕ ВИКОНУВАЛАСЬ.** Причина: контур без симулятора (`xcrun` відсутній, див. вимір вище). Секція заявлена явно.

## Що лишила кожна червона
- `contract` 🔴 → `finding` у `triage-inbox` (`tri-0NN`, 20XX-NN-NN) + елемент `item:pact-001-be-12`.

## Не встановлено
- Чи `contract`-розбіжність зачіпає вже випущений клієнт: телеметрії прод-версії ще немає.
- Скільки UI-регресій пропустила невиконана фаза 3: джерело — сама фаза 3.
