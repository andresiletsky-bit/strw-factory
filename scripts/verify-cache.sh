#!/usr/bin/env bash
# verify-cache.sh — кеш плагіна мусить побайтово дорівнювати РЕЛІЗ-ТЕГУ своєї версії.
#
# Чому тег, а не робоче дерево (знахідка triage-inbox 2026-08-09, виміряна на v0.3.7):
# інсталяція (`claude plugin update`, source: "./") копіює робоче дерево на момент
# СВОГО запуску. Якщо дерево встигло змінитись після релізу — навіть чужими
# незакоміченими правками паралельної сесії — вони їдуть у кеш повз коміт, тег і
# рев'ю. Звірка кешу з робочим деревом цього класу НЕ бачить за побудовою: на
# момент витоку кеш і брудне дерево збігаються. Бачить тільки звірка з тегом.
#
# Usage: scripts/verify-cache.sh [X.Y.Z]   # без аргументу — версія з plugin.json
# Вихід: 0 — кеш == тег; 1 — розійшовся (поіменний перелік); 2/3 — кеш/тег відсутні.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO/.claude-plugin/plugin.json"

PV="${1:-}"
if [ -z "$PV" ]; then
  PV="$(grep -Eo '"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$MANIFEST" \
        | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
fi
[ -n "$PV" ] || { echo "verify-cache FAIL: не зміг прочитати версію з $MANIFEST"; exit 2; }

TAG="v$PV"
CACHE="$HOME/.claude/plugins/cache/strw-factory/strw-factory/$PV"
[ -d "$CACHE" ] || {
  echo "verify-cache FAIL: версії $PV немає в кеші ($CACHE)."
  echo "  claude plugin marketplace update strw-factory && claude plugin update strw-factory@strw-factory"
  exit 2
}
git -C "$REPO" rev-parse -q --verify "refs/tags/$TAG" >/dev/null || {
  echo "verify-cache FAIL: тега $TAG немає в репо — кеш $PV не має канону для звірки."
  echo "  Кеш такої версії міг постати лише повз release.sh. Розберись, звідки він."
  exit 3
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/tag"
# Не `git archive | tar -x`: код git у конвеєрі губився (pipefail без перевірки
# статусу = мовчання), а BSD tar на порожньому вході виходить 0 — виміряно
# 04.09 на macOS: `tar -x < /dev/null` → 0. Тоді порожній тег + порожній кеш
# дали б FAIL=0 = зелене. Той самий клас, що й ls нижче (чекер PR #14, р.2).
git -C "$REPO" archive "$TAG" > "$TMP/tag.tar" || { echo "verify-cache FAIL: не дістати тег $TAG (git archive впав)."; exit 2; }
tar -x -f "$TMP/tag.tar" -C "$TMP/tag" || { echo "verify-cache FAIL: не розпакувати тег $TAG."; exit 2; }

FAIL=0
# Переліки — у файл, з кодом виходу. `done < <(ls -A …)` ковтав би падіння ls:
# кеш, якого не прочитати, читався б як «порожній» → нуль розбіжностей → зелене
# (форма procsub-loop-input, strw-state/scripts/lib/nonportable-forms.tsv).
# Коди: 1 — кеш ≠ тег (FAIL нижче); 2 — міряти нема чим (версія/кеш/читання); 3 — тега немає.
# Відсутність кешу вже відсічена вище ([ -d "$CACHE" ]), тож тут ls падає лише на НЕДОСТУПНОМУ.
ls -A "$CACHE" > "$TMP/cache.list" || { echo "verify-cache FAIL: не прочитати кеш $CACHE — це не «порожньо»."; exit 2; }
ls -A "$TMP/tag" > "$TMP/tag.list" || { echo "verify-cache FAIL: не прочитати розпакований тег $TAG."; exit 2; }
# Кеш → тег: усе, що лежить у кеші, мусить бути в тегу тим самим байтом.
# Три винятки, і всі три — НЕ вміст плагіна: .DS_Store створює Finder будь-де;
# .orphaned_at ставить менеджер плагінів у витіснених версіях кешу; .in_use —
# тека з PID, яку той самий менеджер створює для версії, ЩО ЗАРАЗ У РОБОТІ.
# Один такий запис робить гейт назавжди червоним без жодного витоку правил, і
# 25.08 це виміряно ціною зупинки: перереєстрація плагіна (лік tri-021) створила
# `.in_use`, і preflight `strw-run` став віддавати STOP на КОЖНОМУ тіку, хоч
# правила побайтово збігалися з тегом.
#
# Виняток названий ПОІМЕННО, а не «усі крапкові»: `.claude-plugin/` і
# `.githooks/` — справжній вміст плагіна, і вони мусять звірятися.
while IFS= read -r e; do
  case "$e" in .DS_Store|.orphaned_at|.in_use) continue ;; esac
  if ! diff -rq "$CACHE/$e" "$TMP/tag/$e" > "$TMP/delta" 2>&1; then
    FAIL=1
    echo "verify-cache FAIL — «${e}» у кеші $PV ≠ тег $TAG:"
    sed 's/^/  /' "$TMP/delta"
  fi
done < "$TMP/cache.list"
# Тег → кеш: файл канону, який не доїхав, — теж провал, а не дрібниця.
while IFS= read -r e; do
  [ -e "$CACHE/$e" ] || { FAIL=1; echo "verify-cache FAIL — «${e}» є в тегу $TAG, але відсутній у кеші $PV."; }
done < "$TMP/tag.list"

if [ "$FAIL" = 1 ]; then
  echo ""
  echo "Кеш $PV роздає сесіям НЕ те, що ратифіковано релізом $TAG."
  echo "Лік: з чистого дерева на цьому тегу —"
  echo "  claude plugin marketplace update strw-factory && claude plugin update strw-factory@strw-factory"
  echo "  scripts/verify-cache.sh $PV"
  exit 1
fi
echo "OK: кеш $PV == тег $TAG ($(ls -A "$CACHE" | wc -l | tr -d ' ') записів звірено)"
