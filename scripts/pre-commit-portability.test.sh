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
mkdir -p "$ROOT/tests/integration"; printf '#!/bin/sh\nexit 0\n' > "$ROOT/tests/integration/docs-current.test.sh"   # заглушка дрейфу паспортів — щоб коміт із loops/*.md дійшов до другого trap
FIXTURE="$(awk -F'\t' '$1=="sed-inplace-detached"{print $3}' "$ROOT/strw-state/scripts/lib/nonportable-forms.tsv")"
mkrepo() { rm -rf "$1"; mkdir -p "$1/.githooks"; cp "$HERE/.githooks/pre-commit" "$1/.githooks/pre-commit"; chmod +x "$1/.githooks/pre-commit"
  ( cd "$1" && git init -q && git config user.email t@t && git config user.name t && git config core.hooksPath .githooks && git add .githooks && STRW_ROOT="$ROOT" git commit -q -m init ) >/dev/null 2>&1
  [ "$(cd "$1" && git rev-list --count HEAD 2>/dev/null)" = 1 ] || { echo "FAIL фікстура: init-коміт не пройшов у $1"; fail=$((fail+1)); }; }
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
( cd "$RB" && mkdir -p many && i=0; while [ $i -lt 3000 ]; do printf 'x\n' > "many/file-with-a-rather-long-name-$i.txt"; i=$((i+1)); done && printf '#!/bin/sh\n%s\n' "$FIXTURE" > aaa-bad.sh && git add -A ) >/dev/null 2>&1
n_bytes=$(cd "$RB" && git diff --cached --name-only | wc -c | tr -d ' '); [ "$n_bytes" -gt 65536 ] && { echo "ok   (d'') staged-перелік > 65536 байт ($n_bytes)"; pass=$((pass+1)); } || { echo "FAIL (d'') перелік замалий ($n_bytes)"; fail=$((fail+1)); }
out="$(cd "$RB" && STRW_ROOT="$ROOT" git commit -q -m big 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'sed-inplace-detached'; then echo "ok   (d') великий коміт (3000 staged, >64 КБ) не відкриває гейт"; pass=$((pass+1)); else echo "FAIL (d') великий коміт (3000) відкрив гейт (rc=$rc)"; fail=$((fail+1)); fi
RS="$ROOT/staged"; mkrepo "$RS"
out=$(cd "$RS" && printf '#!/bin/sh\n%s\n' "$FIXTURE" > drift.sh && git add drift.sh && printf '#!/bin/sh\necho clean\n' > drift.sh && STRW_ROOT="$ROOT" git commit -q -m drift 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'sed-inplace-detached'; then echo "ok   (f) staged брудне, дерево чисте → відмова (їде staged)"; pass=$((pass+1)); else echo "FAIL (f) staged-дрейф пройшов (rc=$rc)"; fail=$((fail+1)); fi
( cd "$RS" && git reset -q HEAD -- drift.sh && rm -f drift.sh )
out=$(cd "$RS" && printf '#!/bin/sh\necho clean\n' > other.sh && git add other.sh && printf '#!/bin/sh\n%s\n' "$FIXTURE" > other.sh && STRW_ROOT="$ROOT" git commit -q -m tree 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'sed-inplace-detached'; then echo "ok   (f') staged чисте, дерево брудне → відмова (жива поверхня)"; pass=$((pass+1)); else echo "FAIL (f') дерево брудне пройшло (rc=$rc)"; fail=$((fail+1)); fi
RN="$ROOT/names"; mkrepo "$RN"
out=$(cd "$RN" && printf '#!/bin/sh\n%s\n' "$FIXTURE" > перевірка.sh && git add перевірка.sh && printf '#!/bin/sh\necho clean\n' > перевірка.sh && STRW_ROOT="$ROOT" git commit -q -m cyr 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'sed-inplace-detached'; then echo "ok   (g) кириличне ім'я (git цитує без -z): staged-дрейф відмовлено"; pass=$((pass+1)); else echo "FAIL (g) кирилиця пройшла (rc=$rc)"; fail=$((fail+1)); fi
( cd "$RN" && git reset -q HEAD -- перевірка.sh && rm -f перевірка.sh )
out=$(cd "$RN" && printf '#!/bin/sh\necho ok\n' > "my script.sh" && git add "my script.sh" && STRW_ROOT="$ROOT" git commit -q -m sp 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then echo "ok   (g') ім'я з пробілом, чистий → проходить"; pass=$((pass+1)); else echo "FAIL (g') пробіл (rc=$rc): $out"; fail=$((fail+1)); fi
# (g″) два `trap … EXIT` в одному процесі — другий заміщає перший: коміт із *.sh і loops/*.md
# лишав би теку staged-копій у TMPDIR. Блок — підоболонка з власним trap. Міряємо ЗНІМКОМ
# справжнього TMPDIR до/після (BSD mktemp -d ігнорує TMPDIR без явного шаблону — приватний
# TMPDIR був би порожній незалежно від хука; 6a р.3).
# evals-гейт хука шукає scripts/evals/run.sh у самому репо — заглушка, щоб дійти до другого trap.
TD="${TMPDIR:-/tmp}"; before=$(ls -d "$TD"/tmp.* 2>/dev/null | sort)
out=$(cd "$RN" && mkdir -p loops scripts/evals && printf '#!/bin/sh\nexit 0\n' > scripts/evals/run.sh && printf '#!/bin/sh\necho ok\n' > ok.sh && printf '# rule\n' > loops/x.md && git add ok.sh loops/x.md scripts/evals/run.sh && STRW_ROOT="$ROOT" git commit -q -m both 2>&1); rc=$?
after=$(ls -d "$TD"/tmp.* 2>/dev/null | sort)
leftover=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -c . || true)
if [ "$rc" -eq 0 ] && [ "$leftover" -eq 0 ]; then echo "ok   (g″) коміт із *.sh і loops/*.md: обидва trap відпрацювали, у TMPDIR нових тек не лишилось"; pass=$((pass+1)); else echo "FAIL (g″) rc=$rc, нових тек у TMPDIR: $leftover"; fail=$((fail+1)); comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/       /'; fi
# (g‴) `exit 0` «нема поверхні» живе в підоболонці: під `{ }` він завершував би ВЕСЬ хук і наступні
# кроки (дрейф паспортів, evals) не доїжджали б. Staged лише loops/*.md + заглушка дрейфу exit 1 → rc=1.
RD="$ROOT/drift"; mkrepo "$RD"
RD_ROOT="$ROOT/drift-root"; mkdir -p "$RD_ROOT/strw-state/scripts/lib" "$RD_ROOT/bin" "$RD_ROOT/tests/integration"
cp "$ROOT/strw-state/scripts/shell-portability-check.sh" "$RD_ROOT/strw-state/scripts/"; cp "$ROOT/strw-state/scripts/lib/nonportable-forms.tsv" "$RD_ROOT/strw-state/scripts/lib/"
printf '#!/bin/sh\nexit 0\n' > "$RD_ROOT/bin/constitution-size-gate.sh"; printf '#!/bin/sh\necho DRIFT-RED; exit 1\n' > "$RD_ROOT/tests/integration/docs-current.test.sh"
out=$(cd "$RD" && mkdir -p loops scripts/evals && printf '#!/bin/sh\nexit 0\n' > scripts/evals/run.sh && git add scripts/evals/run.sh && STRW_ROOT="$ROOT" git commit -q -m evals-stub 2>&1 && printf '# rule\n' > loops/x.md && git add loops/x.md && STRW_ROOT="$RD_ROOT" git commit -q -m only-loops 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'дрейфу'; then echo "ok   (g‴) staged лише loops/*.md, дрейф червоний → rc≠0: кроки ПІСЛЯ блоку доїжджають"; pass=$((pass+1)); else echo "FAIL (g‴) rc=$rc: $out"; fail=$((fail+1)); fi
R2="$ROOT/repo2"; mkrepo "$R2"; sed 's#bash "\$PGATE" || {#true || {#; s#bash "\$PGATE" "\$@" ) || {#true ) || {#' "$R2/.githooks/pre-commit" > "$R2/.githooks/x" && mv "$R2/.githooks/x" "$R2/.githooks/pre-commit" && chmod +x "$R2/.githooks/pre-commit"
grep -q 'bash "\$PGATE"' "$R2/.githooks/pre-commit" && { echo "FAIL мутація не накладена"; fail=$((fail+1)); }
try "(e) НЕГАТИВНИЙ КОНТРОЛЬ: хук без сторожа пропускає (a)" 0 "$R2" "$ROOT" bad.sh "$(printf '#!/bin/sh\n%s' "$FIXTURE")"
printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
