#!/usr/bin/env bash
# validate-design-index.test.sh — схема design/index.yaml (крок 2 strw-design-sync).
# Своїх тестів у валідатора не було (свідком був лише engine-lib-guard на дублі ключа). Поверхню
# `ds-artifact` (дизайн-система в Claude, dec-117) додано з цим файлом: кожен випадок міняє ОДНУ
# річ у зеленому індексі й звіряє ПРИЧИНУ, не лише код.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="${HERE}/validate-design-index.py"
pass=0; fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
ok()  { pass=$((pass+1)); printf 'PASS · %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL · %s\n%s\n' "$1" "${2:-}"; }

green() { cat <<'Y'
schema_version: 1
product: p-001
units:
  - ref: p-001/design-system/claude-ds
    surface: ds-artifact
    url: https://claude.ai/artifact/AbC123
    version: 1793269691-ece4
    working_files: [p-ios/design-system/tokens.json]
    hash: null
    state: watched
  - ref: p-001/design-system/tokens
    surface: code
    working_files: [p-ios/kit/tokens.json]
    hash: null
    state: watched
  - ref: p-001/screens/Canvas
    surface: claude-design
    state: unwatched
    reason: "закривається 14.12"
Y
}
check() { # check <назва> <очікуваний rc: 0|1> <очікуваний фрагмент stderr або ""> <файл>
    local out rc
    out="$(python3 "$V" "$4" 2>&1)"; rc=$?
    if [ "$rc" -eq "$2" ] && { [ -z "$3" ] || printf '%s' "$out" | grep -qF -- "$3"; }; then ok "$1"
    else bad "$1" "rc=$rc (чекали $2) · $out"; fi
}
mut() { # mut <файл> <sed-вираз> — індекс із ОДНІЄЮ зміною
    green | sed "$2" > "$1"
}

green > "$TMP/green.yaml"
check "зелений індекс з ds-artifact, code і unwatched" 0 "" "$TMP/green.yaml"

mut "$TMP/nourl.yaml" '/url: https:\/\/claude.ai\/artifact\/AbC123/d'
check "ds-artifact без url" 1 "ds-artifact без url виду https://claude.ai/artifact/" "$TMP/nourl.yaml"

mut "$TMP/wrongurl.yaml" 's#url: https://claude.ai/artifact/AbC123#url: https://claude.ai/design/p/AbC123#'
check "ds-artifact з url claude.ai/design (не артефакт)" 1 "ds-artifact без url виду" "$TMP/wrongurl.yaml"

mut "$TMP/nover.yaml" '/version: 1793269691-ece4/d'
check "ds-artifact без version" 1 "ds-artifact без version" "$TMP/nover.yaml"

mut "$TMP/nofiles.yaml" '/working_files: \[p-ios\/design-system\/tokens.json\]/d'
check "watched ds-artifact без working_files" 1 "watched без working_files" "$TMP/nofiles.yaml"

mut "$TMP/surface.yaml" 's/surface: ds-artifact/surface: ds-artefact/'
check "друкарська помилка в surface" 1 "surface='ds-artefact'" "$TMP/surface.yaml"

mut "$TMP/noreason.yaml" '/reason: "закривається 14.12"/d'
check "unwatched без reason" 1 "unwatched без reason" "$TMP/noreason.yaml"

mut "$TMP/dupref.yaml" 's#ref: p-001/design-system/tokens#ref: p-001/design-system/claude-ds#'
check "ref повторюється" 1 "ref повторюється" "$TMP/dupref.yaml"

mut "$TMP/noid.yaml" 's#url: https://claude.ai/artifact/AbC123#url: https://claude.ai/artifact/#'
check "ds-artifact з url без id артефакту" 1 "ds-artifact без url виду" "$TMP/noid.yaml"

# url і version обов'язкові ЛИШЕ для ds-artifact: індекс з однією code-одиницею без них — зелений (контроль)
printf 'schema_version: 1\nproduct: p-001\nunits:\n  - ref: p-001/design-system/tokens\n    surface: code\n    working_files: [p-ios/kit/tokens.json]\n    hash: null\n    state: watched\n' > "$TMP/codeonly.yaml"
check "code-одиниця без url/version не червоніє" 0 "" "$TMP/codeonly.yaml"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
