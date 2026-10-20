# Режими A/B — як елемент реєстру стає «без людини»

Джерело: strw-ops `reports/2026-10-20-hybrid-autonomy-spec.md` (рішення CEO 20.10: «варіант А і В … за фазою
продукту і складністю задач; для А — детальна проробка специфікацій, планів, критеріїв і тестів; захист від
незворотного і грошей»). Тут — лише те, що треба знати, щоб заповнити елемент і прочитати відповідь скрипта.
Правило в паспорті — L3 №11.

**A — без людини:** будильник → `strw-run.sh` зі `STRW_UNATTENDED=1`, мерж робить раннер за умовами §4a спеки.
**B — з CEO:** сесія на Mac, будь-який елемент. Режим — властивість **елемента**, не сесії.

## Поля елемента

| Поле | Форма | Коли обов'язкове |
|---|---|---|
| `autonomy` | `unattended` \| `with-ceo`; поля немає = `with-ceo` | — |
| `touches` | список із `money · release · prod · data-deletion · third-party-data · privacy-behavior · milestone-scope`; невідоме значення — ERROR | — (порожній = нічого з принципу 5) |
| `tests_spec` | непорожній список `{name, red_when, negative_control}`: назва тесту до коду · що робить його червоним зараз · на якій підробці він мусить упасти | `unattended` |
| `plan_review` | `{verdict: PASS, by: <модель>, at: <дата>, sha: <версія плану>}`; шкала вердикту — `review-policy.md` | `unattended` |
| `budget` | `{max_cycles: ціле > 0, max_hours: число > 0}` | `unattended` |
| `acceptance`, `not_in_scope`, `plan` | як для L3 №10 (`plan`: `files · order · risks`/`risks_none_because` · `proof`) | `unattended` — **і для S теж** |

`plan_review.sha` — версія **поточного** плану: `bash scripts/engine/autonomy-route.sh --plan-sha <елемент>`
(sha256 канонічного JSON `plan`, ключі відсортовані; коментарі й порядок ключів у YAML версію не міняють).
Змінили план після рев'ю — хеш розійшовся, і елемент знову потребує вердикту по плану.

Форму тримає `scripts/engine/validate-items.sh` (ERROR реєстру): невідоме `touches`/`autonomy`, покручені поля,
а для `autonomy: unattended` — кожна прогалина готовності окремим рядком. Код форми і готовності один —
`scripts/engine/lib/item_fields.py`; свіжість підстави — `lib/decisions_basis.py`. Обидва читачі (валідатор і
маршрут) імпортують їх, тож розійтися в слові «готово» чи «STALE» вони не можуть.

## Маршрут: `scripts/engine/autonomy-route.sh <елемент> [--engine-dir D] [--state-dir S]`

Рівно один рядок у stdout:

- `unattended` — rc 0;
- `with-ceo: <причина>` — rc 1, причина — перша невиконана умова простими словами;
- `не поміряно: <що>` — rc 2: немає файла, читача (`lib/` неповна), стадії продукту, журналу рішень чи
  `triage/open/`. Це не «B», а сліпий інструмент: раннер зупиняється, а не гадає.

Умови перевіряються в такому порядку (перша невиконана = причина):

1. `autonomy: unattended` заявлено (без позначки — B; `with-ceo` — B вручну, завжди поважається).
2. Поля режиму мають правильну форму (покручене поле не читається як порожнє).
3. Стадія продукту — `5-build` у frontmatter `products/<id>/state.md`; `product: factory` — без стадії.
4. `size` — `S` або `M` (`L` — завжди B).
5. `touches` порожній.
6. `blocked_by` порожній (першим називається `ceo:*`).
7. Жодна картка в `triage/open/` не називає id елемента (межа слова: `x` ≠ `x-two`).
8. `acceptance_basis` звірено з журналом і не STALE (той самий вимір, що у валідаторі).
9. Готовність до A: `acceptance` · `not_in_scope` · `plan` · `tests_spec` · `plan_review` з `PASS` і `sha`
   поточного плану · `budget`.
10. Не «великий» за L3 6a — за `plan.files`: контракт (`contract/`), міграції (`migrations/`), крипто й ключі
    (`crypto`, `keychain`, `key-exchange`, `space-key`, `secret`), вимірювальний інструмент (`*-check.sh`,
    `*-guard.sh`, `validate-*`, `gates*.json`, `dep-allowlist.txt`, `autonomy-route.sh`, `strw-run.sh`,
    `.claude/hooks/`, `hooks/`, `.githooks/`, `.github/workflows/`, `scripts/engine/lib/`,
    `.claude/settings*.json`), понад 15 файлів; маска чи тека в `plan.files` — теж B (під маскою нічого
    не видно, а `plan_drift` раннера розгорне її на будь-що).

## Що скрипт НЕ міряє — і де це стережеться

- **~400 рядків дифу** — з плану не видно. Стереже чекер 6a і мерж-умова «великий» на дифі.
- **Залежність `sends-user-data`** і **закриття віхи** — у `touches` (`third-party-data`, `milestone-scope`);
  забуте значення скрипт не вгадає — його ловить чекер плану.
- **Дрейф від плану по ходу** — `plan_drift` раннера (> 0 файлів поза `plan.files` → стоп і B) і повторний
  виклик маршруту на момент мержу (§4a умова 4).
- Заборонені дії в A (гроші, незворотне, знищення, рішення CEO, запис у спільну копію) — хук
  `unattended-guard.sh` у strw-ops, не цей скрипт.

## Тести

`scripts/engine/autonomy-route.test.sh` — на кожну умову червоний випадок і близнюк, rc 2 на кожен сліпий
вхід, контракт «один рядок + код» на кожному виході; валідаторна частина — та сама форма через
`validate-items.sh`. Хто їх ганяє: strw-ops `tests/unit/autonomy-route.test.sh` (нічний прогін `tests/run.sh`) —
сам strw-factory тестів рушія не запускає ні в pre-commit, ні в `release.sh`.
