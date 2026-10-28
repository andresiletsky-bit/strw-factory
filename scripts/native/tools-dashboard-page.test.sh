#!/usr/bin/env bash
# tools-dashboard-page.test.sh — логіка сторінки Dashboard реєстру (scripts/native/tools-dashboard/index.html):
# фільтр статусу, пошук, «лише без активного» і позначка застарілого виміру — чисті функції між маркерами
# logic:begin / logic:end, виконані node. Червоні: кожен предикат має випадок, де інвертована умова дає інше;
# проводка — увесь скрипт сторінки виконується із заглушками dash і DOM, фільтри — через її обробники (рев'ю codex #38).
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

// Проводка — виконанням, не пошуком тексту (рев'ю codex #38: «!toolVisible(...)» містить «toolVisible(...)»).
// Увесь <script> сторінки біжить із заглушками dash і DOM; фільтри вмикаються через її власні обробники подій.
const el = () => ({ className: '', textContent: '', children: [],
  appendChild(c) { this.children.push(c); return c; }, replaceChildren() { this.children = []; } });
const inputs = {}, handlers = {}, draws = {}, targets = {};
const document = { createElement: el, querySelectorAll(sel) {
  inputs[sel] = inputs[sel] || { value: '', checked: false, addEventListener(ev, fn) { handlers[sel] = fn; } };
  return [inputs[sel]]; } };
const DATA = {
  summary: [{ tools: 3 }],
  tasks: [{ task: 'code-build', active: 1 }, { task: 'legal', active: '0' }, { task: 'deck', active: 0 }],
  tools: [
    { id: 'codex-cli', name: 'Codex CLI', tasks: 'code-review-6a', status: 'active', stale: true, measured_result: 'available' },
    { id: 'figma-mcp', name: 'Figma', tasks: 'design-mockup', status: 'candidate', stale: 'false', measured_result: 'needs-auth' },
    { id: 'metricool-mcp', name: 'Metricool', tasks: 'growth-queue', status: 'forbidden', stale: 'true', measured_result: 'available' },
  ] };
const dash = { data: (id) => ({ status: 'ok', data: DATA[id] }),
  draw(name, fn) { if (fn) { draws[name] = fn; targets[name] = targets[name] || el(); } if (draws[name]) draws[name](targets[name]); } };
const script = page.slice(page.lastIndexOf('<script>') + 8, page.lastIndexOf('</script>'));
new Function('document', 'dash', script)(document, dash);
const ids = (name) => (targets[name] ? targets[name].children.map((tr) => tr.children[0].textContent).join(',') : '<нема>');
const fire = (sel, prop, v) => { inputs[sel][prop] = v; handlers[sel](); };
eq('малювання: усі інструменти без фільтра', ids('tools-body'), 'codex-cli,figma-mcp,metricool-mcp');
fire('#tools-status', 'value', 'active');
eq('малювання: фільтр статусу active', ids('tools-body'), 'codex-cli');
fire('#tools-status', 'value', ''); fire('#tools-q', 'value', '  FIGMA ');
eq('малювання: пошук (обрізано, без регістру)', ids('tools-body'), 'figma-mcp');
fire('#tools-q', 'value', '');
const ageCls = targets['tools-body'].children.map((tr) => tr.children[7].className.includes('tr-stale'));
eq('малювання: позначка застарілого — true і «true», не «false»', ageCls.join(','), 'true,false,true');
eq('малювання: усі типи задач без фільтра', ids('tasks-body'), 'code-build,legal,deck');
fire('#tasks-gaps', 'checked', true);
eq('малювання: «лише без активного» (0 і «0»)', ids('tasks-body'), 'legal,deck');
for (const copy of ['r.stale ===', 'r.status === statusPick', 'Number(r.active)']) {
  rest.includes(copy) ? bad('копія умови поза logic: ' + copy) : ok('умова «' + copy + '» живе лише в logic');
}
console.log('\n' + pass + ' PASS · ' + fail + ' FAIL');
process.exit(fail ? 1 : 0);
JS
