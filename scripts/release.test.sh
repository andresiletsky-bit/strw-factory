#!/usr/bin/env bash
# release.test.sh — реліз без нотаток не робиться (v0.10.8, 07.09.2026).
#
# ЩО СТАЛОСЬ. Сесія запустила release.sh до того, як PR злився; секція
# [Unreleased] була порожня, і скрипт мовчки підставив «- Release 0.10.8» —
# тег і GitHub Release опубліковано без жодної зміни (клас
# green-because-subject-missing: гейт «нотатки є» проходив, не бачачи нотаток).
#
# Проби — на фікстурній копії плагіна в tmp (git init, main, стаб evals), усе
# через --dry-run --no-gh -y, тобто без тегів, пушів і мережі:
#   · [Unreleased] порожній, -m немає → rc≠0 з названою причиною;
#   · [Unreleased] з записом → rc=0, нотатки = запис;
#   · [Unreleased] порожній, але -m «…» → rc=0 (явна нотатка — дозволено);
#   · [Unreleased] лише з HTML-коментарем → rc≠0 (коментар — не нотатка).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

mkfixture() { # mkfixture <тека> <тіло [Unreleased]>
    local d=$1; rm -rf "$d"; mkdir -p "$d/.claude-plugin" "$d/scripts/evals"
    cp "$HERE/release.sh" "$d/scripts/release.sh"
    printf '#!/bin/sh\nexit 0\n' > "$d/scripts/evals/run.sh"
    printf '{ "name": "fx", "version": "0.1.0" }\n' > "$d/.claude-plugin/plugin.json"
    printf '# Changelog\n\n## [Unreleased]\n%s\n## [0.1.0] — 2026-01-01\n\n- перший\n' "$2" > "$d/CHANGELOG.md"
    ( cd "$d" && git init -q -b main && git config user.email t@t && git config user.name t \
      && git add -A && git commit -qm init ) >/dev/null 2>&1
}
want() { # want <rc-код: 0|nonzero> <назва> <тека> <шматок|-> [args...]
    local code=$1 name=$2 d=$3 nugget=$4; shift 4
    local out rc ok=1
    out=$(cd "$d" && bash scripts/release.sh patch --dry-run --no-gh -y "$@" 2>&1); rc=$?
    if [ "$code" = 0 ]; then [ $rc -eq 0 ] || ok=0; else [ $rc -ne 0 ] || ok=0; fi
    [ "$nugget" = "-" ] || printf '%s' "$out" | grep -q -- "$nugget" || ok=0
    if [ $ok -eq 1 ]; then printf 'ok   %s\n' "$name"; pass=$((pass+1))
    else printf 'FAIL %s (rc=%d, очікував %s)\n' "$name" "$rc" "$code"; printf '%s\n' "$out" | tail -5 | sed 's/^/       /'; fail=$((fail+1)); fi
}

mkfixture "$TMP/empty" ""
want nonzero "порожній [Unreleased] без -m → відмова з причиною" "$TMP/empty" "реліз без нотаток не робиться"
want 0       "порожній [Unreleased], але -m → дозволено"          "$TMP/empty" "явна нотатка" -m "явна нотатка"

mkfixture "$TMP/full" $'\n### Changed\n- щось справжнє\n'
want 0       "[Unreleased] із записом → dry-run зелений"           "$TMP/full" "щось справжнє"

mkfixture "$TMP/comment" $'\n<!-- лише коментар -->\n'
want nonzero "[Unreleased] лише з коментарем → відмова"            "$TMP/comment" "реліз без нотаток не робиться"
mkfixture "$TMP/mlcomment" $'\n<!--\nсюди додай запис перед релізом\n-->\n'
want nonzero "[Unreleased] лише з БАГАТОРЯДКОВИМ коментарем → відмова (текст усередині — не нотатка)" "$TMP/mlcomment" "реліз без нотаток не робиться"
mkfixture "$TMP/mixed" $'\n<!--\nпідказка\n-->\n- справжній запис\n'
want 0       "коментар + справжній запис → ок, нотатки = запис без підказки" "$TMP/mixed" "справжній запис"
out=$(cd "$TMP/mixed" && bash scripts/release.sh patch --dry-run --no-gh -y 2>&1)
if printf '%s' "$out" | grep -q "підказка"; then printf 'FAIL %s\n' "текст коментаря не потрапляє в нотатки"; fail=$((fail+1)); else printf 'ok   %s\n' "текст коментаря не потрапляє в нотатки"; pass=$((pass+1)); fi
want nonzero "-m з самих пробілів → відмова"                       "$TMP/empty" "реліз без нотаток не робиться" -m "   "
mkfixture "$TMP/unclosed" $'\n<!--\nсюди додай запис\n- ніби запис\n'
want nonzero "незакритий <!-- → відмова (секція зламана, не «нотатки з маркером»)" "$TMP/unclosed" "непарний HTML-коментар"
mkfixture "$TMP/nosection" ""
( cd "$TMP/nosection" && printf '# Changelog\n\n## [0.1.0] — 2026-01-01\n\n- перший\n' > CHANGELOG.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm nosec ) >/dev/null 2>&1
want nonzero "CHANGELOG без секції [Unreleased] → відмова (не плейсхолдер)" "$TMP/nosection" "реліз без нотаток не робиться"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ $fail -eq 0 ]
