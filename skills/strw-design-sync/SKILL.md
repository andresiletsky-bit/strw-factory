---
name: strw-design-sync
description: Звірити дизайн-одиниці продукту з реєстром — витягти канваси, порахувати хеші, показати різницю. Використовувати, коли просять «синк дизайну», «що змінилось у макетах», «звір дизайн із кодом», або коли цього просить тижнева регресія.
---

# strw-design-sync

Виявлення, пояснення і заведення. Пише у ДВА місця, обидва явним кроком: елементи реєстру
(`engine/items/`, крок 4a) і базову лінію (`hash` + `tokens` у `design/index.yaml`, крок 5).
**Порядок кроків несучий** — чому саме такий, з кодами виходу і купленими причинами:
`references/design-sync-rationale.md`. Тут — лише що робити. Скіл не править макетів і не реалізовує
різниці (це L3); протухання рахує `validate-items.sh`.

## Крок 1 · Оновити робочі файли з опублікованих канвасів
Для кожної одиниці з `surface: canvas-artifact` у `index.yaml`: `WebFetch` за її `url` →
`node <design-skill>/seed-canvas.mjs --extract <збережений файл> --to <порожня тека>` → скопіювати
витягнуті `.dc.html` поверх `working_files`. Свіжий extract — безпосередньо перед будь-яким записом
назад (збереження канвасу — compare-and-set).

## Крок 2 · Схема індексу, тоді хеші
```bash
python3 strw-factory/scripts/engine/validate-design-index.py strw-state/products/<продукт>/design/index.yaml || exit 1
python3 strw-factory/scripts/engine/design-hash.py strw-state/products/<продукт>/design/index.yaml --repo-root .
```
rc: 0 без різниці · 1 різниця (під `--fail-on-change`) → кроки 4–5 · 2 індекс не в формі → полагодити ·
**3 джерело нечитане → зупинитись і назвати одиницю; це НЕ «без змін»** · 5 (`--verify`) → кроки 4–5.

## Крок 3 · Одиниці `unwatched`
Не звірялась понад один build-цикл → finding з єдиною дією: ручний експорт із claude.ai/design
(`build-playbook.md §0.1`); після нього одиниця стає `watched`.

## Крок 4 · Пояснити різницю — ПІСЛЯ вердикту критика, ДО запису
```bash
python3 strw-factory/scripts/engine/design-emit.py --explain <звіт design-hash.py у JSON> --repo-root .
```
Емітер бере шляхи й сигнатури ЗІ ЗВІТУ; спільна причина — лише токен форми дизайн-токена, присутній у
різниці КОЖНОЇ зміненої одиниці; решта лишається окремою групою з `unexplained_tokens`.
rc: 0 пояснено (непояснених груп ≤5) → у `design-delta` · 2 звіт не читається · 3 джерело нечитане →
зупинитись · **4 потоп (>5 груп) → ескалація `question`** · **5 у звіті немає змінених одиниць → не
«чисто», перезняти звіт кроком 2 ДО `--write`**.

## Крок 4a · Завести елементи реєстру — ПІСЛЯ пояснення, ДО базової лінії
```bash
python3 strw-factory/scripts/engine/design-emit.py --explain <звіт> --repo-root . --write-elements strw-state/engine/items
```
Один елемент на ГРУПУ; кожен несе `acceptance_basis.design_sources` (`ref`, `hash`, `verified_at`) —
підставу протухання для `validate-items.sh`. До кроку 5 елемент чесно показується STALE — «зміну ще не
прийнято». Заведених елементів емітер не редагує.
rc: 0 заведено/уже було · 4 потоп → елементів не заведено, діф іде питанням до CEO · 6 смугу не
вивести → дописати `NAMESPACE_LANE` · 7 реєстр не в формі → полагодити шлях.

## Крок 5 · Оновити базову лінію — ПІСЛЯ перегляду очима, не замість нього
```bash
python3 strw-factory/scripts/engine/design-hash.py strw-state/products/<продукт>/design/index.yaml --repo-root . --write
```
Лише коли макет переглянуто, `acceptance` залежних елементів звірено, різницю пояснено кроком 4.
Ніколи «щоб було зелено»: це стирає єдиний доказ зміни. Без права запису на теку індексу — rc=2.

## Крок 6 · Повнота базової лінії (= `stop_condition` L7)
```bash
python3 strw-factory/scripts/engine/design-hash.py strw-state/products/<продукт>/design/index.yaml --repo-root . --verify
```
rc=0 — у кожної `watched`-одиниці є `hash` і `tokens`, файли читаються, розбіжностей немає; rc=5 —
перелік того, чого бракує.
