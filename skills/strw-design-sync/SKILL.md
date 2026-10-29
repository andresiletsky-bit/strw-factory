---
name: strw-design-sync
description: Звірити дизайн продукту з кодом і реєстром — дизайн-систему в Claude з закріпленою копією, канваси з хешами, версії макетів з реєстром історії. Використовувати, коли просять «синк дизайну», «звір дизайн-систему з кодом», «що змінилось у макетах», «що зараз у проді з дизайну», перед UI-задачею (dec-117 — спершу дизайн-система), або коли цього просить тижнева регресія.
---

# strw-design-sync

Пише явними кроками: копію дизайн-системи (0, PR у репо продукту), елементи реєстру (4a), базову лінію
`design/index.yaml` (5), реєстр версій `design/ledger.yaml` (7). **Порядок несучий** — причини й коди:
`references/design-sync-rationale.md`. Різниці не реалізовує (L3); протухання рахує `validate-items.sh`.

## Крок 0 · Дизайн-система — ПЕРШОЮ, до будь-якої UI-задачі (dec-117)
Одиниця `surface: ds-artifact`: `Artifact` `action: read` за її `url` → версію порівняти з `version=` в
`<репо продукту>/design-system/UPSTREAM.lock`. Інша → PR перезакріплення: файли артефакту поверх
закріплених, нові `sha256` і `version` у lock, `version` в `index.yaml`; гейт CI продукту (`ds-drift`)
скаже, де кіт розійшовся. Задачі бракує токена чи компонента → спершу допрацювати артефакт (дизайнер,
L7), опублікувати, перезакріпити; кіт — лише після. Артефакт не читається → стоп, не «без змін».

## Крок 1 · Оновити робочі файли з опублікованих канвасів
`surface: canvas-artifact`: `WebFetch` за `url` → `node <design-skill>/seed-canvas.mjs --extract <файл>
--to <порожня тека>` → `.dc.html` поверх `working_files`. Свіжий extract — перед кожним записом назад.

## Крок 2 · Схема індексу, тоді хеші
```bash
python3 strw-factory/scripts/engine/validate-design-index.py strw-state/products/<продукт>/design/index.yaml || exit 1
python3 strw-factory/scripts/engine/design-hash.py strw-state/products/<продукт>/design/index.yaml --repo-root .
```
rc: 0 без різниці · 1 різниця (`--fail-on-change`) → кроки 4–5 · 2 індекс не в формі → полагодити ·
**3 джерело нечитане → стоп, назвати одиницю; це НЕ «без змін»** · 5 (`--verify`) → кроки 4–5.

## Крок 3 · `unwatched`
Не звірялась понад build-цикл → finding: ручний експорт із claude.ai/design (`build-playbook.md §0.1`).

## Крок 4 · Пояснити різницю — ПІСЛЯ вердикту критика, ДО запису
```bash
python3 strw-factory/scripts/engine/design-emit.py --explain <звіт design-hash.py у JSON> --repo-root .
```
rc: 0 пояснено (≤5 груп) → у `design-delta` · 2 звіт не читається · 3 джерело нечитане → стоп ·
**4 потоп (>5 груп) → `question`** · **5 немає змінених одиниць → перезняти звіт кроком 2 ДО `--write`**.

## Крок 4a · Елементи реєстру — ПІСЛЯ пояснення, ДО базової лінії
```bash
python3 strw-factory/scripts/engine/design-emit.py --explain <звіт> --repo-root . --write-elements strw-state/engine/items
```
Елемент на ГРУПУ з `acceptance_basis.design_sources`; до кроку 5 чесно STALE. rc: 0 заведено/було ·
4 потоп → нічого, питання CEO · 6 смугу не вивести → `NAMESPACE_LANE` · 7 реєстр не в формі.

## Крок 5 · Базова лінія — ПІСЛЯ перегляду очима, не замість нього
`design-hash.py <index> --repo-root . --write` — лише коли макет переглянуто, `acceptance` звірено,
різницю пояснено. Ніколи «щоб було зелено». Без права запису на теку індексу — rc=2.

## Крок 6 · Повнота базової лінії (= `stop_condition` L7)
`design-hash.py <index> --repo-root . --verify`: rc=0 — у кожної `watched` є `hash` і `tokens`, файли
читаються; rc=5 — перелік того, чого бракує.

## Крок 7 · Реєстр версій макетів — після кожної прийнятої зміни
Нова версія → запис у `design/ledger.yaml` (`in-work`+`items` · `planned`+`plan_ref` · `live`+`live_evidence`);
стара → `superseded`, посилання в обидва боки; знімок — `design-archive/<id>/` репо продукту (write-once,
MANIFEST) або `git: <repo>@<sha>:<шлях>`; варіант, що програв, — `not-taken` з `return_if`. Тоді:
```bash
python3 strw-factory/scripts/engine/design-ledger.py strw-state/products/<продукт>/design/ledger.yaml --repo-root . --items strw-state/engine/items
```
rc: 0 у формі · 1 правило → полагодити запис · 2 не в формі · **3 джерело нечитане чи без `--repo-root`/`--items` → стоп** ·
4 є `snapshot_pending` → не зелено, назвати дірку. `--report` — markdown «прод · робота · план · історія».
