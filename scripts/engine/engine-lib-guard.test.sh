#!/usr/bin/env bash
# engine-lib-guard.test.sh — кожен читач реєстру без lib/yaml_nodup.py поруч каже «немає
# читача, не поміряти» кодом 2 і НАЗИВАЄ файл — не трейсбек ModuleNotFoundError (6a #28: гард був
# у двох скриптах із трьох, свідка не було; мутація «прибрати гард» лишала набори зеленими).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ok()  { pass=$((pass+1)); printf 'PASS · %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL · %s\n%s\n' "$1" "${2:-}"; }
E="$TMP/engine"; mkdir -p "$E/items"; printf 'schema_version: 1\nlanes: []\nshared: []\ntools: {}\n' > "$E/lanes.yaml"
printf 'units: []\n' > "$TMP/index.yaml"

# копія скриптів у теку БЕЗ lib/ (як у фікстурах тестів strw-ops); fallback через STRW_ROOT
# теж перевіряється: (в) копія без lib + STRW_ROOT з парасолькою → читач знайдено
NOLIB="$TMP/nolib"; mkdir -p "$NOLIB"
cp "$HERE"/validate-items.sh "$HERE"/repo-dir.sh "$HERE"/toolchain-filter.sh "$HERE"/design-emit.py "$HERE"/design-hash.py "$HERE"/design_tokens.py "$HERE"/validate-design-index.py "$NOLIB"/
WITHLIB="$TMP/withlib"; cp -R "$NOLIB" "$WITHLIB"; cp -R "$HERE/lib" "$WITHLIB/lib"

probe() { # probe <назва> <тека> <очікуваний: nolib|withlib> <cmd...>
    local name=$1 dir=$2 mode=$3; shift 3
    local out rc
    # «ніде немає»: ні поруч, ні STRW_ENGINE_LIB, ні STRW_ROOT/strw-factory (fallback для копій
    # у фікстурах strw-ops — там парасолька є; тут її свідомо немає)
    out="$(cd "$dir" && env -u STRW_ENGINE_LIB STRW_ROOT=/nonexistent "$@" 2>&1)"; rc=$?
    if [ "$mode" = nolib ]; then
        if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'yaml_nodup.py' && ! printf '%s' "$out" | grep -q 'Traceback'; then ok "$name без lib → 2, називає yaml_nodup.py, без трейсбека"
        else bad "$name без lib мав би дати 2 з назвою читача" "rc=$rc $(printf '%s' "$out" | tail -3)"; fi
    else
        if ! printf '%s' "$out" | grep -q 'yaml_nodup.py'; then ok "$name з lib → про читача не скаржиться (контроль)"
        else bad "$name з lib не мав би скаржитись на читача" "rc=$rc $out"; fi
    fi
}
for mode in nolib withlib; do
    D="$TMP/$mode"
    probe "validate-items.sh"        "$D" $mode bash ./validate-items.sh "$E"
    probe "toolchain-filter.sh"      "$D" $mode bash ./toolchain-filter.sh "$E"
    probe "design-emit.py --help"    "$D" $mode python3 ./design-emit.py --help
    probe "design-hash.py"           "$D" $mode python3 ./design-hash.py --index "$TMP/index.yaml"
    probe "validate-design-index.py" "$D" $mode python3 ./validate-design-index.py "$TMP/index.yaml"
done

# (в) fallback: копія без lib/, але STRW_ROOT указує на парасольку зі strw-factory → не 2
UMB="$TMP/umb"; mkdir -p "$UMB/strw-factory/scripts/engine"; cp -R "$HERE/lib" "$UMB/strw-factory/scripts/engine/lib"
out="$(cd "$NOLIB" && env -u STRW_ENGINE_LIB STRW_ROOT="$UMB" bash ./toolchain-filter.sh "$E" 2>&1)"; rc=$?
if ! printf '%s' "$out" | grep -q 'yaml_nodup.py'; then ok "fallback STRW_ROOT/strw-factory: копія без lib знаходить читача"; else bad "fallback через STRW_ROOT мав би знайти читача" "rc=$rc $out"; fi
out="$(cd "$NOLIB" && env -u STRW_ENGINE_LIB STRW_ROOT="$UMB" python3 ./design-hash.py --index "$TMP/index.yaml" 2>&1)"; rc=$?
if ! printf '%s' "$out" | grep -q 'yaml_nodup.py'; then ok "fallback STRW_ROOT/strw-factory: design-hash.py теж"; else bad "fallback для python-читача" "rc=$rc $out"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
