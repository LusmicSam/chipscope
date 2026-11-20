// chipscope app shell: router, live stream, replay timeline, load buttons, side panel.
import { S, MAX_FRAMES, current, h, heatGradientCSS, post, clearFlows, hideTip, fmtW } from './lib.js';
import { macView, socView } from './views_map.js';
import { clusterView, coreView, gpuView, memoryView, atlasView, sensorsView } from './views_detail.js';

const $ = (id) => document.getElementById(id);
const err = $('err');
function showError(msg) { err.textContent = msg; err.style.display = 'block'; }
window.addEventListener('error', (e) => showError(`JS error: ${e.message}\n${e.filename}:${e.lineno}`));
window.addEventListener('unhandledrejection', (e) => showError(`JS error: ${e.reason}`));

const ROUTES = [
  [/^\/mac$/, () => macView()],
  [/^\/soc$/, () => socView()],
  [/^\/cluster\/([\w.]+)$/, (m) => clusterView(m[1])],
  [/^\/core\/([\w.]+)$/, (m) => coreView(m[1])],
  [/^\/gpu$/, () => gpuView()],
  [/^\/memory$/, () => memoryView()],
  [/^\/atlas$/, () => atlasView()],
  [/^\/sensors$/, () => sensorsView()],
];

let view = null;

function route() {
  const path = (location.hash || '#/soc').slice(1);
  let next = null;
  for (const [re, make] of ROUTES) { const m = path.match(re); if (m) { next = make(m); break; } }
  if (!next) { location.hash = '#/soc'; return; }
  if (view && view.unmount) view.unmount();
  clearFlows();
  hideTip();
  S.sel = null;
  const stage = $('stage');
  stage.replaceChildren();
  stage.scrollTop = 0;
  view = next;
  view.mount(stage);
  // breadcrumbs + tabs
  const cr = $('crumbs');
  cr.replaceChildren();
  const crumbs = view.crumbs();
  crumbs.forEach(([label, href], i) => {
    if (i) h('span', { class: 'sep' }, cr, '›');
    h('a', { href, class: i === crumbs.length - 1 ? 'here' : '' }, cr, label);
  });
  for (const a of document.querySelectorAll('#tabs a')) a.classList.toggle('on', a.dataset.tab === view.tab);
  render();
}

function render() {
  const f = current();
  if (!f || !view) return;
  try {
    view.update(f);
    const side = $('side');
    const keep = side.scrollTop;
    side.replaceChildren();
    view.side(f, side);
    side.scrollTop = keep;
  } catch (e) {
    showError(`render: ${e.message}\n${(e.stack || '').split('\n').slice(0, 3).join('\n')}`);
  }
  drawTimeline();
  drawLoads(f);
}

// ------------------------------------------------------------------ stream
function connect() {
  const es = new EventSource('/api/stream');
  es.addEventListener('frame', (ev) => {
    const f = JSON.parse(ev.data);
    S.frames.push(f);
    if (S.frames.length > MAX_FRAMES) { S.frames.shift(); if (!S.live) S.cursor = Math.max(0, S.cursor - 1); }
    $('conn').textContent = 'live · 4/s';
    $('conn').className = '';
    if (S.live) render(); else drawTimeline();
  });
  es.addEventListener('probe', (ev) => {
    window.dispatchEvent(new CustomEvent('chipscope:probe', { detail: JSON.parse(ev.data) }));
  });
  es.onerror = () => { $('conn').textContent = 'disconnected · retrying'; $('conn').className = 'bad'; };
}

// ------------------------------------------------------------------ timeline (record & replay)
const tl = $('tl');
const socPower = (f) => f.cpu_w + f.gpu.w + f.ane.w + f.mem.dram_w;
function drawTimeline() {
  const dpr = devicePixelRatio || 1;
  const W = tl.clientWidth, H = tl.clientHeight;
  if (!W) return;
  if (tl.width !== W * dpr) { tl.width = W * dpr; tl.height = H * dpr; }
  const c = tl.getContext('2d');
  c.setTransform(dpr, 0, 0, dpr, 0, 0);
  c.clearRect(0, 0, W, H);
  const fr = S.frames;
  if (fr.length < 2) return;
  const vals = fr.map(socPower);
  const max = Math.max(5, ...vals);
  c.beginPath();
  vals.forEach((v, i) => { const x = W * i / (MAX_FRAMES - 1), y = H - 3 - (H - 6) * v / max; i ? c.lineTo(x, y) : c.moveTo(x, y); });
  c.strokeStyle = '#c3c2b7';
  c.lineWidth = 1.5;
  c.stroke();
  const idx = S.live ? fr.length - 1 : S.cursor;
  const x = W * idx / (MAX_FRAMES - 1);
  c.fillStyle = S.live ? '#0ca30c' : '#fab219';
  c.fillRect(x - 1, 0, 2, H);
  const f = current();
  const ago = (fr[fr.length - 1].t - f.t);
  $('when').textContent = S.live ? `now · ${fmtW(socPower(f))}` : `${ago.toFixed(0)} s ago · ${fmtW(socPower(f))}`;
}
function scrub(e) {
  const r = tl.getBoundingClientRect();
  const i = Math.round((e.clientX - r.left) / r.width * (MAX_FRAMES - 1));
  if (i >= S.frames.length - 1) { setLive(true); return; }
  S.live = false;
  S.cursor = Math.max(0, i);
  $('live').classList.remove('on');
  $('live').textContent = '▶ Back to live';
  render();
}
function setLive(on) {
  S.live = on;
  if (on) S.cursor = -1;
  $('live').classList.toggle('on', on);
  $('live').textContent = on ? '● Live' : '▶ Back to live';
  render();
}
let dragging = false;
tl.addEventListener('pointerdown', (e) => { dragging = true; tl.setPointerCapture(e.pointerId); scrub(e); });
tl.addEventListener('pointermove', (e) => { if (dragging) scrub(e); });
tl.addEventListener('pointerup', () => { dragging = false; });
$('live').addEventListener('click', () => setLive(true));

// ------------------------------------------------------------------ load buttons
const LOADS = [['cpu-p', 'P-cores'], ['cpu-e', 'E-cores'], ['mem', 'Memory'], ['gpu', 'GPU'], ['ane', 'Neural Engine'], ['ssd', 'SSD']];
const loadBtns = {};
h('span', { style: 'color:#898781' }, $('loads'), 'Load:');
for (const [k, label] of LOADS) {
  loadBtns[k] = h('button', { class: 'lb', title: `Run a 20 s ${label} load and watch it light up`, onclick: async () => {
    const f = S.frames[S.frames.length - 1];
    const on = f && f.loads && f.loads[k];
    await post(on ? `/api/load/stop?kind=${k}` : `/api/load/${k}?seconds=20`);
  } }, $('loads'), label);
}
function drawLoads(f) {
  const L = (S.frames[S.frames.length - 1] || f).loads || {};
  const now = Date.now() / 1000;
  for (const [k, label] of LOADS) {
    const on = L[k];
    loadBtns[k].classList.toggle('on', !!on);
    loadBtns[k].textContent = on ? `${label} · ${Math.max(0, Math.round(on.until - now))}s` : label;
  }
}

// ------------------------------------------------------------------ controls
$('heatbar').style.background = heatGradientCSS();
$('heatBy').addEventListener('change', (e) => { S.heatBy = e.target.value; render(); });
$('explain').addEventListener('click', () => { S.explain = !S.explain; $('explain').classList.toggle('on', S.explain); render(); });
window.addEventListener('chipscope:select', render);
window.addEventListener('hashchange', route);
window.addEventListener('resize', drawTimeline);

// ------------------------------------------------------------------ boot
async function boot() {
  S.topo = await (await fetch('/api/topology')).json();
  $('machine').textContent = `${S.topo.chip} · ${S.topo.model}`;
  try {
    const hist = await (await fetch('/api/history?seconds=300')).json();
    S.frames = hist.slice(-MAX_FRAMES);
  } catch (e) { /* start empty */ }
  route();
  // ?snapshot: render from history only (no live stream) - used by headless screenshots.
  if (new URLSearchParams(location.search).has('snapshot')) {
    $('conn').textContent = 'snapshot';
    window.dispatchEvent(new Event('chipscope:snapshot-ready'));
    return;
  }
  connect();
}
boot().catch((e) => showError('boot: ' + e.message));
