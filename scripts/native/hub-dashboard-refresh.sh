#!/usr/bin/env bash
# hub-dashboard-refresh.sh — дані Dashboard хаба однією командою (factory.hub-dashboard).
#
#   hub-dashboard-refresh.sh <sessions.json>
#
# <sessions.json> — вихід list_sessions (limit: 200), який хаб записав файлом. Решту джерел обгортка бере сама:
#   · strw-state — знімок origin/main через `git archive` (fetch перед ним), а не робоче дерево спільної копії:
#     його дерево буває замороженим або на чужій гілці (tri-194/195); у summary.state_source — sha знімка;
#   · PR п'яти репо — `gh pr list` (hub-dashboard-data.py --gh).
# Друкує шлях hub.json і його sha256. Код 2 — відмова (fetch не вдався, генератор відмовив): дашборд не чіпати.
# Знімок сесій, старший за SESSIONS_MAX_MIN хвилин, — відмова: забутий /tmp/hub-sessions.json дав би старі сесії
# під свіжим часом генерації. Нічого не публікує: завантаження в Dashboard — крок сесії, references/hub-dashboard.md.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${STRW_ROOT:-${HOME}/Developer/STRW}"
STATE_REPO="${ROOT}/strw-state"
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    printf 'usage: hub-dashboard-refresh.sh <sessions.json>  (вихід list_sessions, limit: 200)\n' >&2
    exit 2
fi
SESSIONS="$1"
SESSIONS_MAX_MIN=30
if [ -n "$(find "${SESSIONS}" -mmin +"${SESSIONS_MAX_MIN}" 2>/dev/null)" ]; then
    printf 'ERROR: знімок сесій %s старший за %s хв — зніми list_sessions (limit: 200) заново; дашборд не оновлено (код 2)\n' "${SESSIONS}" "${SESSIONS_MAX_MIN}" >&2
    exit 2
fi
if ! git -C "${STATE_REPO}" fetch -q origin main < /dev/null; then
    printf 'ERROR: git fetch origin main у %s не вдався — знімок state був би старим; дашборд не оновлено (код 2)\n' "${STATE_REPO}" >&2
    exit 2
fi
SHA="$(git -C "${STATE_REPO}" rev-parse origin/main)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hub-dashboard.XXXXXX")"
mkdir "${WORK}/state" "${WORK}/out"
if ! git -C "${STATE_REPO}" cat-file -e "${SHA}:engine/items" 2>/dev/null; then
    printf 'ERROR: у strw-state %s немає engine/items; дашборд не оновлено (код 2)\n' "${SHA:0:7}" >&2
    exit 2
fi
# triage/open без жодної картки git не зберігає — це справжні «0 відкритих», а не відмова
PATHS="engine/items"
if git -C "${STATE_REPO}" cat-file -e "${SHA}:triage/open" 2>/dev/null; then PATHS="${PATHS} triage/open"; else mkdir -p "${WORK}/state/triage/open"; fi
# shellcheck disable=SC2086 — PATHS: два відомі шляхи без пробілів
git -C "${STATE_REPO}" archive "${SHA}" ${PATHS} | tar -x -C "${WORK}/state"
NOW="$(date -u +%Y-%m-%dT%H:%MZ)"
python3 "${HERE}/hub-dashboard-data.py" --state "${WORK}/state" --sessions "${SESSIONS}" --gh \
    --out "${WORK}/out" --now "${NOW}" --state-label "strw-state origin/main @ ${SHA:0:7}" < /dev/null
printf 'hub.json: %s\nsha256: %s\n' "${WORK}/out/hub.json" "$(shasum -a 256 "${WORK}/out/hub.json" | cut -d' ' -f1)"
