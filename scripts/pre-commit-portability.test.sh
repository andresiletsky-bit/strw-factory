#!/usr/bin/env bash
# .githooks/pre-commit strw-factory — крок переносності оболонки (factory.portability-gate-all-repos).
# Фікстура: парасолька в tmp зі СПРАВЖНІМ сторожем і tsv зі strw-state + стаб
# constitution-size-gate (перший крок хука, не предмет); репо з цим самим хуком;
# кожен випадок — справжній `git commit` під core.hooksPath.
#   (a) staged *.sh із fixture рядка tsv → відмова з id; (b) чистий → ок;
#   (c) без strw-state поруч → відмова з причиною; (d) без файлів поверхні — крок не ганяється;
#   (e) негативний контроль: хук без виклику сторожа → (a) проходить.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRW="${STRW_ROOT:-$(cd "$HERE/../.." && pwd)}"; [ -f "$STRW/strw-state/scripts/shell-portability-check.sh" ] || STRW="$HOME/Developer/STRW"
REAL="$STRW/strw-state/scripts"
[ -f "$REAL/shell-portability-check.sh" ] || { echo "SKIP · немає strw-state поруч ($REAL) — фікстура не збирається (код 3)"; exit 3; }
pass=0; fail=0; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/root"; mkdir -p "$ROOT/strw-state/scripts/lib" "$ROOT/bin"
cp "$REAL/shell-portability-check.sh" "$ROOT/strw-state/scripts/"; cp "$REAL/lib/nonportable-forms.tsv" "$ROOT/strw-state/scripts/lib/"
printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/constitution-size-gate.sh"
FIXTURE="$(awk -F'\t' '$1=="sed-inplace-detached"{print $3}' "$ROOT/strw-state/scripts/lib/nonportable-forms.tsv")"
mkrepo() { rm -rf "$1"; mkdir -p "$1/.githooks"; cp "$HERE/.githooks/pre-commit" "$1/.githooks/pre-commit"; chmod +x "$1/.githooks/pre-commit"
  ( cd "$1" && git init -q && git config user.email t@t && git config user.name t && git config core.hooksPath .githooks && git add .githooks && git commit -q -m init ) >/dev/null 2>&1; }
try() { # try <назва> <очікуваний rc> <репо> <STRW_ROOT> <файл> <вміст> [нагет]
  local name=$1 want=$2 r=$3 root=$4 f=$5 body=$6 nug=${7:-}; local out rc ok=1
  out=$(cd "$r" && printf '%s\n' "$body" > "$f" && git add -- "$f" && STRW_ROOT="$root" git commit -q -m "probe" 2>&1); rc=$?
  [ "$rc" -eq "$want" ] || ok=0; [ -z "$nug" ] || printf '%s' "$out" | grep -q -- "$nug" || ok=0
  if [ $ok -eq 1 ]; then echo "ok   $name"; pass=$((pass+1)); else echo "FAIL $name (rc=$rc/$want)"; printf '%s\n' "$out" | tail -4 | sed 's/^/       /'; fail=$((fail+1)); fi
  ( cd "$r" && git reset -q HEAD -- "$f" 2>/dev/null; rm -f "$f" ) >/dev/null 2>&1
}
R="$ROOT/repo"; mkrepo "$R"
try "(a) fixture форми → відмова з id"           1 "$R" "$ROOT" bad.sh "$(printf '#!/bin/sh\n%s' "$FIXTURE")" "sed-inplace-detached"
try "(b) чистий *.sh → ок"                        0 "$R" "$ROOT" ok.sh  "$(printf '#!/bin/sh\necho ok')"
mkdir -p "$TMP/lonely/bin"; cp "$ROOT/bin/constitution-size-gate.sh" "$TMP/lonely/bin/"
try "(c) без strw-state поруч → відмова з причиною" 1 "$R" "$TMP/lonely" ok2.sh "$(printf '#!/bin/sh\necho ok')" "немає strw-state поруч"
try "(d) без файлів поверхні — крок не ганяється (навіть без сусіда)" 0 "$R" "$TMP/lonely" notes.md "текст"
RB="$ROOT/big"; mkrepo "$RB"
( cd "$RB" && mkdir -p many && i=0; while [ $i -lt 800 ]; do printf 'x\n' > "many/file-with-a-rather-long-name-$i.txt"; i=$((i+1)); done && printf '#!/bin/sh\n%s\n' "$FIXTURE" > aaa-bad.sh && git add -A ) >/dev/null 2>&1
out="$(cd "$RB" && STRW_ROOT="$ROOT" git commit -q -m big 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'sed-inplace-detached'; then echo "ok   (d') великий коміт (800 staged) не відкриває гейт"; pass=$((pass+1)); else echo "FAIL (d') великий коміт відкрив гейт (rc=$rc)"; fail=$((fail+1)); fi
R2="$ROOT/repo2"; mkrepo "$R2"; sed 's#bash "\$PGATE" || {#true || {#' "$R2/.githooks/pre-commit" > "$R2/.githooks/x" && mv "$R2/.githooks/x" "$R2/.githooks/pre-commit" && chmod +x "$R2/.githooks/pre-commit"
grep -q 'bash "\$PGATE"' "$R2/.githooks/pre-commit" && { echo "FAIL мутація не накладена"; fail=$((fail+1)); }
try "(e) НЕГАТИВНИЙ КОНТРОЛЬ: хук без сторожа пропускає (a)" 0 "$R2" "$ROOT" bad.sh "$(printf '#!/bin/sh\n%s' "$FIXTURE")"
printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
