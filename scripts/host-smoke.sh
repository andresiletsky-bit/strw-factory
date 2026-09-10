#!/usr/bin/env bash
# host-smoke.sh — чи вантажиться плагін в ОБОХ хостах (Claude Code і Codex CLI),
# перш ніж його випустити.
#
# ЧОМУ ЦЕ ІСНУЄ. Статичні перевірки (`claude plugin validate`, evals) — потрібні,
# але недостатні: маніфест може бути валідний, а хост — не побачити жодного скіла.
# Виміряно 09.09.2026 на Grow PM (плагін CEO, той самий формат): об'єктна форма
# `source` у marketplace.json — маркетплейс додається, плагінів 0, помилки нема.
# strw-factory має рядкову форму `"./"` — тому й вантажиться в Codex без правок
# (8/8 скілів, 09.09). Але це ФАКТ на сьогодні, не властивість: одна правка
# маніфесту — і плагін тихо зникне з одного з хостів. Гейт тримає властивість.
#
# ЩО МІРЯЄТЬСЯ (без жодного виклику моделі — безкоштовно і без авторизації):
#   Claude — `claude plugin validate <тека>` мусить сказати «Validation passed».
#   Codex  — плагін ставиться з ОКРЕМОГО CODEX_HOME у tmp (конфіг користувача
#            не чіпається), і `codex debug prompt-input` — модельно-видимий промт —
#            мусить перелічити РІВНО стільки скілів `<plugin>:<skill>`, скільки тек
#            `skills/*/SKILL.md` на диску. Менше — скіл випав; більше — чужий.
#   Codex НЕ вантажить `agents/*.md` і `hooks/hooks.json` з плагіна (виміряно
#   09.09: 0 згадок, 14 агентів); це ВІДОМА межа хоста, гейт її називає рядком,
#   не червонить (див. tri-096 — рішення про Codex як хост ще за CEO).
#
# ПРЕДМЕТ — те, що ЇДЕ В РЕЛІЗ: `git archive HEAD` (staged-і-закомічене), не
# робоче дерево. `--tree` міряє робоче дерево (для проби ДО коміту і для фікстур
# без git).
#
# Контракт виходу:
#   0 — зелено (кожен доступний хост вантажить плагін)
#   1 — червоно (хост доступний і НЕ вантажить; або сам плагін не зібрано)
#   2 — не поміряно: хост відсутній у PATH — названо, не пропущено мовчки
#       (release.sh читає 2 як гучне WARN, 1 — як відмову)
# Ніколи не висне: кожен виклик хоста під perl alarm (timeout на macOS немає).
#
# Оточення: HOST_SMOKE_SKIP_CLAUDE=1 / HOST_SMOKE_SKIP_CODEX=1 (свідомо, названо у
# виводі); CLAUDE_BIN, CODEX_BIN (підмінювані для проб); HOST_SMOKE_TIMEOUT (с, 120).
set -uo pipefail

MODE="head"
PLUGIN_DIR=""
for a in "$@"; do
  case "$a" in
    --tree) MODE="tree" ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) PLUGIN_DIR="$a" ;;
  esac
done
[ -n "$PLUGIN_DIR" ] || PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARG_DIR="$PLUGIN_DIR"
PLUGIN_DIR="$(cd "$ARG_DIR" 2>/dev/null && pwd)" || { echo "FAIL: теки плагіна немає: $ARG_DIR"; exit 1; }

TIMEOUT="${HOST_SMOKE_TIMEOUT:-120}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CODEX_BIN="${CODEX_BIN:-codex}"
RC=0; UNMEASURED=0
fail() { echo "FAIL: $*"; RC=1; }
ok()   { echo "ok:   $*"; }
note() { echo "note: $*"; }
skip() { echo "SKIP: $*"; UNMEASURED=1; }

# Виклик під будильником; вивід — у файл (підстановка $(…) чекала б EOF пайпа
# осиротілого нащадка — урок bin/codex-probe.sh 14.08). Повертає rc команди.
alarm_run() { # alarm_run <out-file> <cmd...>
  local out="$1"; shift
  perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$@" >"$out" 2>&1 </dev/null
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ----- знімок: ОДИН предмет для всіх перевірок ------------------------------
# HEAD-режим міряє git archive HEAD (те, що їде в реліз), --tree — робоче дерево;
# і маніфести, і лічба скілів, і обидва хости читають той самий знімок STAGE —
# інакше незакомічений скіл у дереві червонив би здоровий HEAD, а видалений
# локально зламаний скіл ховав би свою відсутність у промті Codex (codex review
# 10.09, P2). Знімок робиться ДО будь-якого виміру.
SRC_DIR="$PLUGIN_DIR"; STAGE="$TMP/stage"; mkdir -p "$STAGE"
if [ "$MODE" = head ] && git -C "$SRC_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
  git -C "$SRC_DIR" archive HEAD | tar -x -C "$STAGE" || { echo "FAIL: git archive HEAD не розпакувався"; echo "host-smoke: ❌"; exit 1; }
  SNAPSHOT="git archive HEAD (те, що їде в реліз; --tree міряє робоче дерево)"
else
  (cd "$SRC_DIR" && tar -cf - --exclude .git .) | tar -xf - -C "$STAGE" || { echo "FAIL: копія дерева не вдалась"; echo "host-smoke: ❌"; exit 1; }
  SNAPSHOT="робоче дерево"
fi
PLUGIN_DIR="$STAGE"
echo "note: предмет — $SNAPSHOT ($SRC_DIR)"

# ----- 0) сам плагін: маніфести читаються, скіли на диску полічені -----------
MANIFEST="$PLUGIN_DIR/.claude-plugin/plugin.json"
MARKET="$PLUGIN_DIR/.claude-plugin/marketplace.json"
[ -f "$MANIFEST" ] || { fail "немає $MANIFEST"; echo "host-smoke: ❌"; exit 1; }
[ -f "$MARKET" ]   || { fail "немає $MARKET — Codex ставить плагін лише через маркетплейс"; echo "host-smoke: ❌"; exit 1; }
python3 - "$MANIFEST" "$MARKET" > "$TMP/meta" <<'PY'
import json, sys
try:
    m = json.load(open(sys.argv[1]))
    k = json.load(open(sys.argv[2]))
except Exception as e:
    print("ERR " + str(e).replace("\n", " ")); sys.exit(0)
name = m.get("name", "")
mkt = k.get("name", "")
plugs = k.get("plugins", [])
src = next((p.get("source") for p in plugs if p.get("name") == name), None)
# порожнє поле — «-», не порожній рядок: bash розбиває META по пробілах і порожнє поле зсунуло б сусідів
print("OK", name or "-", m.get("version") or "-", mkt or "-", json.dumps(src))
PY
META="$(cat "$TMP/meta")"
case "$META" in
  OK\ *) ;;
  *) fail "маніфест не читається: ${META#ERR }"; echo "host-smoke: ❌"; exit 1 ;;
esac
set -- $META; NAME="$2"; VER="$3"; MKT="$4"; shift 4; SRC="$*"
[ "$NAME" != - ] || { fail "plugin.json без name"; echo "host-smoke: ❌"; exit 1; }
[ "$MKT" != - ]  || { fail "marketplace.json без name"; echo "host-smoke: ❌"; exit 1; }

N_SKILLS=0
for d in "$PLUGIN_DIR"/skills/*/; do [ -f "${d}SKILL.md" ] && N_SKILLS=$((N_SKILLS + 1)); done
N_AGENTS="$(find "$PLUGIN_DIR/agents" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
# Імена агентів — з frontmatter, щоб вимір «агенти в промті» не був прибитий до цього плагіна.
AGENT_NAMES="$(find "$PLUGIN_DIR/agents" -name '*.md' 2>/dev/null | xargs -I{} sed -n 's/^name:[[:space:]]*//p' {} 2>/dev/null | tr '\n' ' ')"
ok "плагін $NAME $VER · скілів на диску: $N_SKILLS · агентів: $N_AGENTS · маркетплейс: $MKT · source: $SRC"

# Форма source — властивість, яку Codex ловить мовчки (0 плагінів, код 0), а Claude —
# гучно (`"."` → Invalid input). Обидва хости приймають лише рядок із префіксом `./`.
case "$SRC" in
  \"./\"|\"./*\") ;;
  *) note "marketplace source не рядок з префіксом ./ ($SRC) — Codex перелічить 0 плагінів (виміряно на Grow PM 07.09)" ;;
esac

# ----- 1) Claude Code -------------------------------------------------------
if [ "${HOST_SMOKE_SKIP_CLAUDE:-0}" = 1 ]; then
  skip "Claude — HOST_SMOKE_SKIP_CLAUDE=1"
elif ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  skip "Claude — немає $CLAUDE_BIN у PATH (передумова: claude встановлено)"
else
  # Два виклики, обидва явні: `claude plugin validate <тека>` з двома маніфестами
  # валідує МАРКЕТПЛЕЙС і мовчки пропускає плагін — на цьому ж дереві тека
  # проходила, а plugin.json падав на frontmatter агентів (codex review 10.09, P1).
  for target in "$MANIFEST" "$MARKET"; do
    alarm_run "$TMP/claude.out" "$CLAUDE_BIN" plugin validate "$target"; crc=$?
    tname="${target##*/}"
    if [ "$crc" -ge 128 ]; then
      fail "Claude — plugin validate $tname завис (> ${TIMEOUT}s)"
    elif grep -q 'Validation passed' "$TMP/claude.out"; then
      ok "Claude — plugin validate $tname: passed"
    else
      fail "Claude — plugin validate $tname НЕ пройшов (rc=$crc):"; grep -E '❯|✘|Validating' "$TMP/claude.out" | tail -8 | sed 's/^/      /'
    fi
  done
fi

# ----- 2) Codex CLI ---------------------------------------------------------
if [ "${HOST_SMOKE_SKIP_CODEX:-0}" = 1 ]; then
  skip "Codex — HOST_SMOKE_SKIP_CODEX=1"
elif ! command -v "$CODEX_BIN" >/dev/null 2>&1; then
  skip "Codex — немає $CODEX_BIN у PATH (передумова: codex встановлено; симлінк ChatGPT.app)"
else
  HOME_C="$TMP/codex-home"; mkdir -p "$HOME_C"
  printf 'model = "gpt-6-astra"\n' > "$HOME_C/config.toml"

  run_codex() { # run_codex <out> <args...>  — ізольований CODEX_HOME
    local out="$1"; shift
    CODEX_HOME="$HOME_C" alarm_run "$out" "$CODEX_BIN" "$@"
  }
  if ! run_codex "$TMP/mkt.out" plugin marketplace add "$STAGE"; then
    fail "Codex — plugin marketplace add не вдався:"; tail -3 "$TMP/mkt.out" | sed 's/^/      /'
  elif ! run_codex "$TMP/add.out" plugin add "$NAME@$MKT"; then
    fail "Codex — plugin add $NAME@$MKT не вдався (маркетплейс без плагінів? форма source):"; tail -3 "$TMP/add.out" | sed 's/^/      /'
  else
    ( cd "$STAGE" && run_codex "$TMP/prompt.json" debug prompt-input ); prc=$?
    if [ "$prc" -ne 0 ]; then
      fail "Codex — debug prompt-input rc=$prc:"; tail -3 "$TMP/prompt.json" | sed 's/^/      /'
    else
      python3 - "$TMP/prompt.json" "$NAME" "$HOME_C" "$AGENT_NAMES" > "$TMP/counts" <<'PY'
import json, os, re, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("ERR " + str(e).replace("\n", " ")); sys.exit(0)
name = sys.argv[2]
home = os.path.realpath(sys.argv[3])  # mktemp дає /var/…, Codex пише /private/var/… — порівнювати реальні шляхи
t = "".join(c.get("text", "") for m in d for c in (m.get("content") or []) if isinstance(c, dict))
bt = chr(96)  # бектик — не літералом: bash 3.2 губиться на ньому всередині heredoc
roots = {m.group(1): m.group(2) for m in re.finditer(r"- " + bt + r"(r\d+)" + bt + r" = " + bt + r"([^" + bt + r"]+)" + bt, t)}
skills = 0
for l in t.splitlines():
    m = re.match(r"- " + re.escape(name) + r":([A-Za-z0-9_-]+): .*\(file: (r\d+)/", l.strip())
    if m and os.path.realpath(roots.get(m.group(2), "/nonexistent")).startswith(home):
        skills += 1
names = [n for n in sys.argv[4].split() if n]
agents = sum(1 for n in names if re.search(r"(^|[^A-Za-z0-9_-])" + re.escape(n) + r"([^A-Za-z0-9_-]|$)", t))
print("OK", skills, agents, "shortened" if "shortened to fit" in t else "full")
PY
      COUNTS="$(cat "$TMP/counts")"
      case "$COUNTS" in
        OK\ *)
          set -- $COUNTS; C_SK="$2"; C_AG="$3"; C_DESC="$4"
          if [ "$C_SK" = "$N_SKILLS" ]; then
            ok "Codex — у промті $C_SK/$N_SKILLS скілів $NAME:* (ізольований CODEX_HOME, без моделі)"
          else
            fail "Codex — у промті $C_SK скілів, на диску $N_SKILLS (${NAME}:* мусять збігатися один в один)"
          fi
          [ "$C_DESC" = shortened ] && note "Codex — описи скілів урізано під бюджет (~15k символів на всі скіли хоста)"
          note "Codex — агентів у промті: $C_AG з $N_AGENTS на диску; хуків: не вантажаться з плагіна (відома межа хоста, виміряно 09.09)"
          ;;
        *) fail "Codex — промт не розібрано: ${COUNTS#ERR }" ;;
      esac
    fi
  fi
fi

echo
if [ "$RC" -ne 0 ]; then echo "host-smoke: ❌ ($NAME $VER)"; exit 1; fi
if [ "$UNMEASURED" -ne 0 ]; then echo "host-smoke: ⚠ не поміряно повністю ($NAME $VER) — див. SKIP вище"; exit 2; fi
echo "host-smoke: ✅ $NAME $VER вантажиться в Claude Code і Codex CLI"
exit 0
