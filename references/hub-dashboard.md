# Dashboard хаба — числа дошки з джерел

Звідки: CEO 28.10 обрав варіант C для дошки хаба — числа (сесії, відкриті PR, тріаж, реєстр) живуть у приватному
Dashboard і генеруються з джерел; проза («що бачу», «порядок») лишається в strw-ops `reports/2026-10-20-status-board.md`.
Елемент strw-state `factory.hub-dashboard`. Загальні правила нативних типів — `references/native-outputs.md`.

**Приватний Dashboard «Дошка хаба STRW»:** https://claude.ai/artifact/WgSSb5bX1vvXWF56SspZym (створено 28.10 з типу
Dashboard через `type_url`).

## Що всередині

- Один файловий датасет `hub` — `hub.json` з `scripts/native/hub-dashboard-data.py`: масив рядків із полем `table`.
  Сторінка (`scripts/native/hub-dashboard/index.html`) ділить його через `dash.calc` на сім таблиць: `summary` (один рядок
  підсумків і пороги), `sessions`, `prs`, `repos` (п'ять репо), `triage`, `items`, `lanes`.
- Джерела: знімок `list_sessions` (файл від хаба); `gh pr list` для strw-ops, strw-factory, strw-state, pact-ios,
  pact-backend; `triage/open/*.md` і `engine/items/*.yaml` зі знімка strw-state `origin/main`.
- Один файл — бо оновлення тоді одне завантаження й один `update`, а не сім.

## Оновлення (хаб, щоразу, коли оновлює дошку)

1. `list_sessions` з `limit: 200` → весь вивід записати файлом (Write), напр. `/tmp/hub-sessions.json`. Без `limit`
   інструмент дає 20 рядків — генератор попереджає, якщо рядків рівно 20.
2. Одна команда:
   `bash ~/Developer/STRW/strw-factory/scripts/native/hub-dashboard-refresh.sh /tmp/hub-sessions.json`
   — fetch strw-state, знімок `origin/main` через `git archive` (не робоче дерево спільної копії), `gh pr list` п'яти
   репо, генератор. Друкує шлях `hub.json` і його sha256. Код 2 — відмова з причиною й без `hub.json`: дашборд не чіпати,
   причину — у тріаж або власнику джерела.
3. `Artifact` · `asset: true` · `url` дашборда · `file_path` = надрукований `hub.json`; sha256 у відповіді = надрукованому.
4. `ArtifactData` · `update` `datasets/hub` (`if_version` — з останнього читання): `source.url` (новий `/_blob/…` з
   відповіді), `source.name: hub.json`, `updated: {at: <generated_at із summary>, by: "хаб"}`.
5. `ArtifactData` · `get` `data/users/me` · `check` — `passed` (до 5 читань, поки `checking`).
6. Сторінка змінилась у git — `update` `files/index.html` її повним текстом.

## Межа

- Приватний: не ділити, не публікувати, не прикріплювати — рішення CEO (принцип 5), не сесії.
- У дашборд не йдуть `cwd` і `link` сесій; email-адреси в назвах сесій генератор маскує (`[email]`).
- Між оновленнями дашборд показує час генерації в підвалі — старі числа видно як старі. Дашборд не замінює ні реєстру,
  ні тріажу: джерело правди — git і GitHub.
