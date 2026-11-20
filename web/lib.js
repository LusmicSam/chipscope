// Shared state + helpers for chipscope's UI. No dependencies.

export const S = {
  topo: null,
  frames: [],          // client-side history (for replay)
  live: true,
  cursor: -1,          // index into frames when replaying
  heatBy: 'busy',
  explain: false,
  sel: null,           // selected block id (side panel)
  atlas: null,
  probe: null,         // probe progress
};
export const MAX_FRAMES = 1200;  // 5 min at 4/s

export function current() {
  if (!S.frames.length) return null;
  return S.live || S.cursor < 0 ? S.frames[S.frames.length - 1] : S.frames[Math.min(S.cursor, S.frames.length - 1)];
}

// ------------------------------------------------------------------ DOM
const SVGNS = 'http://www.w3.org/2000/svg';
export function svg(tag, attrs = {}, parent = null, text = null) {
  const e = document.createElementNS(SVGNS, tag);
  for (const [k, v] of Object.entries(attrs)) if (v !== null && v !== undefined) e.setAttribute(k, v);
  if (text !== null) e.textContent = text;
  if (parent) parent.appendChild(e);
  return e;
}
export function h(tag, attrs = {}, parent = null, text = null) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') e.className = v;
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else if (v !== null && v !== undefined) e.setAttribute(k, v);
  }
  if (text !== null) e.textContent = text;
  if (parent) parent.appendChild(e);
  return e;
}
export function kv(parent, rows) {
  const g = h('div', { class: 'kv' }, parent);
  for (const [k, v] of rows) {
    if (v === null || v === undefined) continue;
    h('div', { class: 'k' }, g, k);
    h('div', { class: 'v' }, g, String(v));
  }
  return g;
}

// ------------------------------------------------------------------ colour
// Semantic heat ramp (idle slate -> deep red -> red -> hot orange). Always shown with its legend.
const HEAT = [[0, [42, 44, 48]], [0.15, [74, 38, 48]], [0.35, [138, 31, 44]], [0.6, [201, 38, 43]],
  [0.85, [240, 65, 43]], [1, [255, 106, 61]]];
export function heat(x) {
  if (x === null || x === undefined || Number.isNaN(x)) return '#202124';
  x = Math.max(0, Math.min(1, x));
  for (let i = 1; i < HEAT.length; i++) {
    const [t1, c1] = HEAT[i];
    const [t0, c0] = HEAT[i - 1];
    if (x <= t1) {
      const f = (x - t0) / (t1 - t0);
      const c = c0.map((v, j) => Math.round(v + (c1[j] - v) * f));
      return `rgb(${c[0]},${c[1]},${c[2]})`;
    }
  }
  return 'rgb(255,106,61)';
}
export function heatGradientCSS() {
  return 'linear-gradient(90deg,' + HEAT.map(([t, c]) => `rgb(${c.join(',')}) ${t * 100}%`).join(',') + ')';
}
// Sequential blue (latency matrix): light = fast, dark = slow on the dark surface.
const BLUE = ['#cde2fb', '#9ec5f4', '#6da7ec', '#3987e5', '#256abf', '#184f95', '#104281', '#0d366b'];
export function blue(x) {
  x = Math.max(0, Math.min(1, x));
  return BLUE[Math.min(BLUE.length - 1, Math.floor(x * BLUE.length))];
}
// Block colour: share of a block's capacity, linear (so red really means busy).
export const lin = (v, peak) => (v > 0 ? Math.min(1, v / peak) : 0);
// Flow width/speed: bandwidth -> 0..1 on a log scale (1 MB/s .. peak), so small streams stay visible.
export function bwHeat(bps, peak = 200e9) {
  if (!bps || bps <= 0) return 0;
  return Math.max(0, Math.min(1, Math.log10(1 + bps / 1e6) / Math.log10(1 + peak / 1e6)));
}

// ------------------------------------------------------------------ format
export function fmtBps(b) {
  if (b === null || b === undefined) return '—';
  if (b >= 1e9) return (b / 1e9).toFixed(b >= 1e10 ? 0 : 1) + ' GB/s';
  if (b >= 1e6) return (b / 1e6).toFixed(b >= 1e8 ? 0 : 1) + ' MB/s';
  if (b >= 1e3) return (b / 1e3).toFixed(0) + ' kB/s';
  return Math.round(b) + ' B/s';
}
export function fmtBytes(b) {
  if (b === null || b === undefined) return '—';
  if (b >= 2 ** 30) return (b / 2 ** 30).toFixed(b >= 10 * 2 ** 30 ? 1 : 2) + ' GiB';
  if (b >= 2 ** 20) return (b / 2 ** 20).toFixed(0) + ' MiB';
  if (b >= 1024) return (b / 1024).toFixed(0) + ' KiB';
  return b + ' B';
}
export function fmtW(w) {
  if (w === null || w === undefined) return '—';
  if (w < 0.1) return (w * 1000).toFixed(0) + ' mW';
  return w.toFixed(w < 10 ? 2 : 1) + ' W';
}
export const fmtPct = (x) => (x === null || x === undefined ? '—' : (x * 100).toFixed(x < 0.1 ? 1 : 0) + '%');
export function fmtNs(ns) {
  if (ns === null || ns === undefined) return '—';
  if (ns < 10) return ns.toFixed(2) + ' ns';
  if (ns < 1000) return ns.toFixed(0) + ' ns';
  if (ns < 1e6) return (ns / 1e3).toFixed(ns < 1e4 ? 2 : 0) + ' µs';
  if (ns < 1e9) return (ns / 1e6).toFixed(ns < 1e7 ? 2 : 0) + ' ms';
  return (ns / 1e9).toFixed(2) + ' s';
}
export const fmtMHz = (m) => (m ? (m >= 1000 ? (m / 1000).toFixed(2) + ' GHz' : m + ' MHz') : '—');

// ------------------------------------------------------------------ tooltip
const tipEl = () => document.getElementById('tip');
export function showTip(evt, c) {
  const t = tipEl();
  t.replaceChildren();
  if (c.value !== undefined) h('div', { class: 'tv' }, t, c.value);
  if (c.label) h('div', { class: 'tl' }, t, c.label);
  for (const [k, v] of c.rows || []) {
    if (v === null || v === undefined) continue;
    const r = h('div', { class: 'tr' }, t);
    h('span', {}, r, k);
    h('span', {}, r, String(v));
  }
  if (S.explain && c.explain) h('div', { class: 'tx' }, t, c.explain);
  if (c.src) h('div', { class: 'ts' }, t, c.src);
  t.style.display = 'block';
  moveTip(evt);
}
export function moveTip(evt) {
  const t = tipEl();
  const pad = 14;
  let x = evt.clientX + pad;
  let y = evt.clientY + pad;
  const r = t.getBoundingClientRect();
  if (x + r.width > innerWidth - 8) x = evt.clientX - r.width - pad;
  if (y + r.height > innerHeight - 8) y = evt.clientY - r.height - pad;
  t.style.left = x + 'px';
  t.style.top = y + 'px';
}
export function hideTip() { tipEl().style.display = 'none'; }
export function bindTip(el, fn) {
  el.addEventListener('pointerenter', (e) => { const c = fn(); if (c) showTip(e, c); });
  el.addEventListener('pointermove', (e) => { const c = fn(); if (c) showTip(e, c); });
  el.addEventListener('pointerleave', hideTip);
  el.setAttribute('tabindex', '0');
  el.addEventListener('focus', () => {
    const c = fn();
    if (!c) return;
    const r = el.getBoundingClientRect();
    showTip({ clientX: r.right, clientY: r.top }, c);
  });
  el.addEventListener('blur', hideTip);
}

// ------------------------------------------------------------------ flows (animated transport)
// Each flow is a path; dashes move along it at a speed set from its bandwidth.
const flows = new Set();
let lastT = performance.now();
export function addFlow(path, dir = 1) {
  const f = { path, dir, speed: 0, off: 0 };
  flows.add(f);
  return f;
}
export function setFlow(f, bps, peak = 200e9, widthMax = 9) {
  const x = bwHeat(bps, peak);
  if (x < 0.02) {
    f.path.style.opacity = 0;
    f.speed = 0;
    return;
  }
  f.path.style.opacity = 0.35 + 0.65 * x;
  f.path.setAttribute('stroke-width', (1.2 + widthMax * x).toFixed(1));
  f.path.setAttribute('stroke-dasharray', '3 9');
  f.speed = 12 + 140 * x;  // px per second
}
export function clearFlows() { flows.clear(); }
function tick(t) {
  const dt = Math.min(0.1, (t - lastT) / 1000);
  lastT = t;
  for (const f of flows) {
    if (!f.speed) continue;
    f.off -= f.speed * dt * f.dir;
    f.path.setAttribute('stroke-dashoffset', f.off.toFixed(1));
  }
  requestAnimationFrame(tick);
}
requestAnimationFrame(tick);

// ------------------------------------------------------------------ small line chart
// series: [{name, color, values[]}], one y-axis only. Hover = crosshair + all values.
export function lineChart(parent, opts) {
  const W = opts.width || 420, H = opts.height || 120, L = 62, R = 10, T = 8, B = 20;
  const root = svg('svg', { viewBox: `0 0 ${W} ${H}`, width: '100%', class: 'chart' }, parent);
  const grid = svg('g', {}, root);
  const lines = svg('g', {}, root);
  const cross = svg('line', { y1: T, y2: H - B, class: 'refline', style: 'display:none' }, root);
  const hit = svg('rect', { x: L, y: T, width: W - L - R, height: H - T - B, fill: 'transparent' }, root);
  let data = null;
  function draw(series, yMax, xLabel) {
    data = { series, yMax };
    grid.replaceChildren();
    lines.replaceChildren();
    const n = Math.max(...series.map((s) => s.values.length), 2);
    const ymax = yMax || Math.max(1e-9, ...series.flatMap((s) => s.values.filter((v) => v !== null)));
    for (let i = 0; i <= 2; i++) {
      const y = T + (H - T - B) * (1 - i / 2);
      svg('line', { x1: L, x2: W - R, y1: y, y2: y, class: 'gridline' }, grid);
      svg('text', { x: L - 6, y: y + 4, 'text-anchor': 'end', class: 'tiny' }, grid, opts.yFmt(ymax * i / 2));
    }
    svg('text', { x: L, y: H - 5, class: 'tiny' }, grid, xLabel || '');
    svg('text', { x: W - R, y: H - 5, 'text-anchor': 'end', class: 'tiny' }, grid, 'now');
    for (const s of series) {
      let d = '';
      s.values.forEach((v, i) => {
        if (v === null || v === undefined) return;
        const x = L + (W - L - R) * (i / (n - 1));
        const y = T + (H - T - B) * (1 - Math.min(1, v / ymax));
        d += (d ? 'L' : 'M') + x.toFixed(1) + ',' + y.toFixed(1);
      });
      svg('path', { d, class: 'series', stroke: s.color }, lines);
    }
  }
  hit.addEventListener('pointermove', (e) => {
    if (!data) return;
    const r = root.getBoundingClientRect();
    const px = (e.clientX - r.left) / r.width * W;
    const n = Math.max(...data.series.map((s) => s.values.length), 2);
    const i = Math.max(0, Math.min(n - 1, Math.round((px - L) / (W - L - R) * (n - 1))));
    const x = L + (W - L - R) * (i / (n - 1));
    cross.setAttribute('x1', x);
    cross.setAttribute('x2', x);
    cross.style.display = '';
    const ago = ((n - 1 - i) / 4).toFixed(1);
    showTip(e, {
      label: `${ago} s ago`,
      rows: data.series.map((s) => [s.name, s.values[i] === null || s.values[i] === undefined ? '—' : opts.yFmt(s.values[i])]),
    });
  });
  hit.addEventListener('pointerleave', () => { cross.style.display = 'none'; hideTip(); });
  return { draw, root };
}

// Last n frames up to the cursor (for history charts that follow replay).
export function windowFrames(n) {
  const end = S.live || S.cursor < 0 ? S.frames.length : S.cursor + 1;
  return S.frames.slice(Math.max(0, end - n), end);
}

export async function post(path) {
  const r = await fetch(path, { method: 'POST', headers: { 'X-Chipscope': '1' } });
  return r.json();
}
