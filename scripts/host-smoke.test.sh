#!/usr/bin/env bash
# Проби на scripts/host-smoke.sh — гейт «плагін вантажиться в обох хостах».
#
# ГОЛОВНА ПРОБА — (b): маркетплейс з ОБ'ЄКТНОЮ формою `source`. Codex додає такий
# маркетплейс мовчки з 0 плагінів (виміряно на Grow PM 07–08.09.2026), Claude
# validate його теж не ловить. Гейт, що не червоніє на цій фікстурі, не тримає
# властивості, заради якої існує.
#
# Проби (c)–(e) — інші способи розійтися з диском; (f) — «не поміряно» (2) не
# сміє злитися з «зелено» (0): хоста немає → 2, і це видно у виводі.
#
# Справжні `claude`/`codex` — так, але БЕЗ моделі: `claude plugin validate` і
# `codex debug prompt-input` в ізольованому CODEX_HOME. Без `codex` у PATH проби
# (a)–(d) кажуть SKIP уголос і набір лічить їх окремо; (e)–(f) не потребують codex.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$PWD/scripts/host-smoke.sh"
PLUGIN="$PWD"
pass=0; fail=0; skipped=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Фікстура — мінімальна копія плагіна: маніфести + skills/ (agents/ лишаємо, щоб
# рядок note про агентів був відтворюваний). Без git → --tree.
mkfixture() { # mkfixture <тека>
    local d=$1; rm -rf "$d"; mkdir -p "$d/.claude-plugin"
    cp "$PLUGIN/.claude-plugin/plugin.json" "$PLUGIN/.claude-plugin/marketplace.json" "$d/.claude-plugin/"
    cp -R "$PLUGIN/skills" "$d/skills"
    cp -R "$PLUGIN/agents" "$d/agents"
}
set_source() { # set_source <тека> <python-вираз для source>
    python3 - "$1/.claude-plugin/marketplace.json" "$2" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["plugins"][0]["source"] = eval(sys.argv[2])
json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
PY
}
want() { # want <код> <назва> <шматок|-> <args...>
    local code=$1 name=$2 nugget=$3; shift 3
    local out rc ok=1
    out=$(bash "$TOOL" "$@" 2>&1); rc=$?
    [ "$rc" = "$code" ] || ok=0
    [ "$nugget" = "-" ] || printf '%s' "$out" | grep -q -- "$nugget" || ok=0
    if [ $ok -eq 1 ]; then printf 'ok   %s\n' "$name"; pass=$((pass+1))
    else printf 'FAIL %s (rc=%d, очікував %s)\n' "$name" "$rc" "$code"; printf '%s\n' "$out" | tail -6 | sed 's/^/       /'; fail=$((fail+1)); fi
}
skip() { printf 'SKIP %s — %s\n' "$1" "$2"; skipped=$((skipped+1)); }

HAVE_CODEX=0; command -v codex >/dev/null 2>&1 && HAVE_CODEX=1
HAVE_CLAUDE=0; command -v claude >/dev/null 2>&1 && HAVE_CLAUDE=1

if [ $HAVE_CODEX -eq 1 ]; then
    echo "  (a) справжній плагін, робоче дерево → 0, у промті стільки ж скілів, скільки на диску"
    N=$(ls -d "$PLUGIN"/skills/*/ | wc -l | tr -d ' ')
    HOST_SMOKE_SKIP_CLAUDE=1 want 2 "без Claude (SKIP названо) → 2, Codex $N/$N" "у промті $N/$N скілів" --tree "$PLUGIN"

    echo "  (b) об'єктна форма source → Codex 0 плагінів → 1 (головна проба)"
    mkfixture "$TMP/objsrc"; set_source "$TMP/objsrc" '{"source":"git-subdir","url":"https://example.invalid/x.git","path":".","ref":"main"}'
    HOST_SMOKE_SKIP_CLAUDE=1 want 1 "source-об'єкт → plugin add не вдається → 1" "форма source" --tree "$TMP/objsrc"

    echo "  (c) тека в skills/ без SKILL.md — на диску не рахується, у промті теж → 0 (не хибна тривога)"
    mkfixture "$TMP/nodir"; mkdir -p "$TMP/nodir/skills/zz-empty"
    HOST_SMOKE_SKIP_CLAUDE=1 want 2 "порожня тека не змінює лічбу" "скілів" --tree "$TMP/nodir"

    echo "  (d) скіл без frontmatter name/description — Codex не перелічує, на диску є → 1"
    mkfixture "$TMP/badskill"; mkdir -p "$TMP/badskill/skills/zz-broken"; printf '# без frontmatter\n' > "$TMP/badskill/skills/zz-broken/SKILL.md"
    HOST_SMOKE_SKIP_CLAUDE=1 want 1 "скіл без frontmatter → у промті менше, ніж на диску → 1" "мусять збігатися" --tree "$TMP/badskill"
else
    skip "(a)–(d)" "codex немає в PATH — Codex-половину гейта тут не поміряти"
fi

echo "  (e) зламаний plugin.json → 1 ще до хостів"
mkfixture "$TMP/noname"; printf '{ "version": "0.0.1" }\n' > "$TMP/noname/.claude-plugin/plugin.json"
want 1 "plugin.json без name → 1 (порожнє поле не зсуває сусідів)" "без name" --tree "$TMP/noname"
mkfixture "$TMP/badjson"; printf '{ not json' > "$TMP/badjson/.claude-plugin/plugin.json"
want 1 "plugin.json не читається → 1" "маніфест не читається" --tree "$TMP/badjson"
mkfixture "$TMP/nomkt"; rm "$TMP/nomkt/.claude-plugin/marketplace.json"
want 1 "без marketplace.json → 1" "marketplace.json" --tree "$TMP/nomkt"

echo "  (f) хоста немає → 2 (не поміряно), не 0"
mkfixture "$TMP/nohost"
CODEX_BIN=/nonexistent/codex CLAUDE_BIN=/nonexistent/claude want 2 "обох хостів немає → 2 з двома SKIP" "SKIP: Codex" --tree "$TMP/nohost"
CODEX_BIN=/nonexistent/codex HOST_SMOKE_SKIP_CLAUDE=1 want 2 "codex немає, claude пропущено свідомо → 2" "передумова: codex" --tree "$TMP/nohost"

if [ $HAVE_CLAUDE -eq 1 ]; then
    echo "  (g) Claude validate червоний → 1 (name із пробілом — це ловить лише claude, не передперевірка)"
    mkfixture "$TMP/badname"; python3 - "$TMP/badname/.claude-plugin/plugin.json" "$TMP/badname/.claude-plugin/marketplace.json" <<'PY'
import json, sys
for p in sys.argv[1:]:
    d = json.load(open(p))
    if "plugins" in d: d["plugins"][0]["name"] = "bad name!"
    else: d["name"] = "bad name!"
    json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
PY
    HOST_SMOKE_SKIP_CODEX=1 want 1 "name «bad name!» → Claude validate failed → 1" "plugin.json НЕ пройшов" --tree "$TMP/badname"
    echo "  (h) зламано ЛИШЕ вміст плагіна (frontmatter агента), маркетплейс цілий → 1 (P1: тека валідує маркетплейс, не плагін)"
    mkfixture "$TMP/badagent"; printf -- '---\nname: zz\ndescription: a: b: c\n---\nтіло\n' > "$TMP/badagent/agents/zz-broken.md"
    HOST_SMOKE_SKIP_CODEX=1 want 1 "агент із нечитним frontmatter → plugin.json НЕ пройшов → 1" "plugin.json НЕ пройшов" --tree "$TMP/badagent"
else
    skip "(g)–(h)" "claude немає в PATH"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
[ $fail -eq 0 ]
