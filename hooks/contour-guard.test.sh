#!/usr/bin/env bash
# Негативні контролі contour-guard.sh (П-3). Запуск на Mac: bash hooks/contour-guard.test.sh
# Контур C симулюється фейковим uname (друкує Linux) попереду PATH — без
# env-перемикачів у самому гарді, щоб не створювати вектор обходу.
# «Зняти умову → проба червоніє» — проба 13: та сама проба блокування, але в
# реальному Mac-середовищі, МУСИТЬ дати 0 замість 2 (тобто почервоніти).
set -uo pipefail
GUARD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/contour-guard.sh"
PASS=0; FAIL=0

TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\necho Linux\n' > "$FAKEBIN/uname"; chmod +x "$FAKEBIN/uname"

probe() { # $1 назва · $2 очікуваний код · $3 env-режим (C|M) · $4 JSON
  local out rc envprefix
  if [ "$3" = "C" ]; then
    out="$(printf '%s' "$4" | PATH="$FAKEBIN:$PATH" bash "$GUARD" 2>&1)"; rc=$?
  else
    out="$(printf '%s' "$4" | bash "$GUARD" 2>&1)"; rc=$?
  fi
  if [ "$rc" -eq "$2" ]; then
    PASS=$((PASS+1)); printf 'PASS · %s (exit %s)\n' "$1" "$rc"
  else
    FAIL=$((FAIL+1)); printf 'FAIL · %s: очікував %s, отримав %s\n%s\n' "$1" "$2" "$rc" "$out"
  fi
}

wjson() { printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1"; }
bjson() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

echo "── Контур C (фейковий uname=Linux) ──"
probe "Write у triage-inbox.md → блок"        2 C "$(wjson "$TMP/strw-state/triage-inbox.md")"
probe "Edit у loops-log/ → блок"              2 C '{"tool_name":"Edit","tool_input":{"file_path":"/x/strw-state/loops-log/2026-W34.md"}}'
probe "Write у _outbox/ → дозвіл"             0 C "$(wjson "$TMP/strw-state/_outbox/2026-08-15T10-00-l4-tea.md")"
probe "Write у звичайний файл → дозвіл"       0 C "$(wjson "$TMP/notes.md")"
probe "Bash: echo >> budget.md → блок"        2 C "$(bjson 'echo x >> budget.md')"
probe "Bash: tee -a decisions-log.md → блок"  2 C "$(bjson 'printf x | tee -a decisions-log.md')"
probe "Bash: sed -i portfolio.md → блок"      2 C "$(bjson 'sed -i .bak s/a/b/ portfolio.md')"
probe "Bash: читання канонічного з редиректом убік → дозвіл" 0 C "$(bjson 'grep -c x triage-inbox.md > /tmp/out.txt')"
probe "Bash: git commit → блок"               2 C "$(bjson 'git commit -m x')"
probe "Bash: git push → блок"                 2 C "$(bjson 'git push origin main')"
probe "Bash: git без --no-optional-locks → блок" 2 C "$(bjson 'git status --short')"
probe "Bash: git --no-optional-locks log → дозвіл" 0 C "$(bjson 'git --no-optional-locks log --oneline -3')"
probe "Bash: xcodebuild → блок"               2 C "$(bjson 'xcodebuild test -scheme Pact')"

echo "── Контур M (реальне середовище, тулчейн на місці) ──"
probe "Write у triage-inbox.md → дозвіл"      0 M "$(wjson "$TMP/strw-state/triage-inbox.md")"
probe "Bash: git commit → дозвіл (гард неактивний)" 0 M "$(bjson 'git commit -m x')"

echo "── Негативний контроль: зняти умову → проба червоніє ──"
# Та сама проба, що блокувалась у C, у середовищі M з очікуванням блоку МУСИТЬ провалитись.
out="$(printf '%s' "$(wjson "$TMP/strw-state/triage-inbox.md")" | bash "$GUARD" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
  FAIL=$((FAIL+1)); echo "FAIL · проба НЕ почервоніла без умови: гард блокує і в контурі M — умова не працює"
else
  PASS=$((PASS+1)); echo "PASS · без умови контуру C проба блокування червоніє (exit $rc ≠ 2) — гард міряє умову, не завжди-блок"
fi

echo "── Умова «.git недоступний на запис» (Darwin + тулчейн, RO .git) ──"
RO="$TMP/ro-repo"; mkdir -p "$RO/.git"; touch "$RO/budget.md"; chmod 555 "$RO/.git"
probe "Write у budget.md під RO-.git → блок"  2 M "$(wjson "$RO/budget.md")"
chmod 755 "$RO/.git"
probe "Write у budget.md після повернення прав → дозвіл" 0 M "$(wjson "$RO/budget.md")"

echo
echo "Разом: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
