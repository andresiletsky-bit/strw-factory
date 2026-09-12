#!/usr/bin/env bash
# toolchain-filter-nodup.test.sh — фільтр читає реєстр тим самим читачем, що й валідатор:
# дубльований ключ у item-файлі чи lanes.yaml → код 2 «не поміряти» з іменем ключа, а не
# мовчазний «останній» (tri-094; другий контур після strw-factory #27 — контур C без
# SessionStart-хука бачив реєстр лише цим фільтром).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/toolchain-filter.sh"
pass=0; fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ok()  { pass=$((pass+1)); printf 'PASS · %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL · %s\n%s\n' "$1" "${2:-}"; }
STUB="$TMP/bin"; mkdir -p "$STUB"; printf '#!/bin/sh\nexit 0\n' > "$STUB/gh"; chmod +x "$STUB/gh"

mkengine() { # mkengine <тека> [дубль-у-lanes: 0|1]
    local E=$1; rm -rf "$E"; mkdir -p "$E/items"
    printf 'schema_version: 1\ntools:\n  gh: {kind: tool, probe: "gh --version"}\nlanes:\n  - id: l1\n    repo: x\n    owns: ["a/**"]\n    resources: [gh]\nshared: []\n' > "$E/lanes.yaml"
    [ "${2:-0}" = 1 ] && printf 'schema_version: 1\n' >> "$E/lanes.yaml"
    printf 'schema_version: 1\nid: it1\nproduct: p\nloop: L3-build\nlane: l1\nstate: ready\nrepo: x\nbranch: b\nlease: {run_id: null, epoch: 0, heartbeat: null}\nevidence: {run_id: null, commit_sha: null, cwd: /x}\nattempts: 0\n' > "$E/items/it1.yaml"
}
run() { PATH="$STUB:$PATH" TOOLCHAIN_PROBE_TIMEOUT=5 bash "$TOOL" "$1" 2>&1; }

# контроль: чистий реєстр → не 2 (0 «взято» або 3 «чекають» — залежно від gh-стаба, тут 0)
mkengine "$TMP/clean"; out="$(run "$TMP/clean")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "чистий реєстр → 0 (контроль)"; else bad "чистий реєстр мав би дати 0" "rc=$rc $out"; fi

# дубль у item → 2 з іменем ключа
mkengine "$TMP/dupitem"; printf 'attempts: 1\n' >> "$TMP/dupitem/items/it1.yaml"
out="$(run "$TMP/dupitem")"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'it1.yaml не парситься: дубльований ключ `attempts`'; then ok "дубль attempts у item → 2 з іменем ключа"; else bad "дубль у item мав би дати 2 з іменем ключа" "rc=$rc $out"; fi

# дубль у lanes.yaml → 2
mkengine "$TMP/duplanes" 1; out="$(run "$TMP/duplanes")"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'lanes.yaml не парситься: дубльований ключ `schema_version`'; then ok "дубль schema_version у lanes.yaml → 2"; else bad "дубль у lanes.yaml мав би дати 2" "rc=$rc $out"; fi

# merge-ключ — валідний YAML, не «не парситься»
mkengine "$TMP/merge"; printf 'zz_base: &b {q: 1}\nzz_merge:\n  <<: *b\n' >> "$TMP/merge/lanes.yaml"
out="$(run "$TMP/merge")"; rc=$?
if [ "$rc" -ne 2 ]; then ok "merge-ключ << у lanes.yaml — не 2 (валідний YAML)"; else bad "merge-ключ не мав би бути «не парситься»" "$out"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
