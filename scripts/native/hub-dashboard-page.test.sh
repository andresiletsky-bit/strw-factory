#!/usr/bin/env bash
# hub-dashboard-page.test.sh — сторінка Dashboard хаба (scripts/native/hub-dashboard/index.html) на справжньому
# hub.json: генератор будує його з fixtures/hub, весь <script> сторінки біжить під node із заглушками dash і DOM.
# Перевіряє: сім dash.calc ділять hub.json рівно за полем table; кожна позначка data-source / data-field /
# data-row-key / data-draw розмітки відповідає колонці або drawing, які справді є (розбіжність генератора й сторінки
# — червоно); фільтри — через власні обробники сторінки; предикати між logic:begin/end — з червоними випадками.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAGE="${HERE}/hub-dashboard/index.html"
FX="${HERE}/fixtures/hub"
if ! command -v node >/dev/null 2>&1; then
    printf 'SKIP · немає node — сторінку не виконано (command -v node порожньо)\n'; exit 0
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hdp-test.XXXXXX")"; trap 'rm -rf "${TMP}"' EXIT
if ! python3 "${HERE}/hub-dashboard-data.py" --state "${FX}/state" --sessions "${FX}/sessions.json" --prs-dir "${FX}/prs" \
        --out "${TMP}" --now 2026-10-28T09:00Z < /dev/null >/dev/null; then
    printf 'FAIL · генератор не зібрав hub.json з фікстури\n\n0 PASS · 1 FAIL\n'; exit 1
fi
node - "${PAGE}" "${TMP}/hub.json" <<'JS'
const fs = require('fs');
const page = fs.readFileSync(process.argv[2], 'utf8');
const HUB = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
let pass = 0, fail = 0;
const ok = (n) => { pass++; console.log('PASS · ' + n); };
const bad = (n, d) => { fail++; console.log('FAIL · ' + n + (d ? '\n' + d : '')); };
const eq = (name, got, want) => (got === want ? ok(name) : bad(name, 'got ' + got + ', want ' + want));
const finish = () => { console.log('\n' + pass + ' PASS · ' + fail + ' FAIL'); process.exit(fail ? 1 : 0); };

// --- 1. предикати logic ------------------------------------------------------------------------------
const B = '// logic:begin', E = '// logic:end';
const nb = page.split(B).length - 1, ne = page.split(E).length - 1;
if (nb !== 1 || ne !== 1) { bad('маркери logic:begin / logic:end — рівно по одному', 'begin=' + nb + ' end=' + ne); finish(); }
const src = page.slice(page.indexOf('\n', page.indexOf(B)) + 1, page.indexOf(E));
const rest = page.slice(0, page.indexOf(B)) + page.slice(page.indexOf(E));
const L = new Function(src + '\nreturn { yes, prVisible, sessionVisible, triageVisible, itemVisible, checksTone, stateTone };')();
eq('yes: true', L.yes(true), true);
eq('yes: «true» з файла', L.yes('true'), true);
eq('yes: false', L.yes(false), false);
eq('yes: «false»', L.yes('false'), false);
eq('PR: без фільтра видно зелений', L.prVisible({ checks: 'pass' }, false), true);
eq('PR: «лише червоні» ховає pending', L.prVisible({ checks: 'pending' }, true), false);
eq('PR: «лише червоні» показує fail', L.prVisible({ checks: 'fail' }, true), true);
eq('сесія: тиху сховано', L.sessionVisible({ idle: true }, true), false);
eq('сесія: тиху «true» сховано', L.sessionVisible({ idle: 'true' }, true), false);
eq('сесія: не тиху видно', L.sessionVisible({ idle: false }, true), true);
eq('сесія: без фільтра тиху видно', L.sessionVisible({ idle: true }, false), true);
eq('тріаж: строк минув — видно', L.triageVisible({ overdue_days: 1 }, true), true);
eq('тріаж: «0» — сховано', L.triageVisible({ overdue_days: '0' }, true), false);
eq('тріаж: без фільтра — видно', L.triageVisible({ overdue_days: 0 }, false), true);
const it = { id: 'factory.hub-dashboard', lane: 'factory-tooling', product: 'factory', state: 'done' };
eq('елемент: «крім done» ховає done', L.itemVisible(it, 'open', ''), false);
eq('елемент: «крім done» показує ready', L.itemVisible({ ...it, state: 'ready' }, 'open', ''), true);
eq('елемент: «усі» показує done', L.itemVisible(it, '', ''), true);
eq('елемент: точний стан', L.itemVisible(it, 'done', ''), true);
eq('елемент: інший стан — сховано', L.itemVisible(it, 'ready', ''), false);
eq('елемент: пошук за смугою', L.itemVisible(it, '', 'tooling'), true);
eq('елемент: пошук без збігу', L.itemVisible(it, '', 'pact'), false);
eq('тон перевірок fail', L.checksTone('fail'), 'hb-bad');
eq('тон перевірок none', L.checksTone('none'), 'hb-muted');
eq('тон стану blocked', L.stateTone('blocked'), 'hb-bad');

// --- 2. увесь скрипт сторінки із заглушками ---------------------------------------------------------
const el = () => ({ className: '', textContent: '', children: [], dataset: {}, href: '',
  appendChild(c) { this.children.push(c); return c; }, replaceChildren() { this.children = []; } });
const inputs = {}, handlers = {}, draws = {}, targets = {}, calcs = {};
const document = { createElement: el, querySelectorAll(sel) {
  inputs[sel] = inputs[sel] || { value: '', checked: false, addEventListener(ev, fn) { handlers[sel] = fn; } };
  return [inputs[sel]]; } };
// стан контролів, як у розмітці (checked / перша option) — сторінка читає їх лише в обробниках
inputs['#sessions-quiet'] = { value: '', checked: true, addEventListener(ev, fn) { handlers['#sessions-quiet'] = fn; } };
inputs['#items-state'] = { value: 'open', checked: false, addEventListener(ev, fn) { handlers['#items-state'] = fn; } };
const dash = {
  calc(id, spec) { if (calcs[id]) bad('dash.calc двічі: ' + id); calcs[id] = spec; },
  data(id) {
    if (id === 'hub') return { status: 'ok', data: HUB };
    if (!calcs[id]) return { status: 'missing', data: [] };
    return { status: 'ok', data: calcs[id].fn(...calcs[id].inputs.map((i) => dash.data(i).data)) };
  },
  draw(name, fn) { if (fn) { draws[name] = fn; targets[name] = targets[name] || el(); } if (draws[name]) draws[name](targets[name]); },
};
// посилання лише на github: URL із даних не стає javascript:-посиланням
HUB.find((r) => r.key === 'pact-backend#72').url = 'javascript:alert(1)';
const script = page.slice(page.lastIndexOf('<script>') + 8, page.lastIndexOf('</script>'));
new Function('document', 'dash', script)(document, dash);

const TABLES = ['summary', 'sessions', 'prs', 'repos', 'triage', 'items', 'lanes'];
eq('dash.calc — рівно сім таблиць', Object.keys(calcs).sort().join(','), TABLES.slice().sort().join(','));
for (const t of TABLES) {
  const got = calcs[t] ? dash.data(t).data : [];
  const want = HUB.filter((r) => r.table === t);
  (got.length === want.length && got.length > 0 && got.every((r) => r.table === t))
    ? ok('calc ' + t + ': ' + got.length + ' рядків, усі table=' + t)
    : bad('calc ' + t + ' ділить не за своїм table', 'got ' + got.length + ', want ' + want.length);
  if (calcs[t] && JSON.stringify(calcs[t].inputs) !== '["hub"]') bad('calc ' + t + ': inputs не [hub]');
  if (calcs[t] && !String(calcs[t].fn).includes("'" + t + "'")) bad('calc ' + t + ': літерал таблиці не в тексті fn');
}

// --- 3. розмітка ↔ дані ----------------------------------------------------------------------------------
const cols = (t) => new Set(HUB.filter((r) => r.table === t).flatMap((r) => Object.keys(r)));
const html = page.slice(0, page.lastIndexOf('<script>'));
const srcs = [...html.matchAll(/data-source="([^"]+)"/g)].map((m) => m[1]);
const unknownSrc = srcs.filter((s) => !TABLES.includes(s));
eq('кожен data-source — одна з семи calc', unknownSrc.join(','), '');
const tables = [...html.matchAll(/<table[^>]*data-source="([^"]+)"[^>]*data-row-key="([^"]+)"[^>]*>([\s\S]*?)<\/table>/g)];
eq('таблиць із data-row-key у розмітці — 6', tables.length, 6);
for (const [, t, key, body] of tables) {
  const c = cols(t);
  c.has(key) ? ok('ключ ' + t + '.' + key + ' — колонка даних') : bad('ключ ' + t + '.' + key + ' немає в даних');
  const ths = [...body.matchAll(/<th[^>]*data-field="([^"]+)"/g)].map((m) => m[1]);
  const miss = ths.filter((f) => !c.has(f));
  eq('заголовки ' + t + ' — колонки даних', miss.join(','), '');
  const keys = HUB.filter((r) => r.table === t).map((r) => r[key]);
  eq('ключ ' + t + '.' + key + ' унікальний', new Set(keys).size, keys.length);
}
const sumFields = [...html.matchAll(/data-source="summary" data-field="([^"]+)"/g)].map((m) => m[1]);
eq('позначок summary у розмітці', sumFields.length, 20);
eq('кожне поле summary з розмітки є в даних', sumFields.filter((f) => !cols('summary').has(f)).join(','), '');
const drawNames = [...html.matchAll(/data-draw="([^"]+)"/g)].map((m) => m[1]);
eq('кожен data-draw має dash.draw', drawNames.filter((n) => !draws[n]).join(','), '');
eq('кожен dash.draw має data-draw', Object.keys(draws).filter((n) => !drawNames.includes(n)).join(','), '');
for (const sel of ['#prs-red', '#sessions-quiet', '#triage-late', '#items-q', '#items-state']) {
  const id = sel.slice(1);
  (html.includes('id="' + id + '"') && handlers[sel]) ? ok('контрол ' + sel + ': є в розмітці і має обробник') : bad('контрол ' + sel + ' не проведено');
}

// --- 4. малювання і фільтри через обробники сторінки --------------------------------------------------
const col0 = (name) => (targets[name] ? targets[name].children.map((tr) => tr.children[0].textContent || (tr.children[0].children[0] || {}).textContent).join(',') : '<нема>');
const keysOf = (name) => (targets[name] ? targets[name].children.map((tr) => tr.dataset.key).join(',') : '<нема>');
const fire = (sel, prop, v) => { inputs[sel][prop] = v; handlers[sel](); };
eq('шапка: сесій 4', targets['h-sessions'].textContent, '4');
eq('плитка: червоних PR 2', targets['t-fail'].textContent, '2');
eq('поріг тиші — з summary', targets['s-idle-limit'].textContent, '24');
eq('поріг PR — з summary', targets['p-stale-limit'].textContent, '7');
eq('підвал: сесії станом на найсвіжішу активність', targets['f-sess-at'].textContent, '2026-10-28T08:59Z');
eq('repos: п\'ять репо', col0('repos-body'), 'strw-ops,strw-factory,strw-state,pact-ios,pact-backend');
eq('PR: усі шість', keysOf('prs-body'), 'strw-ops#12,strw-ops#36,strw-factory#40,pact-ios#240,pact-backend#71,pact-backend#72');
eq('PR: текст посилання = ключ', targets['prs-body'].children[0].children[0].children[0].textContent, 'strw-ops#12');
eq('PR: посилання лише на github', targets['prs-body'].children[0].children[0].children[0].href, 'https://github.com/andresiletsky-bit/strw-ops/pull/12');
eq('PR: застарілий підсвічено, свіжий ні', targets['prs-body'].children.slice(0, 2).map((tr) => tr.children[4].className.includes('hb-old')).join(','), 'true,false');
eq('PR: URL не з github → «#»', targets['prs-body'].children[5].children[0].children[0].href, '#');
fire('#prs-red', 'checked', true);
eq('PR: «лише червоні»', keysOf('prs-body'), 'strw-ops#12,pact-ios#240');
eq('сесії: тихі сховано за замовчуванням', keysOf('sessions-body'), 'local_eeee,local_aaaa');
fire('#sessions-quiet', 'checked', false);
eq('сесії: усі чотири', keysOf('sessions-body'), 'local_eeee,local_aaaa,local_dddd,local_bbbb');
eq('тріаж: усі', col0('triage-body'), 'tri-001,tri-002,tri-003');
fire('#triage-late', 'checked', true);
eq('тріаж: лише зі строком, що минув', col0('triage-body'), 'tri-001');
eq('елементи: крім done за замовчуванням', col0('items-body'), 'a.one,b.two,c.three,d.four,f.six');
fire('#items-state', 'value', 'done');
eq('елементи: лише done', col0('items-body'), 'e.five');
fire('#items-state', 'value', ''); fire('#items-q', 'value', '  LANE-TWO ');
eq('елементи: пошук (обрізано, без регістру)', col0('items-body'), 'c.three,d.four,f.six');
eq('смуги', col0('lanes-body'), 'lane-one,lane-two');
for (const copy of ["r.checks === 'fail'", "r.state !== 'done'", '!yes(r.idle)']) {
  const inLogic = src.includes(copy), outside = rest.includes(copy);
  (inLogic && !outside) ? ok('умова «' + copy + '» живе лише в logic') : bad('умова «' + copy + '» поза logic або зникла');
}
finish();
JS
