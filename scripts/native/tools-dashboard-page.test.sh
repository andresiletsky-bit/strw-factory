#!/usr/bin/env bash
# tools-dashboard-page.test.sh — логіка сторінки Dashboard реєстру (scripts/native/tools-dashboard/index.html):
# фільтр статусу, пошук, «лише без активного» і позначка застарілого виміру — чисті функції між маркерами
# logic:begin / logic:end, виконані node. Червоні: кожен предикат має випадок, де інвертована умова дає інше;
# проводка — малювання таблиць викликає саме ці функції, а не власну копію умови (рев'ю codex #38: U01, U02).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAGE="${HERE}/tools-dashboard/index.html"
if ! command -v node >/dev/null 2>&1; then
    printf 'SKIP · немає node — логіку сторінки не виконано (command -v node порожньо)\n'; exit 0
fi
node - "${PAGE}" <<'JS'
const fs = require('fs');
const page = fs.readFileSync(process.argv[2], 'utf8');
let pass = 0, fail = 0;
const ok = (n) => { pass++; console.log('PASS · ' + n); };
const bad = (n, d) => { fail++; console.log('FAIL · ' + n + (d ? '\n' + d : '')); };
const B = '// logic:begin', E = '// logic:end';
const nb = page.split(B).length - 1, ne = page.split(E).length - 1;
if (nb !== 1 || ne !== 1) {
  bad('маркери logic:begin / logic:end — рівно по одному', 'begin=' + nb + ' end=' + ne);
  console.log('\n' + pass + ' PASS · ' + fail + ' FAIL'); process.exit(1);
}
const src = page.slice(page.indexOf('\n', page.indexOf(B)) + 1, page.indexOf(E)); // від рядка після маркера
const rest = page.slice(0, page.indexOf(B)) + page.slice(page.indexOf(E));
const L = new Function(src + '\nreturn { isStale, toolVisible, taskVisible };')();
const eq = (name, got, want) => (got === want ? ok(name) : bad(name, 'got ' + got + ', want ' + want));

eq('isStale: true', L.isStale({ stale: true }), true);
eq('isStale: рядок «true» (дані з файла)', L.isStale({ stale: 'true' }), true);
eq('isStale: false', L.isStale({ stale: false }), false);
eq('isStale: рядок «false»', L.isStale({ stale: 'false' }), false);
eq('isStale: поля немає', L.isStale({}), false);

const codex = { id: 'codex-cli', name: 'Codex CLI', tasks: 'code-review-6a, code-rescue', status: 'active' };
const figma = { id: 'figma-mcp', name: 'Figma', tasks: 'design-mockup', status: 'candidate' };
eq('статус active: активний видно', L.toolVisible(codex, 'active', ''), true);
eq('статус active: кандидата сховано', L.toolVisible(figma, 'active', ''), false);
eq('статус не вибрано: видно будь-який', L.toolVisible(figma, '', ''), true);
eq('пошук за задачею', L.toolVisible(codex, '', 'review'), true);
eq('пошук за назвою (без регістру)', L.toolVisible(codex, '', 'codex cli'), true);
eq('пошук без збігу — сховано', L.toolVisible(codex, '', 'figma'), false);
eq('статус і пошук разом: обидва мають збігтися', L.toolVisible(figma, 'active', 'figma'), false);

eq('без фільтра — задачу з активним видно', L.taskVisible({ active: 2 }, false), true);
eq('«лише без активного»: 0 — видно', L.taskVisible({ active: 0 }, true), true);
eq('«лише без активного»: рядок «0» — видно', L.taskVisible({ active: '0' }, true), true);
eq('«лише без активного»: 2 — сховано', L.taskVisible({ active: 2 }, true), false);

for (const call of ['toolVisible(r, statusPick, q)', 'taskVisible(r, gapsOnly)', 'isStale(r)']) {
  rest.includes(call) ? ok('проводка: малювання викликає ' + call) : bad('проводка: немає виклику ' + call);
}
for (const copy of ['r.stale ===', 'r.status === statusPick', 'Number(r.active)']) {
  rest.includes(copy) ? bad('копія умови поза logic: ' + copy) : ok('умова «' + copy + '» живе лише в logic');
}
console.log('\n' + pass + ' PASS · ' + fail + ' FAIL');
process.exit(fail ? 1 : 0);
JS
