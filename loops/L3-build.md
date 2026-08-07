---
id: L3-build
trigger: event — G2 scope lock пройдено (далі: зауваження reviewer'а, фікси QA)
scope: Definition→Design→Build до ready-to-ship. Деплой у прод і публічний реліз — незворотні, йдуть через G3.
maker: strw-engineer (+ strw-designer паралельно; strw-product-manager для уточнень PRD)
checker: strw-code-reviewer (код) · strw-qa (передреліз)
stop_condition: "усі гейти в gates.json продукту зелені — кожен своєю командою check, не оцінкою агента"
output: код у репо продукту · build-report.md · launch-checklist.md
escalation: gate-request G3; блокери безпеки → finding негайно; архітектурна розвилка ціною >дня → question
budget: maker opus · checker іншою моделлю · ≤2 worktree на продукт, ніколи два xcodebuild одночасно. Стеля циклів І умова її скасування — budget.md § Ліміти (єдине джерело). Поправка до стелі без записаної умови скасування стає постійною мовчки — саме так 29.07 подвоєння пережило свій привід.
state_writes: products/<id>/state.md · budget.md · рядок у loops-log/. Запис у git робить strw-run на Mac; у контурі C сесія пише в _outbox/.
---

# L3 · Build Loop

Специфіка поверх `loop-passport.md`. Докази, якими куплені ці правила, лежать у `decisions-log.md` за датами — тут лише сама поведінка.

## Гейти циклу

Умови зупинки живуть у `gates.json` продукту, а не в цьому тексті. Їх рахує `strw-run`, тому «гейт-блок назвав чотири умови замість шести» більше не може статися (04.08).

Вісім гейтів: `tests · lint · contract · kmp · deps · secrets · tracking · human_smoke`.

**`human_smoke` — повноцінний гейт.** Година живого користування 06.08 дала три дефекти, яких автотести не ловлять за побудовою. Коли до екрана руками не дійти — двоактовий XCTest проти живого стеку, зі `skippedTests: 0`, перевіреним через `xcresulttool` (04.08).

## Правила циклу

1. **Продовження, не перезапуск.** Цикл починається з `state.md`: Next + зауваження reviewer'а. `Tried & failed` — заборона повторювати тупикові підходи.
2. **Tests-first.** AC з PRD → падаючі тести → реалізація під них. Тести написані під готовий код контрактом не вважаються.
3. **Worktree-ізоляція.** Кожна паралельна фіча — власний worktree і власний DerivedData.
4. **Дизайн-трек паралельний.** Блокує брак токенів чи макета — engineer будує логіку без UI.
5. **Security перед checker'ом.** dep-audit, верифікація нових залежностей, security-review по diff.
6. **Мерж без незалежної перевірки — дозволений і підрахунковий.** Запис у `decisions-log.md`: «PR #N · без checker · причина · що прийнято на віру». Підстава — вимір: з ~11 циклів із чекером 10 дали REQUEST CHANGES з реальними знахідками. Мерж делеговано агенту 04.08, тож без обліку ерозія стала б невидимою.
7. **Прогрес у `portfolio.md` для стадії 5-Build — число з `engine/items/`.** Ручна оцінка розходилась із реєстром на дві позиції.
8. **Номер ADR — три листинги.** `ls` в обох `docs/adr/`, **плюс** `gh pr list --state open` → `git ls-tree --name-only <branch> docs/adr/` по кожному відкритому PR. Два цикли 04.08 незалежно взяли ADR-017, обидва виконавши старе правило правильно: номер справді був вільний на `main`, бо жоден PR не змержено.

## Зміна цього файлу доходить до сесій лише через реліз

Копія плагіна ключована версією, тож зміна без бампу лишається невидимою — 05.08 встановлена копія була датована 7 липня і не мала правил 7–11.

Після кожної зміни в `strw-factory/`, у цьому порядку:

1. підняти `version` у `.claude-plugin/plugin.json` **і** в `.claude-plugin/marketplace.json`;
2. `claude plugin marketplace update strw-factory`;
3. `claude plugin update strw-factory@strw-factory` (коротка назва без `@` дає «Plugin not found»);
4. `diff -rq ~/.claude/plugins/cache/strw-factory/strw-factory/<версія>/loops loops` має мовчати.

`strw-run` перевіряє це у preflight і відмовляється стартувати на розбіжності. Зміни діють з наступної сесії.
