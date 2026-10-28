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
# Нічого не публікує: завантаження в Dashboard — крок сесії, references/native-outputs.md § «Живий Dashboard хаба».
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${STRW_ROOT:-${HOME}/Developer/STRW}"
STATE_REPO="${ROOT}/strw-state"
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    printf 'usage: hub-dashboard-refresh.sh <sessions.json>  (вихід list_sessions, limit: 200)\n' >&2
    exit 2
fi
SESSIONS="$1"
if ! git -C "${STATE_REPO}" fetch -q origin main < /dev/null; then
    printf 'ERROR: git fetch origin main у %s не вдався — знімок state був би старим; дашборд не оновлено (код 2)\n' "${STATE_REPO}" >&2
    exit 2
fi
SHA="$(git -C "${STATE_REPO}" rev-parse origin/main)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hub-dashboard.XXXXXX")"
mkdir "${WORK}/state" "${WORK}/out"
git -C "${STATE_REPO}" archive "${SHA}" triage/open engine/items | tar -x -C "${WORK}/state"
NOW="$(date -u +%Y-%m-%dT%H:%MZ)"
python3 "${HERE}/hub-dashboard-data.py" --state "${WORK}/state" --sessions "${SESSIONS}" --gh \
    --out "${WORK}/out" --now "${NOW}" --state-label "strw-state origin/main @ ${SHA:0:7}" < /dev/null
printf 'hub.json: %s\nsha256: %s\n' "${WORK}/out/hub.json" "$(shasum -a 256 "${WORK}/out/hub.json" | cut -d' ' -f1)"
