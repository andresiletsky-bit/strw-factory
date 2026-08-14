#!/usr/bin/env bash
# strw-factory · hooks/contour-guard.sh — PreToolUse (Bash|Write|Edit|MultiEdit)
# П-3, рішення CEO 2026-08-14 (ретро W33, пропозиція 3): контур C тримає ГАРД,
# а не абзац. §4c порушено двічі (28.07 dcd6a6c; 13.08 L4 писала в канонічний
# loops-log/ і комітила з хмари) — правило текстом не тримає, тримає механізм.
#
# ЧОМУ ЦЕ ДРУГА КОПІЯ ГАРДА, І ЦЕ СВІДОМО. Центральний contour-guard.sh живе
# в strw-ops (~/Developer/STRW/.claude/hooks/) і реєструється в settings.json
# репо АБСОЛЮТНИМ Mac-шляхом — у хмарному контурі цього шляху не існує, тож
# саме в контурі, який гард має тримати, його не було (так і пройшло 13.08).
# Плагінна копія їде з кешем плагіна в будь-яку сесію, де strw-factory
# увімкнено. Дрейф двох копій — названий шов; правки git-правил синхронізувати.
#
# МЕЖА, НАЗВАНА ЧЕСНО. Гард ЛОВИТЬ у контурі C:
#   • Write/Edit/MultiEdit у канонічні файли стану:
#     loops-log/ · portfolio.md · budget.md · triage-inbox.md · decisions-log.md
#   • bash-редиректи (> >> >|), tee і sed -i у ці ж файли
#   • git-команди на запис/мережу; git-читання без --no-optional-locks
#   • виклики тулчейна (xcodebuild/swift/xcrun/gradlew/supabase/deno)
# Гард НЕ ловить: запис через perl/python/awk/mv/cp у Bash; сесії без цього
# плагіна; процеси поза Claude Code. І він ловить ЗАПИС, не намір.
#
# Умова контуру C (будь-яка з трьох):
#   не-Darwin · немає НІ xcodebuild, НІ swift · .git цілі без права запису.
set -uo pipefail
HOOK_JSON="$(cat)"

jf() { # $1 = jq-фільтр, $2 = python-вираз над d
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$HOOK_JSON" | jq -r "$1" 2>/dev/null
  else
    printf '%s' "$HOOK_JSON" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    v=$2
    print(v if v is not None else '')
except Exception:
    print('')
" 2>/dev/null
  fi
}

block() { printf 'STRW-GUARD · %s\n' "$1" >&2; exit 2; }

git_root_for() { # $1 = шлях файла або каталогу → корінь репо, якщо є
  local d="$1"; [ -d "$d" ] || d="$(dirname "$d")"
  while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do
    [ -e "$d/.git" ] && { printf '%s' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

contour_c_for() { # $1 = шлях цілі (файл для Write/Edit, PWD для Bash)
  [ "$(uname -s)" != "Darwin" ] && return 0
  if ! command -v xcodebuild >/dev/null 2>&1 && ! command -v swift >/dev/null 2>&1; then
    return 0
  fi
  local root
  if root="$(git_root_for "$1")"; then
    [ ! -w "$root/.git" ] && return 0
  fi
  return 1
}

is_canonical_path() {
  case "$1" in */loops-log/*|loops-log/*) return 0 ;; esac
  case "$(basename "$1")" in
    portfolio.md|budget.md|triage-inbox.md|decisions-log.md) return 0 ;;
  esac
  return 1
}

OUTBOX_HINT='Поклади результат у _outbox/$(date +%Y-%m-%dT%H-%M)-<loop>-<product>.md — Mac-сесія вллє його наступним заходом (state-protocol, «Контур і запис у git»).'

TOOL="$(jf '.tool_name // empty' "d.get('tool_name')")"
case "$TOOL" in
  Write|Edit|MultiEdit)
    F="$(jf '.tool_input.file_path // empty' "d.get('tool_input',{}).get('file_path')")"
    [ -n "$F" ] || exit 0
    is_canonical_path "$F" || exit 0
    contour_c_for "$F" || exit 0
    block "контур C не пише в канонічні файли стану (ціль: $F).
$OUTBOX_HINT"
    ;;

  Bash)
    CMD="$(jf '.tool_input.command // empty' "d.get('tool_input',{}).get('command')")"
    [ -n "$CMD" ] || exit 0
    contour_c_for "$PWD" || exit 0

    # ── git: правила центрального гарда strw-ops, продубльовані свідомо ──────
    GITRE='(^|[;&|(])[[:space:]]*(sudo[[:space:]]+)?git([[:space:]]|$)'
    if printf '%s' "$CMD" | grep -Eq "$GITRE"; then
      if printf '%s' "$CMD" | grep -Eq "${GITRE%\(\[\[:space:\]\]\|\$\)}[[:space:]]+([^[:space:]]+[[:space:]]+)*(add|commit|commit-tree|update-ref|update-index|write-tree|reset|checkout|switch|restore|stash|merge|rebase|cherry-pick|revert|push|pull|fetch|clone|remote|ls-remote|gc|prune|tag)([[:space:]]|$)"; then
        block "цей контур не має права запису в git і не має мережі до нього.
$OUTBOX_HINT"
      fi
      if ! printf '%s' "$CMD" | grep -q -- '--no-optional-locks'; then
        block "у цьому контурі кожна git-команда йде з --no-optional-locks: без нього git бере .git/index.lock, який пісочниця прибрати не може (вимір 05–07.08).
Так: git --no-optional-locks log --oneline -20 · git --no-optional-locks status --short"
      fi
    fi

    # ── тулчейн: у хмарі його немає, спроба лише палить токени ───────────────
    if printf '%s' "$CMD" | grep -Eq '(^|[;&|(])[[:space:]]*(\./)?(xcodebuild|swift|xcrun|gradlew|supabase|deno)([[:space:]]|$)'; then
      block "тулчейн живе тільки на Mac. Постав задачу в engine/items/ і заверши сесію звітом у _outbox/."
    fi

    # ── запис у канонічні файли через shell: > >> >| · tee · sed -i ──────────
    CANONRE='(loops-log/[^[:space:]"'"'"']*|portfolio\.md|budget\.md|triage-inbox\.md|decisions-log\.md)'
    if printf '%s' "$CMD" | grep -Eq ">[>|]?[[:space:]]*[^|;&[:space:]]*${CANONRE}"; then
      block "контур C не пише в канонічні файли стану (редирект у команді).
$OUTBOX_HINT"
    fi
    if printf '%s' "$CMD" | grep -Eq "(^|[;&|(])[[:space:]]*tee([[:space:]]+-[a-zA-Z]+)*[[:space:]]+[^|;&]*${CANONRE}"; then
      block "контур C не пише в канонічні файли стану (tee у команді).
$OUTBOX_HINT"
    fi
    if printf '%s' "$CMD" | grep -Eq "(^|[;&|(])[[:space:]]*sed[[:space:]]+[^|;&]*-i[^|;&]*${CANONRE}"; then
      block "контур C не пише в канонічні файли стану (sed -i у команді).
$OUTBOX_HINT"
    fi
    ;;
esac

exit 0
