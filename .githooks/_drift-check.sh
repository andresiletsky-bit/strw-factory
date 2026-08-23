#!/usr/bin/env bash
# Спільне тіло перевірки дрейфу паспортів для pre-commit і pre-merge-commit.
#
# Матеріалізує ПОВНУ теку паспортів такою, якою вона стане після коміта:
# staged-версія для зачеплених файлів, HEAD-версія для решти. Підмножина не
# годиться — рев-ю 6b, H1: перша редакція клала в теку лише зачеплені файли, і
# коміт, що не чіпав L3-build.md, отримував rc=3 («перевірити нічим»), який
# `check … 0` читав як провал. Тобто хук блокував КОЖНУ правку будь-якого
# іншого паспорта.
#
# Чому це важче за звичайний хибно-червоний: правило 6a того самого паспорта
# каже, що правило, яке блокує через зовнішню обставину, «почнуть обходити, а
# звичний обхід гірший за відсутнє правило». Такий хук робить --no-verify
# штатним способом редагувати паспорти — тобто він гірший за відсутній.
#
# Друга причина брати ПОВНУ теку: сусідні перевірки (стеля в budget.md,
# обізнаність диспетчера) на підмножині мовчки звужували б покриття до
# зачеплених файлів — не червоне, просто менше перевірено, ніж написано.
set -uo pipefail

git diff --cached --name-only --diff-filter=ACMR -- 'loops/*.md' | grep -q . || exit 0

DRIFT="${STRW_ROOT:-$HOME/Developer/STRW}/tests/integration/docs-current.test.sh"
if [ ! -f "$DRIFT" ]; then
  echo "FAIL: немає $DRIFT — перевірка дрейфу паспортів недоступна,"
  echo "  а коміт чіпає loops/. Понови strw-ops або постав STRW_ROOT."
  exit 1
fi

STAGED="$(mktemp -d)"
trap 'rm -rf "$STAGED"' EXIT

# Спершу HEAD-версія всіх паспортів, потім staged поверх зачеплених.
git ls-tree --name-only HEAD -- loops/ 2>/dev/null | while IFS= read -r f; do
  case "$f" in *.md) git show "HEAD:$f" > "$STAGED/$(basename "$f")" 2>/dev/null ;; esac
done
git diff --cached --name-only --diff-filter=ACMR -- 'loops/*.md' | while IFS= read -r f; do
  git show ":$f" > "$STAGED/$(basename "$f")" 2>/dev/null
done
# Видалені паспорти прибираємо з матеріалізованої теки — інакше перевірка
# бачила б файл, якого після коміта не буде.
git diff --cached --name-only --diff-filter=D -- 'loops/*.md' | while IFS= read -r f; do
  rm -f "$STAGED/$(basename "$f")"
done

STRW_LOOPS_DIR="$STAGED" bash "$DRIFT" >/dev/null 2>&1 || {
  echo "FAIL: перевірка дрейфу в strw-ops впала."
  echo "  Причина НЕ обовʼязково в паспорті — той самий набір стереже й інші"
  echo "  речі. Прожени й подивись, що саме:"
  echo "  STRW_LOOPS_DIR=<staged> bash $DRIFT"
  exit 1
}
