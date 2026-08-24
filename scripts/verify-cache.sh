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
git -C "$REPO" archive "$TAG" | tar -x -C "$TMP/tag"

FAIL=0
# Кеш → тег: усе, що лежить у кеші, мусить бути в тегу тим самим байтом.
# Два винятки, обидва — НЕ вміст плагіна: .DS_Store створює Finder будь-де;
# .orphaned_at ставить сам менеджер плагінів у витіснених версіях кешу.
# Один такий файл робив би гейт назавжди червоним без жодного витоку правил.
while IFS= read -r e; do
  case "$e" in .DS_Store|.orphaned_at) continue ;; esac
  if ! diff -rq "$CACHE/$e" "$TMP/tag/$e" > "$TMP/delta" 2>&1; then
    FAIL=1
    echo "verify-cache FAIL — «${e}» у кеші $PV ≠ тег $TAG:"
    sed 's/^/  /' "$TMP/delta"
  fi
done < <(ls -A "$CACHE")
# Тег → кеш: файл канону, який не доїхав, — теж провал, а не дрібниця.
while IFS= read -r e; do
  [ -e "$CACHE/$e" ] || { FAIL=1; echo "verify-cache FAIL — «${e}» є в тегу $TAG, але відсутній у кеші $PV."; }
done < <(ls -A "$TMP/tag")

if [ "$FAIL" = 1 ]; then
  echo ""
  echo "Кеш $PV роздає сесіям НЕ те, що ратифіковано релізом $TAG."
  echo "Лік: з чистого дерева на цьому тегу —"
  echo "  claude plugin marketplace update strw-factory && claude plugin update strw-factory@strw-factory"
  echo "  scripts/verify-cache.sh $PV"
  exit 1
fi
echo "OK: кеш $PV == тег $TAG ($(ls -A "$CACHE" | wc -l | tr -d ' ') записів звірено)"
