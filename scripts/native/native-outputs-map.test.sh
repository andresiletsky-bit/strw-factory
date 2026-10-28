#!/usr/bin/env bash
# native-outputs-map.test.sh — references/native-outputs.md узгоджена з реєстром інструментів
# (factory.native-outputs, acceptance: «типи задач карти збігаються з vocab.task_types»). Golden: справжня карта
# проти фікстури v1.1 і — коли є — проти живого strw-state/engine/tools.yaml. Червоні: кожна властивість
# перевірки ламається підкладеною копією справжньої карти (мутація з доказом накладення).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHK="${HERE}/native-outputs-map-check.py"
MAP="${HERE}/../../references/native-outputs.md"
FIX="${HERE}/fixtures/tools.v1.yaml"
pass=0; fail=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nom-test.XXXXXX")"; trap 'rm -rf "${TMP}"' EXIT
ok()  { pass=$((pass+1)); printf 'PASS · %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL · %s\n%s\n' "$1" "${2:-}"; }

out="$(python3 "${CHK}" --map "${MAP}" --registry "${FIX}" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "справжня карта ↔ фікстура v1.1 → 0" || bad "справжня карта мала бути узгоджена з фікстурою" "rc=${rc} ${out}"

sub() { # sub <вихід> <старе> <нове> [файл-джерело] — заміна першого входження з доказом накладення
    python3 - "${4:-${MAP}}" "$1" "$2" "$3" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src, encoding="utf-8").read()
assert old in t, "мутація не накладена: немає " + old
open(dst, "w", encoding="utf-8").write(t.replace(old, new, 1))
PY
}
red() { # red <назва> <фрагмент знахідки> <карта> [реєстр]
    local out rc
    out="$(python3 "${CHK}" --map "$3" --registry "${4:-${FIX}}" 2>&1)"; rc=$?
    if [ "${rc}" -eq 1 ] && printf '%s' "${out}" | /usr/bin/grep -q -- "$2"; then ok "червоний: $1 → 1, «$2»"
    else bad "червоний: $1 мав дати 1 з «$2»" "rc=${rc} ${out}"; fi
}
M="${TMP}/m"; mkdir -p "${M}"
sub "${M}/extra.md" "| \`automation\` |" "| \`automation-x\` |";                     red "зайвий і відсутній task_type" "поза vocab.task_types: automation-x" "${M}/extra.md"
red "той самий випадок — відсутній" "немає task_type реєстру: automation" "${M}/extra.md"
python3 - "${MAP}" "${M}/missing.md" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read().splitlines(True)
n = [l for l in t if not l.startswith("| `legal` |")]
assert len(n) == len(t) - 1, "мутація не накладена"
open(sys.argv[2], "w", encoding="utf-8").write("".join(n))
PY
red "рядок task_type вилучено" "немає task_type реєстру: legal" "${M}/missing.md"
python3 - "${MAP}" "${M}/dup.md" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
line = [l for l in t.splitlines(True) if l.startswith("| `legal` |")][0]
open(sys.argv[2], "w", encoding="utf-8").write(t.replace(line, line + line, 1))
PY
red "дубль task_type" "дубль task_type: legal" "${M}/dup.md"
sub "${M}/where.md" "| \`deck\` | дека для CEO на його прохання | Slides |" "| \`deck\` | дека для CEO на його прохання | Keynote |"; red "невідоме «Куди»" "Keynote" "${M}/where.md"
sub "${M}/status.md" "| Slides | кандидат |" "| Slides | можливо |";               red "невідомий статус" "можливо" "${M}/status.md"
sub "${M}/dashstatus.md" "| — | — | GitHub Actions" "| — | кандидат | GitHub Actions"; red "статус у не-виходу" "ci-gate: не вихід-документ" "${M}/dashstatus.md"
sub "${M}/why.md" "| джерела немає |" "|  |";                                         red "порожнє «Чому»" "порожнє «Чому»" "${M}/why.md"
sub "${M}/whydash.md" "| джерела немає |" "| — |";                                    red "«Чому» = —" "порожнє «Чому»" "${M}/whydash.md"
sub "${M}/noslides.md" "### Slides" "### Слайди";                                     red "розділу Slides немає" "розділи типів" "${M}/noslides.md"
sub "${M}/sixth.md" "### Slides" "### Slides

### Canvas";                                                                               red "шостий розділ типу" "розділи типів" "${M}/sixth.md"
sub "${M}/nourl.md" "**Приватний Dashboard «Реєстр інструментів STRW»:** https://claude.ai/artifact/" "**Приватний Dashboard «Реєстр інструментів STRW»:** artifact/"; red "без посилання на живий Dashboard" "без посилання" "${M}/nourl.md"
sub "${M}/nolive.md" "| Dashboard | впроваджено |" "| Dashboard | кандидат |";       red "немає Dashboard · впроваджено" "Dashboard · впроваджено" "${M}/nolive.md"
sub "${M}/nomark.md" "<!-- map:end -->" "";                                           red "немає маркера кінця" "маркери" "${M}/nomark.md"
sub "${M}/cols.md" "| \`legal\` | юридичні документи | — | — | — · не підключено | джерела немає |" "| \`legal\` | юридичні документи | — | — | джерела немає |"; red "рядок не з 6 колонок" "не з 6 колонок" "${M}/cols.md"
sub "${M}/reg-type.yaml" "  - id: artifact-docs" "  - id: artifact-doc" "${FIX}";            red "artifact-type реєстру не з карти" "artifact-doc (artifact-type)" "${MAP}" "${M}/reg-type.yaml"
sub "${M}/reg-name.yaml" "    name: \"Docs\"" "    name: \"Artifact · Docs\"" "${FIX}"
out="$(python3 "${CHK}" --map "${MAP}" --registry "${M}/reg-name.yaml" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "назва artifact-type — для людини, не звіряється (контроль, форма #283)" || bad "назва artifact-type не мала б червоніти" "rc=${rc} ${out}"
sub "${M}/reg-vocab.yaml" "    automation: \"автоматизації\"" "    automation: \"автоматизації\"
    voice: \"голос\"" "${FIX}";                                                          red "новий task_type у реєстрі без рядка карти" "немає task_type реєстру: voice" "${MAP}" "${M}/reg-vocab.yaml"
sub "${M}/who.md" "| — · не підключено | джерела немає |" "|  | джерела немає |";   red "порожнє «Хто створює»" "порожнє «Хто створює»" "${M}/who.md"
sub "${M}/dupsec.md" "### Slides" "### Slides

### Docs";                                                                                  red "дубль розділу типу" "розділи типів" "${M}/dupsec.md"
sub "${M}/nottable.md" "| \`legal\` |" "просто текст
| \`legal\` |";                                                                               red "рядок поза таблицею" "не є рядком таблиці" "${M}/nottable.md"
sub "${M}/nosep.md" "|---|---|---|---|---|---|
" "";                                                                                       red "таблиця без роздільника" "без заголовка" "${M}/nosep.md"
sub "${M}/notick.md" "| \`legal\` |" "| legal |";                                           red "task_type без бектиків" "не в бектиках" "${M}/notick.md"
sub "${M}/reg-novocab.yaml" "  task_types:" "  task_types_off:" "${FIX}";                    red "реєстр без vocab.task_types" "без vocab.task_types" "${MAP}" "${M}/reg-novocab.yaml"
sub "${M}/outdash.md" "| \`legal\` | юридичні документи |" "| \`legal\` | — |";           red "«Вихід» = —" "legal: порожній «Вихід»" "${M}/outdash.md"
sub "${M}/whodash.md" "| — · не підключено | джерела немає |" "| — | джерела немає |";     red "«Хто» = —" "порожнє «Хто створює»" "${M}/whodash.md"
sub "${M}/cols7.md" "| \`legal\` | юридичні документи | — | — | — · не підключено | джерела немає |" "| \`legal\` | юридичні документи | — | — | — · не підключено | джерела немає | зайве |"; red "рядок із 7 колонок" "не з 6 колонок" "${M}/cols7.md"
sub "${M}/nowhere.md" "| \`legal\` | юридичні документи | — | — |" "| \`legal\` | юридичні документи |  | — |"; red "порожнє «Куди»" "legal: «Куди» «»" "${M}/nowhere.md"
sub "${M}/twomark.md" "<!-- map:end -->" "<!-- map:end -->
<!-- map:begin -->";                                                                         red "подвоєний маркер" "маркери" "${M}/twomark.md"
sub "${M}/chaturl.md" "**Приватний Dashboard «Реєстр інструментів STRW»:** https://claude.ai/artifact/" "**Приватний Dashboard «Реєстр інструментів STRW»:** https://claude.ai/chat/"; red "посилання не на artifact" "без посилання" "${M}/chaturl.md"
sub "${M}/tickx.md" "| \`legal\` |" "| \`legal\` (див.) |";                               red "task_type з хвостом після бектиків" "не в бектиках" "${M}/tickx.md"
sub "${M}/urlelse.md" "**Приватний Dashboard «Реєстр інструментів STRW»:** https://claude.ai/artifact/" "**Приватний Dashboard «Реєстр інструментів STRW»:** artifact/"
sub "${M}/urlelse2.md" "### Dashboard
" "### Dashboard
Приклад: https://claude.ai/artifact/ELmCJXr9kRpguLCwSN8qs7
" "${M}/urlelse.md";                                                                          red "посилання лише поза розділом живого Dashboard" "без посилання" "${M}/urlelse2.md"
sub "${M}/reg-ttempty.yaml" "  task_types:
" "  task_types: {}
  task_types_off:
" "${FIX}";                                                                                  red "реєстр із порожнім vocab.task_types" "без vocab.task_types" "${MAP}" "${M}/reg-ttempty.yaml"
out="$(python3 "${CHK}" --map "${TMP}/nope.md" --registry "${FIX}" 2>&1)"; rc=$?
[ "${rc}" -eq 2 ] && printf '%s' "${out}" | /usr/bin/grep -q "не читається" && ok "карти немає → 2 «не читається» (не поміряти)" || bad "карти немає мало дати 2" "rc=${rc} ${out}"

LIVE="${STRW_ROOT:-${HOME}/Developer/STRW}/strw-state/engine/tools.yaml"
if [ -f "${LIVE}" ]; then
    out="$(python3 "${CHK}" --map "${MAP}" --registry "${LIVE}" 2>&1)"; rc=$?
    [ "${rc}" -eq 0 ] && ok "справжня карта ↔ живий tools.yaml → 0" || bad "карта розійшлась із живим реєстром" "rc=${rc} ${out}"
else
    printf 'SKIP · живий реєстр: немає %s (factory.tool-registry не злито або пісочниця без strw-state)\n' "${LIVE}"
fi

printf '\n%d PASS · %d FAIL\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
