// Drill-down levels (cluster, core, GPU, memory) and the Signal-timing / Sensors pages.
import {
  S, svg, h, kv, heat, blue, bwHeat, fmtBps, fmtBytes, fmtW, fmtPct, fmtMHz, fmtNs, bindTip, lineChart, windowFrames, post,
  showTip, hideTip,
} from './lib.js';
import { EXPLAIN, coreHeat, gpuHeat, coreTip, procsSide } from './views_map.js';

const HIST = 240; // 60 s at 4/s
const big = (n) => (n === undefined || n === null ? '—' : n >= 1e6 ? (n / 1e6).toFixed(1) + ' M' : n >= 1e3 ? (n / 1e3).toFixed(0) + ' k' : String(n));
const short = (s, n) => (s.length > n ? s.slice(0, n - 1) + '…' : s);
const INK = '#c3c2b7';
const SERIES = ['#3987e5', '#d95926', '#199e70', '#c98500', '#d55181'];  // dark categorical slots 1, 2, 3, 4, 5

function page(stage, title, lead) {
  const p = h('div', { class: 'page' }, stage);
  h('h1', {}, p, title);
  if (lead) h('p', { class: 'lead' }, p, lead);
  return p;
}
function card(parent, title, note) {
  const c = h('div', { class: 'card' }, parent);
  h('h3', {}, c, title);
  const body = h('div', {}, c);
  if (note) h('div', { class: 'note' }, c, note);
  return body;
}
const clusterOf = (id) => S.topo.clusters.find((c) => c.id === id);
function coreLookup(id) {
  for (const cl of S.topo.clusters) for (const c of cl.cores) if (c.id === id) return [cl, c];
  return [null, null];
}
function coreName(logical) {
  for (const cl of S.topo.clusters) for (const c of cl.cores) if (!c.fused && c.logical === logical) return `${cl.type}${cl.type === 'P' ? cl.id.slice(-1) + '.' : ''}${c.slot}`;
  return 'cpu' + logical;
}

// Residency bars: share of time in each DVFS state, labelled with its clock.
function residencyBars(parent, width = 420) {
  const H = 150;
  const root = svg('svg', { viewBox: `0 0 ${width} ${H}`, width: '100%' }, parent);
  return (states, freqs) => {
    root.replaceChildren();
    if (!states || !states.length) return;
    const active = freqs ? freqs.filter((x) => x > 0) : [];
    const all = states.map(([n, s]) => n);
    const bw = Math.min(40, (width - 20) / Math.max(1, states.length + 1));
    const maxS = Math.max(...states.map((x) => x[1]), 0.01);
    // State name -> clock step: CPU "V<i>P<j>" is step i, GPU "P<i>" is step i-1.
    // (Frames drop near-empty states, so counting positions would shift the clocks.)
    const idle = new Set(['IDLE', 'OFF', 'DOWN']);
    const step = (n) => { let m = /^V(\d+)P/.exec(n); if (m) return +m[1]; m = /^P(\d+)$/.exec(n); return m ? +m[1] - 1 : -1; };
    states.forEach(([n, s], i) => {
      const mhz = idle.has(n) ? null : active[step(n)] ?? null;
      const x = 10 + i * (bw + 2);
      const bh = (H - 40) * s / maxS;
      const r = svg('rect', { x, y: H - 26 - bh, width: bw, height: Math.max(1, bh), rx: 2, fill: idle.has(n) ? '#383835' : heat(mhz && active.length ? mhz / Math.max(...active) : 0.5) }, root);
      svg('text', { x: x + bw / 2, y: H - 12, class: 'tiny', 'text-anchor': 'middle' }, root, idle.has(n) ? n.toLowerCase() : mhz ? (mhz / 1000).toFixed(1) : n);
      bindTip(r, () => ({ value: fmtPct(s), label: idle.has(n) ? 'Idle' : `${mhz ? fmtMHz(mhz) : n} (state ${n})`, src: 'IOReport state residency' }));
    });
    svg('text', { x: 10, y: H - 1, class: 'tiny' }, root, 'GHz per state · bar = share of time (states under 0.05% hidden)');
  };
}

// ================================================================== cluster
export function clusterView(id) {
  const parts = {};
  let charts = [];
  return {
    tab: 'map',
    crumbs: () => [['Mac', '#/mac'], [S.topo.chip, '#/soc'], [clusterOf(id)?.label.replace(/ \(.*/, '') || id, `#/cluster/${id}`]],
    mount(stage) {
      const cl = clusterOf(id);
      if (!cl) { page(stage, 'Unknown cluster ' + id); return; }
      const p = page(stage, cl.label, EXPLAIN[cl.type === 'P' ? 'pclu' : 'eclu']);
      const W = 1100;
      const root = svg('svg', { viewBox: `0 0 ${W} 360`, width: '100%', style: 'max-width:1100px' }, p);
      svg('defs', {}, root).innerHTML = '<pattern id="hatch" width="8" height="8" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="8" height="8" fill="#161615"/><line x1="0" y1="0" x2="0" y2="8" stroke="#3a3935" stroke-width="3"/></pattern>';
      const n = cl.cores.length;
      const tw = Math.min(250, (W - 40 - (n - 1) * 16) / n);
      cl.cores.forEach((core, i) => {
        const x = 20 + i * (tw + 16), y = 10;
        if (core.fused) {
          const r = svg('rect', { x, y, width: tw, height: 250, rx: 8, class: 'ghost' }, root);
          svg('text', { x: x + tw / 2, y: y + 120, class: 'lbl', 'text-anchor': 'middle' }, root, `slot ${core.slot}: fused off`);
          svg('text', { x: x + tw / 2, y: y + 140, class: 'tiny', 'text-anchor': 'middle' }, root, 'disabled at the factory');
          bindTip(r, () => ({ value: 'Fused off', label: `${cl.label}, slot ${core.slot}`, explain: 'Binned: fused off permanently. No cpu node in the device tree; its energy channel reads zero.', src: 'device tree · IOReport' }));
          return;
        }
        const r = svg('rect', { x, y, width: tw, height: 250, rx: 8, class: 'blk', fill: '#202124' }, root);
        r.addEventListener('click', () => { location.hash = `#/core/${core.id}`; });
        bindTip(r, () => { const f = windowFrames(1)[0]; return f ? coreTip(cl, core, f) : null; });
        svg('text', { x: x + 14, y: y + 26, class: 'lbl' }, root, `${cl.type}-core ${core.slot} · cpu${core.logical}`);
        const big = svg('text', { x: x + 14, y: y + 76, style: 'font-size:38px;font-weight:650;pointer-events:none' }, root, '');
        const l1 = svg('text', { x: x + 14, y: y + 104, class: 'val' }, root, '');
        const l2 = svg('text', { x: x + 14, y: y + 122, class: 'val' }, root, '');
        const bars = svg('g', { transform: `translate(${x + 14},${y + 140})`, 'pointer-events': 'none' }, root);
        parts[core.id] = { r, big, l1, l2, bars, tw };
      });
      svg('text', { x: 20, y: 274, class: 'tiny' }, root, 'White bars at the bottom of each core: time at each clock step (left = 600 MHz … right = max). Click a core for detail.');
      const l2 = svg('rect', { x: 20, y: 280, width: W - 40, height: 64, rx: 8, class: 'blk', fill: '#202124' }, root);
      bindTip(l2, () => { const f = windowFrames(1)[0]; if (!f) return null; const v = f.bw[cl.amc] || [0, 0, 0, 0];
        return { value: fmtBps(v[0] + v[1]), label: `Shared L2 (${fmtBytes(cl.l2)}) ↔ fabric`, rows: [['Read', fmtBps(v[0])], ['Write', fmtBps(v[1])], ['…reached DRAM', fmtBps(v[2] + v[3])], ['Shared logic power', fmtW(f.clusters[cl.id].w_shared)]],
          explain: EXPLAIN.l2, src: `IOReport AMC Stats ${cl.amc} · Energy Model ${cl.energy}_CPM` }; });
      parts.l2 = { r: l2, t: svg('text', { x: 36, y: 306, class: 'lbl' }, root, `L2 cache · ${fmtBytes(cl.l2)} shared`), v: svg('text', { x: 36, y: 328, class: 'val' }, root, '') };
      if (cl.l2_devicetree && cl.l2_devicetree !== cl.l2) {
        svg('text', { x: W - 30, y: 306, class: 'tiny', 'text-anchor': 'end' }, root, `sysctl ${fmtBytes(cl.l2)} · device tree says ${fmtBytes(cl.l2_devicetree)}`);
      }
      const cards = h('div', { class: 'cards', style: 'margin-top:14px' }, p);
      for (const core of cl.cores.filter((c) => !c.fused)) {
        const c = lineChart(card(cards, `${cl.type}-core ${core.slot} busy, last 60 s`), { yFmt: (v) => fmtPct(v), height: 110 });
        charts.push(() => c.draw([{ name: 'Busy', color: INK, values: windowFrames(HIST).map((f) => f.cores[core.id]?.busy ?? null) }], 1, '60 s'));
      }
      const ck = lineChart(card(cards, 'Cluster clock, last 60 s', 'Average frequency while the cluster is active (from DVFS state residency).'), { yFmt: (v) => (v ? fmtMHz(Math.round(v)) : '0'), height: 110 });
      charts.push(() => ck.draw([{ name: 'Clock', color: INK, values: windowFrames(HIST).map((f) => f.clusters[id]?.mhz ?? null) }], Math.max(...cl.freqs), '60 s'));
      const pw = lineChart(card(cards, 'Cluster power, last 60 s', 'Apple energy model: cores + shared logic.'), { yFmt: (v) => fmtW(v), height: 110 });
      charts.push(() => pw.draw([{ name: 'Power', color: INK, values: windowFrames(HIST).map((f) => f.clusters[id] ? f.clusters[id].w_cores + f.clusters[id].w_shared : null) }], null, '60 s'));
    },
    update(f) {
      const cl = clusterOf(id);
      if (!cl) return;
      for (const core of cl.cores) {
        const pt = parts[core.id], c = f.cores[core.id];
        if (!pt || !c) continue;
        pt.r.setAttribute('fill', heat(coreHeat(c, cl.type)));
        pt.big.textContent = fmtPct(c.busy);
        pt.l1.textContent = `${fmtMHz(c.mhz)} while busy`;
        pt.l2.textContent = `${fmtW(c.w)} (model)`;
        pt.bars.replaceChildren();
        // One bar per clock step (left = slowest). The frame only lists states with
        // time in them, so place each by its name: V<i>P<j> is step i of the table.
        const bw = (pt.tw - 28) / Math.max(1, cl.freqs.length);
        for (const [n, s] of c.states) {
          const m = /^V(\d+)P/.exec(n);
          if (!m) continue;
          const k = Math.min(+m[1], cl.freqs.length - 1);
          svg('rect', { x: k * bw, y: 80 - 76 * s, width: Math.max(1, bw - 2), height: Math.max(0.5, 76 * s), fill: 'rgba(255,255,255,0.75)' }, pt.bars);
        }
      }
      const v = f.bw[cl.amc] || [0, 0];
      parts.l2.r.setAttribute('fill', heat(Math.min(1, (v[0] + v[1]) / 100e9)));
      parts.l2.v.textContent = `${fmtBps(v[0] + v[1])} to the fabric  (read ${fmtBps(v[0])}, write ${fmtBps(v[1])})`;
      charts.forEach((fn) => fn());
    },
    side(f, el) {
      const cl = clusterOf(id);
      const c = f.clusters[id];
      h('h2', {}, el, cl.label);
      kv(el, [['Average busy', fmtPct(c.busy)], ['Cluster active', fmtPct(c.active)], ['Clock', fmtMHz(c.mhz)], ['Cores power', fmtW(c.w_cores)], ['Shared logic', fmtW(c.w_shared)],
        ['L1 data / instr per core', `${fmtBytes(cl.type === 'P' ? S.topo.caches.p_l1d : S.topo.caches.e_l1d)} / ${fmtBytes(cl.type === 'P' ? S.topo.caches.p_l1i : S.topo.caches.e_l1i)}`],
        ['Clock range', `${Math.min(...cl.freqs)}–${Math.max(...cl.freqs)} MHz in ${cl.freqs.length} steps`]]);
      const temps = Object.entries(f.board?.smc_temps || {}).filter(([, v]) => v.label.startsWith(cl.type === 'P' ? 'P-core' : 'E-core'));
      if (temps.length) {
        h('h3', {}, el, `${cl.type}-core area temperatures`);
        kv(el, temps.map(([k, v]) => [`${k}`, v.c + ' °C']));
        h('div', { class: 'src' }, el, 'SMC keys named per the community map (open-source "Stats" app). Which sensor sits over which core of THIS binned chip is not known, so they are not tied to tiles.');
      }
      procsSide(f, el);
    },
  };
}

// ================================================================== core
export function coreView(id) {
  const charts = [];
  let bars = null, cl = null, core = null;
  return {
    tab: 'map',
    crumbs: () => { const [c, k] = coreLookup(id); return [['Mac', '#/mac'], [S.topo.chip, '#/soc'], [c?.label.replace(/ \(.*/, '') || '?', `#/cluster/${c?.id}`], [`${c?.type}-core ${k?.slot}`, `#/core/${id}`]]; },
    mount(stage) {
      [cl, core] = coreLookup(id);
      if (!core || core.fused) { page(stage, 'Core ' + id + (core?.fused ? ' is fused off' : ' not found')); return; }
      const p = page(stage, `${cl.type}-core ${core.slot} · ${cl.label} · logical CPU ${core.logical}`, EXPLAIN.core);
      const cards = h('div', { class: 'cards' }, p);
      const mk = (title, note, fmt, val, max) => {
        const c = lineChart(card(cards, title, note), { yFmt: fmt, height: 120 });
        charts.push(() => c.draw([{ name: title.split(',')[0], color: INK, values: windowFrames(HIST).map(val) }], max, '60 s'));
      };
      mk('Busy, last 60 s', null, fmtPct, (f) => f.cores[id]?.busy ?? null, 1);
      mk('Clock while busy, last 60 s', `Max ${fmtMHz(Math.max(...cl.freqs))}.`, (v) => (v ? fmtMHz(Math.round(v)) : '0'), (f) => f.cores[id]?.mhz ?? null, Math.max(...cl.freqs));
      mk('Power, last 60 s', 'Apple energy model estimate for this core.', fmtW, (f) => f.cores[id]?.w ?? null, null);
      bars = residencyBars(card(cards, 'Time in each clock state (now)', 'IDLE = core asleep. Each other bar is one voltage/frequency step from the power manager\'s table.'));
      atlasForType(card(cards, `Memory hierarchy seen from a ${cl.type}-core`, 'Pointer-chase latency vs working-set size, from the Signal-timing probes. macOS cannot pin a thread to one core, so this is "a core of this type".'), cl.type);
      c2cRow(card(cards, `Signal time from cpu${core.logical} to the other cores`, 'One-way cache-line transfer, from the core-to-core probe.'), core.logical);
    },
    update(f) {
      if (!core || core.fused) return;
      const c = f.cores[id];
      if (bars && c) bars(c.states, cl.freqs);
      charts.forEach((fn) => fn());
    },
    side(f, el) {
      if (!core || core.fused) return;
      const c = f.cores[id];
      h('h2', {}, el, `${cl.type}-core ${core.slot}`);
      kv(el, [['Busy', fmtPct(c.busy)], ['Clock', fmtMHz(c.mhz)], ['Power (model)', fmtW(c.w)], ['Logical CPU', core.logical], ['Device-tree cpu-id', core.cpu_id],
        ['IOReport channel', core.ioreport], ['Energy channel', core.energy]]);
      procsSide(f, el);
    },
  };
}

// ================================================================== GPU
export function gpuView() {
  const charts = [];
  let tiles = [], bars = null, stat = null;
  return {
    tab: 'map',
    crumbs: () => [['Mac', '#/mac'], [S.topo.chip, '#/soc'], ['GPU', '#/gpu']],
    mount(stage) {
      const T = S.topo;
      const die = T.spec?.gpu_die_cores || T.gpu.cores;
      const p = page(stage, `GPU · ${T.gpu.cores} of ${die} cores enabled`, EXPLAIN.gpu);
      const root = svg('svg', { viewBox: '0 0 1100 250', width: '100%', style: 'max-width:1100px' }, p);
      svg('defs', {}, root).innerHTML = '<pattern id="hatch" width="8" height="8" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="8" height="8" fill="#161615"/><line x1="0" y1="0" x2="0" y2="8" stroke="#3a3935" stroke-width="3"/></pattern>';
      for (let i = 0; i < die; i++) {
        const x = 20 + (i % 8) * 132, y = 10 + Math.floor(i / 8) * 112;
        if (i >= T.gpu.cores) {
          const r = svg('rect', { x, y, width: 120, height: 100, rx: 8, class: 'ghost' }, root);
          svg('text', { x: x + 60, y: y + 48, class: 'tiny', 'text-anchor': 'middle' }, root, 'fused off');
          svg('text', { x: x + 60, y: y + 62, class: 'tiny', 'text-anchor': 'middle' }, root, '(position unknown)');
          bindTip(r, () => ({ value: 'Fused off', label: `${die - T.gpu.cores} of ${die} GPU cores`, explain: 'Which two are off is not exposed; these tiles are placeholders.' }));
          continue;
        }
        const r = svg('rect', { x, y, width: 120, height: 100, rx: 8, class: 'blk nonav', fill: '#202124' }, root);
        svg('text', { x: x + 10, y: y + 20, class: 'tiny' }, root, `core ${i}`);
        bindTip(r, () => { const f = windowFrames(1)[0]; return f ? { value: fmtPct(f.gpu.util ?? f.gpu.busy), label: 'Whole-GPU utilisation', explain: 'macOS reports one number for the whole GPU, not per core.', src: 'IOKit AGX PerformanceStatistics' } : null; });
        tiles.push(r);
      }
      stat = svg('text', { x: 20, y: 244, class: 'val' }, root, '');
      const cards = h('div', { class: 'cards', style: 'margin-top:14px' }, p);
      const mk = (title, note, fmt, val, max) => {
        const c = lineChart(card(cards, title, note), { yFmt: fmt, height: 120 });
        charts.push(() => c.draw([{ name: title.split(',')[0], color: INK, values: windowFrames(HIST).map(val) }], max, '60 s'));
      };
      mk('Utilisation, last 60 s', 'Device utilisation, as in Activity Monitor\'s GPU history.', fmtPct, (f) => f.gpu.util ?? null, 1);
      mk('Clock, last 60 s', `Max ${fmtMHz(Math.max(...T.gpu.freqs))}. States P1–P6 carry the 6 clocks (a 100% load sits in P6, checked). Empty while the GPU is off.`, (v) => (v ? fmtMHz(Math.round(v)) : '0'), (f) => f.gpu.mhz ?? null, Math.max(...T.gpu.freqs));
      mk('Power, last 60 s', 'Apple energy model.', fmtW, (f) => f.gpu.w, null);
      mk('Memory traffic, last 60 s', 'Both GPU ports (GFX + GFX1), read + write.', fmtBps, (f) => (f.bw.GFX ? f.bw.GFX[0] + f.bw.GFX[1] : 0) + (f.bw.GFX1 ? f.bw.GFX1[0] + f.bw.GFX1[1] : 0), null);
      bars = residencyBars(card(cards, 'Time in each GPU power state (now)', 'OFF = power-gated. P-states map onto the clock table in order.'));
    },
    update(f) {
      const c = heat(gpuHeat(f.gpu));
      for (const t of tiles) t.setAttribute('fill', c);
      if (stat) stat.textContent = `${fmtPct(f.gpu.util ?? f.gpu.busy)} utilised · ${fmtMHz(f.gpu.mhz)} · ${fmtW(f.gpu.w)} · renderer ${f.gpu.renderer ?? '—'}% · tiler ${f.gpu.tiler ?? '—'}% · ${fmtBytes(f.gpu.mem_used)} in use`;
      if (bars) bars(f.gpu.states, S.topo.gpu.freqs);
      charts.forEach((fn) => fn());
    },
    side(f, el) {
      h('h2', {}, el, 'GPU');
      kv(el, [['Utilisation', fmtPct(f.gpu.util)], ['Powered on', fmtPct(f.gpu.busy)], ['Clock', fmtMHz(f.gpu.mhz)], ['Power', fmtW(f.gpu.w)], ['SRAM power', fmtW(f.gpu.w_sram)],
        ['Renderer / tiler', `${f.gpu.renderer ?? '—'}% / ${f.gpu.tiler ?? '—'}%`], ['Memory in use', fmtBytes(f.gpu.mem_used)]]);
      procsSide(f, el);
    },
  };
}

// ================================================================== memory
export function memoryView() {
  const charts = [];
  let comp = null, agentsEl = null, swapEl = null;
  return {
    tab: 'map',
    crumbs: () => [['Mac', '#/mac'], [S.topo.chip, '#/soc'], ['Unified memory', '#/memory']],
    mount(stage) {
      const T = S.topo;
      const p = page(stage, `Unified memory · ${fmtBytes(T.memory_bytes)} ${T.spec?.mem_type || ''}`, EXPLAIN.dram + ' ' + EXPLAIN.mc);
      const cards = h('div', { class: 'cards' }, p);
      comp = card(cards, 'What the memory holds (now)', 'From vm_stat. "Apps" = anonymous memory; "Cached files" can be dropped at any time; "Compressed" = memory squeezed by the compressor.');
      swapEl = card(cards, 'Pressure and swap', 'Pressure level from the kernel (kern.memorystatus_vm_pressure_level).');
      agentsEl = card(cards, 'Who is moving data through the memory system (now)', 'Each on-chip agent\'s traffic at the memory controller. Bar = read + write; darker share reached DRAM, the rest hit the 24 MB system cache.');
      const c1 = lineChart(card(cards, 'DRAM traffic, last 60 s', `Peak ${fmtBps(T.spec?.mem_peak_bw)} (Apple spec).`), { yFmt: fmtBps, height: 130 });
      charts.push(() => c1.draw([
        { name: 'Read', color: '#3987e5', values: windowFrames(HIST).map((f) => f.mem.dram_rd) },
        { name: 'Write', color: '#199e70', values: windowFrames(HIST).map((f) => f.mem.dram_wr) }], null, '60 s'));
      const lg = h('div', { class: 'legend' }, c1.root.parentNode);
      for (const [n, c] of [['Read', '#3987e5'], ['Write', '#199e70']]) { const k = h('span', { class: 'key' }, lg); h('span', { class: 'line', style: `background:${c}` }, k); h('span', {}, k, n); }
      const c2 = lineChart(card(cards, 'Served by the system cache, last 60 s', 'Derived: 1 − DRAM traffic / all agent traffic. Empty when traffic is under 50 MB/s.'), { yFmt: fmtPct, height: 130 });
      charts.push(() => c2.draw([{ name: 'On-chip', color: INK, values: windowFrames(HIST).map((f) => f.mem.slc_hit) }], 1, '60 s'));
      const c3 = lineChart(card(cards, 'DRAM power, last 60 s', 'Energy model: DRAM0.'), { yFmt: fmtW, height: 130 });
      charts.push(() => c3.draw([{ name: 'DRAM', color: INK, values: windowFrames(HIST).map((f) => f.mem.dram_w) }], null, '60 s'));
    },
    update(f) {
      const m = f.board?.mem || {};
      const T = S.topo;
      if (comp && m.total) {
        comp.replaceChildren();
        const parts = [['Wired (kernel)', m.wired], ['Apps', m.app], ['Compressed', m.compressed], ['Cached files', m.file_backed], ['Free', m.free]];
        const used = parts.slice(0, 4).reduce((s, [, v]) => s + (v || 0), 0) + (m.free || 0);
        parts.push(['Other', Math.max(0, m.total - used)]);
        const root = svg('svg', { viewBox: '0 0 420 46', width: '100%' }, comp);
        let x = 0;
        parts.forEach(([n, v], i) => {
          const w = 420 * (v || 0) / m.total;
          if (w <= 0) return;
          const color = n === 'Free' ? '#383835' : n === 'Other' ? '#2c2c2a' : SERIES[i];
          const r = svg('rect', { x: x + 1, y: 4, width: Math.max(0, w - 2), height: 30, rx: 3, fill: color }, root);
          bindTip(r, () => ({ value: fmtBytes(v), label: n, rows: [['Share', fmtPct(v / m.total)]], src: 'vm_stat' }));
          x += w;
        });
        const lg = h('div', { class: 'legend' }, comp);
        parts.forEach(([n, v], i) => { const k = h('span', { class: 'key' }, lg); h('span', { class: 'sw', style: `background:${n === 'Free' ? '#383835' : n === 'Other' ? '#2c2c2a' : SERIES[i]}` }, k); h('span', {}, k, `${n} ${fmtBytes(v)}`); });
      }
      if (swapEl) {
        swapEl.replaceChildren();
        const lvl = { 1: ['Normal', 'var(--good)'], 2: ['Warning', 'var(--warning)'], 4: ['Critical', 'var(--critical)'] }[m.pressure_level] || ['—', 'var(--muted)'];
        const st = h('div', { class: 'status' }, swapEl);
        h('i', { style: `background:${lvl[1]}` }, st);
        h('span', {}, st, `Memory pressure: ${lvl[0]}`);
        kv(swapEl, [['Swap used', `${fmtBytes(m.swap_used)} of ${fmtBytes(m.swap_total)}`], ['Kernel free-memory level', m.free_percent !== undefined ? m.free_percent + '%' : '—'],
          ['Pages swapped in / out (since boot)', `${big(m.swapins)} / ${big(m.swapouts)}`]]);
      }
      if (agentsEl) {
        agentsEl.replaceChildren();
        const rows = Object.entries(f.bw).map(([a, v]) => [a, v]).filter(([, v]) => v[0] + v[1] > 1e5).sort((a, b) => (b[1][0] + b[1][1]) - (a[1][0] + a[1][1]));
        const max = Math.max(1, ...rows.map(([, v]) => v[0] + v[1]));
        const root = svg('svg', { viewBox: `0 0 460 ${Math.max(30, rows.length * 24 + 6)}`, width: '100%' }, agentsEl);
        rows.forEach(([a, v], i) => {
          const y = 4 + i * 24;
          const tot = v[0] + v[1];
          const w = 200 * tot / max;
          const dram = Math.min(tot, v[2] + v[3]);
          svg('text', { x: 0, y: y + 13, class: 'tiny', style: 'fill:#c3c2b7' }, root, short(T.agents[a]?.label || a, 24));
          const r = svg('rect', { x: 170, y, width: Math.max(1, w), height: 16, rx: 3, fill: '#5598e7' }, root);
          svg('rect', { x: 170, y, width: Math.max(0, w * dram / tot), height: 16, rx: 3, fill: '#184f95', 'pointer-events': 'none' }, root);
          svg('text', { x: 170 + w + 6, y: y + 13, class: 'tiny', style: 'fill:#f0efec' }, root, fmtBps(tot));
          bindTip(r, () => ({ value: fmtBps(tot), label: T.agents[a]?.label || a, rows: [['Read', fmtBps(v[0])], ['Write', fmtBps(v[1])], ['Reached DRAM', fmtBps(v[2] + v[3])]], src: `IOReport AMC Stats ${a}` }));
        });
      }
      charts.forEach((fn) => fn());
    },
    side(f, el) {
      h('h2', {}, el, 'Memory system');
      kv(el, [['DRAM traffic', fmtBps(f.mem.dram_rd + f.mem.dram_wr)], ['All agent traffic', fmtBps(f.mem.agents_total)], ['Served on-chip (derived)', fmtPct(f.mem.slc_hit)],
        ['DRAM power', fmtW(f.mem.dram_w)], ['Cache + controller power', fmtW(f.mem.amcc_w + f.mem.dcs_w)]]);
      procsSide(f, el);
    },
  };
}

// ================================================================== signal timing (atlas)
// Degrees clockwise from 3 o'clock; spaced so each group's fan of dots (14° apart) stays clear.
const GROUP_ANGLE = { accel: 0, storage: 40, sensors: 85, network: 125, cache: 190, memory: 232, cores: 268, os: 315 };
const RING_LABEL_ANGLE = 147;
const GROUP_NAME = { cache: 'Caches', cores: 'Other cores', memory: 'Memory', os: 'OS / kernel', accel: 'GPU + Neural Engine', storage: 'Storage', sensors: 'Sensors', network: 'Network' };

async function loadAtlas() {
  S.atlas = await (await fetch('/api/atlas')).json();
  return S.atlas;
}

function atlasForType(el, type) {
  const draw = () => {
    el.replaceChildren();
    const a = S.atlas;
    const pts = a && (type === 'P' ? a.memlat_p : a.memlat_e);
    if (!pts || !pts.length) { h('div', { class: 'note' }, el, 'No probe results yet: open "Signal timing" and run the probes.'); return; }
    memlatChart(el, [{ name: `${type}-core`, color: INK, pts }], type);
  };
  if (S.atlas) draw(); else loadAtlas().then(draw);
}

function c2cRow(el, logical) {
  const draw = () => {
    el.replaceChildren();
    const m = S.atlas?.c2c || {};
    const rows = [];
    for (const cl of S.topo.clusters) for (const c of cl.cores) {
      if (c.fused || c.logical === logical) continue;
      const k = `${Math.min(logical, c.logical)}-${Math.max(logical, c.logical)}`;
      rows.push([`cpu${c.logical} (${coreName(c.logical)})`, m[k] ? `${fmtNs(m[k].p50)} · ${m[k].n} runs` : 'not observed']);
    }
    if (!Object.keys(m).length) h('div', { class: 'note' }, el, 'No probe results yet.');
    else kv(el, rows);
  };
  if (S.atlas) draw(); else loadAtlas().then(draw);
}

function memlatChart(parent, series, type) {
  const W = 460, H = 230, L = 48, R = 12, T = 10, B = 34;
  const root = svg('svg', { viewBox: `0 0 ${W} ${H}`, width: '100%' }, parent);
  const all = series.flatMap((s) => s.pts);
  const xs = all.map((p) => Math.log2(p[0])), ys = all.map((p) => Math.log10(Math.max(0.3, p[1])));
  const x0 = Math.min(...xs), x1 = Math.max(...xs), y0 = Math.floor(Math.min(...ys)), y1 = Math.ceil(Math.max(...ys));
  const X = (b) => L + (W - L - R) * (Math.log2(b) - x0) / (x1 - x0);
  const Y = (ns) => T + (H - T - B) * (1 - (Math.log10(Math.max(0.3, ns)) - y0) / (y1 - y0 || 1));
  for (let e = y0; e <= y1; e++) {
    svg('line', { x1: L, x2: W - R, y1: Y(10 ** e), y2: Y(10 ** e), class: 'gridline' }, root);
    svg('text', { x: L - 6, y: Y(10 ** e) + 4, class: 'tiny', 'text-anchor': 'end' }, root, fmtNs(10 ** e));
  }
  for (let b = 2 ** Math.ceil(x0); b <= 2 ** x1; b *= 8) svg('text', { x: X(b), y: H - 18, class: 'tiny', 'text-anchor': 'middle' }, root, fmtBytes(b));
  svg('text', { x: L, y: H - 3, class: 'tiny' }, root, 'working-set size (log) →');
  const c = S.topo.caches;
  const refs = type === 'E' ? [[c.e_l1d, 'L1'], [c.e_l2, 'L2'], [S.topo.spec?.slc_bytes, 'SLC']] : type === 'P' ? [[c.p_l1d, 'L1'], [c.p_l2, 'L2'], [S.topo.spec?.slc_bytes, 'SLC']] :
    [[c.p_l1d, 'P L1'], [c.p_l2, 'P L2'], [S.topo.spec?.slc_bytes, 'SLC']];
  for (const [b, n] of refs) {
    if (!b || Math.log2(b) < x0 || Math.log2(b) > x1) continue;
    svg('line', { x1: X(b), x2: X(b), y1: T, y2: H - B, class: 'refline' }, root);
    svg('text', { x: X(b) + 3, y: T + 10, class: 'tiny' }, root, `${n} ${fmtBytes(b)}`);
  }
  for (const s of series) {
    const d = s.pts.map((p, i) => `${i ? 'L' : 'M'}${X(p[0]).toFixed(1)},${Y(p[1]).toFixed(1)}`).join('');
    svg('path', { d, class: 'series', stroke: s.color }, root);
    for (const p of s.pts) {
      const dot = svg('circle', { cx: X(p[0]), cy: Y(p[1]), r: 3, fill: s.color }, root);
      const hit = svg('circle', { cx: X(p[0]), cy: Y(p[1]), r: 9, fill: 'transparent' }, root);
      bindTip(hit, () => ({ value: fmtNs(p[1]), label: `${s.name} · ${fmtBytes(p[0])} working set`, rows: [['Measured on', `cpu${p[2]}`]], src: 'pointer chase, best of 5 runs' }));
      void dot;
    }
  }
  if (series.length > 1) {
    const lg = h('div', { class: 'legend' }, parent);
    for (const s of series) { const k = h('span', { class: 'key' }, lg); h('span', { class: 'line', style: `background:${s.color}` }, k); h('span', {}, k, s.name); }
  }
}

export function atlasView() {
  let p, body, btn, status;
  const live = { p: [], e: [] };
  const render = () => {
    body.replaceChildren();
    const a = S.atlas;
    if (!a || !a.entries.length) {
      h('div', { class: 'card' }, body, 'No measurements yet. Press "Run probes": about 30 seconds of light load on every part of the chip while it runs.');
      if (live.p.length || live.e.length) memlatCard(body, live);
      return;
    }
    status.textContent = a.t ? `Last run ${new Date(a.t * 1000).toLocaleString()}${a.load ? ` · load average then ${a.load[0]}` : ''} · busy machines give slower, noisier numbers.`
      : 'Probes not run yet: only the passive timings (SSD driver average, sensor reads) are shown.';
    const cards = h('div', { class: 'cards' }, body);
    const rc = h('div', { class: 'card', style: 'grid-column: 1 / -1' }, cards);
    h('h3', {}, rc, 'Signal distance from a CPU core');
    radial(h('div', { style: 'max-width: 980px; margin: 0 auto' }, rc), a.entries);
    h('div', { class: 'note' }, rc, 'Rings are powers of ten in time. Each dot is a measured round trip; the grey whisker is its p10–p90 spread. Hover for how it was measured; click to find it on the map.');
    ladder(card(cards, 'All timings, fastest first', 'The same numbers as a table (log-scale bars).'), a.entries);
    matrix(card(cards, 'Core-to-core signal time (one way)', 'Two threads bounce one cache line. Same-cluster pairs share an L2; cross-cluster pairs go through the fabric. macOS decides where threads run, so some pairs may not be observed.'), a);
    memlatCard(cards, { p: a.memlat_p, e: a.memlat_e });
  };
  function memlatCard(parent, d) {
    const el = card(parent, 'Memory hierarchy: latency vs working-set size', 'Each step up is the next level: L1 → L2 → system cache → DRAM. The L2 step on P-cores appears before the documented 12 MB; the cause is not verified here (candidates: the thread moving between clusters, TLB reach).');
    const series = [];
    if (d.p && d.p.length) series.push({ name: 'P-core', color: SERIES[0], pts: d.p });
    if (d.e && d.e.length) series.push({ name: 'E-core', color: SERIES[1], pts: d.e });
    if (series.length) memlatChart(el, series, null);
  }
  return {
    tab: 'atlas',
    crumbs: () => [['Signal timing', '#/atlas']],
    mount(stage) {
      p = page(stage, 'Signal timing: how far away is each part, measured in time',
        'Every component answers at a different speed. A value in L1 cache arrives in about a nanosecond; DRAM takes about a hundred; the SSD a hundred thousand. Timing those answers maps the machine: it is how the cache sizes, the two P-clusters and the sensor buses show up below, without any spec sheet.');
      const bar = h('div', { style: 'display:flex;gap:12px;align-items:center;margin-bottom:14px' }, p);
      btn = h('button', { class: 'btn primary', onclick: async () => {
        btn.disabled = true; live.p = []; live.e = [];
        const r = await post('/api/probe/run');
        status.textContent = r.started ? 'Starting…' : 'Already running…';
      } }, bar, 'Run probes (~30 s)');
      status = h('span', { class: 'src', style: 'font-size:12px' }, bar, S.topo.helper_error ? 'Native helper unavailable: ' + S.topo.helper_error : '');
      if (S.topo.helper_error) btn.disabled = true;
      body = h('div', {}, p);
      loadAtlas().then(render);
      this._onProbe = (e) => {
        const d = e.detail;
        if (d.step === 'done') { btn.disabled = false; loadAtlas().then(render); return; }
        btn.disabled = true;
        status.textContent = `Running: ${{ misc: 'kernel + timer', 'memlat-p': 'memory hierarchy on P-cores', 'memlat-e': 'memory hierarchy on E-cores', c2c: 'core-to-core', ssd: 'SSD', gpu: 'GPU', ane: 'Neural Engine', net: 'Wi-Fi' }[d.step] || d.step}…`;
        if (d.point) { (d.step === 'memlat-p' ? live.p : live.e).push(d.point); if (!S.atlas || !S.atlas.entries.length) render(); }
      };
      window.addEventListener('chipscope:probe', this._onProbe);
    },
    unmount() { window.removeEventListener('chipscope:probe', this._onProbe); },
    update(f) { if (f.probing && btn) btn.disabled = true; },
    side(f, el) {
      h('h2', {}, el, 'How to read this');
      h('p', { class: 'explain' }, el, 'Latency is distance. Within the chip, a signal crossing to another cluster or out to DRAM has to traverse more wires, more arbitration, and slower clocks. Off the chip (SSD, sensors, Wi-Fi) it crosses buses and firmware on other processors.');
      h('p', { class: 'explain' }, el, 'All numbers are from this Mac. The passive ones (SSD lifetime average, sensor reads) refresh on their own; the probes run only when you press the button.');
      kv(el, [['Load average now', (f.board?.load || []).join(' / ')]]);
    },
  };
}

function radial(el, entries) {
  // Dots sit at radius = log(time); labels are stacked outside the rings per group,
  // with leader lines, so dots at similar times never fight for the same spot.
  const W = 640, C = W / 2, r0 = 62, r1 = C - 46, MX = 190, MY = 90;
  const root = svg('svg', { viewBox: `${-MX} ${-MY} ${W + 2 * MX} ${W + 2 * MY}`, width: '100%' }, el);
  const e0 = 0, e1 = 8;  // 1 ns .. 100 ms
  const R = (ns) => r0 + (r1 - r0) * (Math.log10(Math.max(1, ns)) - e0) / (e1 - e0);
  const ra = RING_LABEL_ANGLE * Math.PI / 180;
  for (let e = e0; e <= e1; e++) {
    svg('circle', { cx: C, cy: C, r: R(10 ** e), class: 'ring' }, root);
    svg('text', { x: C + R(10 ** e) * Math.cos(ra), y: C + R(10 ** e) * Math.sin(ra) + 4, class: 'ringlbl', 'text-anchor': 'middle' }, root, fmtNs(10 ** e));
  }
  svg('circle', { cx: C, cy: C, r: 16, fill: heat(0.7) }, root);
  svg('text', { x: C, y: C + 4, class: 'tiny', 'text-anchor': 'middle', style: 'fill:#fff' }, root, 'core');
  const leaders = svg('g', {}, root);
  const byGroup = {};
  for (const e of entries) (byGroup[e.group] ||= []).push(e);
  const LH = 15;
  for (const [g, list] of Object.entries(byGroup)) {
    const ga = (GROUP_ANGLE[g] ?? 0) * Math.PI / 180;
    const cos = Math.cos(ga), sin = Math.sin(ga);
    const vertical = Math.abs(cos) < 0.35;
    const P = { x: C + (r1 + 22) * cos, y: C + (r1 + 22) * sin };
    // label slots: index 0 is the header (group name)
    const n = list.length + 1;
    const slot = (k) => {
      if (vertical && sin < 0) return { x: P.x, y: P.y - (n - 1 - k) * LH, anchor: 'middle' };
      if (vertical) return { x: P.x, y: P.y + 10 + k * LH, anchor: 'middle' };
      return { x: P.x + (cos > 0 ? 8 : -8), y: P.y + (k - (n - 1) / 2) * LH, anchor: cos > 0 ? 'start' : 'end' };
    };
    const hd = slot(0);
    svg('text', { x: hd.x, y: hd.y, class: 'cap', 'text-anchor': hd.anchor, style: 'font-weight:600;fill:#898781' }, root, GROUP_NAME[g]);
    // On the left side angles grow upward, so walk the list backwards to keep leaders uncrossed.
    const order = cos < -0.35 ? list.slice().reverse() : list;
    order.forEach((e, k) => {
      const i = list.indexOf(e);
      const a = ga + ((i - (list.length - 1) / 2) * 14) * Math.PI / 180;
      const r = R(e.ns);
      const x = C + r * Math.cos(a), y = C + r * Math.sin(a);
      if (e.spread) {
        svg('path', { d: `M${C + R(e.spread[0]) * Math.cos(a)},${C + R(e.spread[0]) * Math.sin(a)} L${C + R(e.spread[1]) * Math.cos(a)},${C + R(e.spread[1]) * Math.sin(a)}`, stroke: '#6d6c66', 'stroke-width': 2 }, root);
      }
      const L = slot(k + 1);
      const lx = L.anchor === 'start' ? L.x - 3 : L.anchor === 'end' ? L.x + 3 : L.x;
      svg('path', { d: `M${x.toFixed(1)},${y.toFixed(1)} L${lx.toFixed(1)},${(L.y - 4).toFixed(1)}`, stroke: '#383835', 'stroke-width': 1, fill: 'none' }, leaders);
      svg('circle', { cx: x, cy: y, r: 6, class: 'dot', fill: SERIES[0] }, root);
      const t = svg('text', { x: L.x, y: L.y, class: 'cap', 'text-anchor': L.anchor, style: 'fill:#c3c2b7' }, root, `${short(e.label, 30)}  ${fmtNs(e.ns)}`);
      for (const target of [svg('circle', { cx: x, cy: y, r: 12, fill: 'transparent', style: 'cursor:pointer' }, root), t]) {
        bindTip(target, () => ({ value: fmtNs(e.ns), label: e.label, rows: [['Method', e.how], ['Spread (p10–p90)', e.spread ? `${fmtNs(e.spread[0])} – ${fmtNs(e.spread[1])}` : '—']], src: e.src }));
        target.addEventListener('click', () => { location.hash = navFor(e.block); });
      }
      t.style.pointerEvents = 'auto';
      t.style.cursor = 'pointer';
    });
  }
}

function navFor(block) {
  if (['pclu0', 'pclu1', 'eclu'].includes(block)) return `#/cluster/${block}`;
  if (block === 'gpu') return '#/gpu';
  if (['dram', 'slc'].includes(block)) return '#/memory';
  if (['battery', 'wifi'].includes(block)) return '#/mac';
  return '#/soc';
}

function ladder(el, entries) {
  const t = h('table', { class: 't' }, el);
  const hr = h('tr', {}, h('thead', {}, t));
  for (const x of ['Component', 'Time', '', 'How']) h('th', {}, hr, x);
  const tb = h('tbody', {}, t);
  for (const e of entries) {
    const tr = h('tr', {}, tb);
    h('td', {}, tr, e.label);
    h('td', { class: 'n' }, tr, fmtNs(e.ns));
    const td = h('td', { style: 'width:110px' }, tr);
    const w = Math.max(2, 100 * Math.log10(Math.max(1, e.ns)) / 8);
    h('div', { style: `height:8px;width:${w}px;background:#3987e5;border-radius:2px` }, td);
    h('td', { style: 'color:#898781;font-size:11px' }, tr, e.how);
  }
}

function matrix(el, a) {
  const cores = [];
  for (const cl of S.topo.clusters) for (const c of cl.cores) if (!c.fused) cores.push(c.logical);
  cores.sort((x, y) => x - y);
  const n = cores.length, cell = 46, L = 64, T = 40;
  const root = svg('svg', { viewBox: `0 0 ${L + n * cell + 10} ${T + n * cell + 50}`, width: '100%' }, el);
  const vals = Object.values(a.c2c).map((v) => v.p50);
  const lo = Math.min(...vals, 1e9), hi = Math.max(...vals, 0);
  cores.forEach((c, i) => {
    svg('text', { x: L + i * cell + cell / 2, y: T - 8, class: 'tiny', 'text-anchor': 'middle' }, root, coreName(c));
    svg('text', { x: L - 8, y: T + i * cell + cell / 2 + 4, class: 'tiny', 'text-anchor': 'end' }, root, coreName(c));
  });
  cores.forEach((ci, i) => cores.forEach((cj, j) => {
    const x = L + j * cell, y = T + i * cell;
    if (i === j) { svg('rect', { x: x + 1, y: y + 1, width: cell - 2, height: cell - 2, fill: '#1a1a19', stroke: '#2c2c2a' }, root); return; }
    const k = `${Math.min(ci, cj)}-${Math.max(ci, cj)}`;
    const v = a.c2c[k];
    if (!v) {
      const r = svg('rect', { x: x + 1, y: y + 1, width: cell - 2, height: cell - 2, fill: 'url(#hatch2)', stroke: '#383835', 'stroke-dasharray': '3 3' }, root);
      bindTip(r, () => ({ value: 'not observed', label: `${coreName(ci)} ↔ ${coreName(cj)}`, explain: 'The scheduler never placed the two test threads on this pair (or moved them mid-run).' }));
      return;
    }
    const t = hi > lo ? (Math.log(v.p50) - Math.log(lo)) / (Math.log(hi) - Math.log(lo)) : 0.5;
    const r = svg('rect', { x: x + 1, y: y + 1, width: cell - 2, height: cell - 2, rx: 3, fill: blue(t) }, root);
    svg('text', { x: x + cell / 2, y: y + cell / 2 + 4, class: 'tiny', 'text-anchor': 'middle', style: `fill:${t < 0.45 ? '#0b0b0b' : '#f0efec'}` }, root, Math.round(v.p50));
    bindTip(r, () => ({ value: fmtNs(v.p50), label: `${coreName(ci)} ↔ ${coreName(cj)} (one way)`, rows: [['Runs kept', v.n]], src: 'cache-line ping-pong' }));
  }));
  const d = svg('defs', {}, root);
  d.innerHTML = '<pattern id="hatch2" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="6" height="6" fill="#1a1a19"/><line x1="0" y1="0" x2="0" y2="6" stroke="#2c2c2a" stroke-width="2"/></pattern>';
  const ly = T + n * cell + 22;
  svg('text', { x: L, y: ly, class: 'tiny' }, root, `fast ${fmtNs(lo)}`);
  for (let i = 0; i < 8; i++) svg('rect', { x: L + 70 + i * 22, y: ly - 10, width: 20, height: 12, fill: blue(i / 7) }, root);
  svg('text', { x: L + 70 + 8 * 22 + 6, y: ly, class: 'tiny' }, root, `slow ${fmtNs(hi)} (cells in ns)`);
  const drops = Object.entries(a.c2c_drops || {}).map(([k, v]) => `${v} ${k.replace('_', ' ')}`).join(', ');
  if (drops) svg('text', { x: L, y: ly + 18, class: 'tiny' }, root, `discarded runs: ${drops}`);
}

// ================================================================== sensors
export function sensorsView() {
  let p, filter, data = null, chans = null, timer = null, tables;
  const draw = () => {
    tables.replaceChildren();
    const q = (filter.value || '').toLowerCase();
    const cards = h('div', { class: 'cards' }, tables);
    if (data) {
      const hid = data.hid.filter((r) => !q || (r.name + r.place).toLowerCase().includes(q));
      const c1 = card(cards, `Named temperature sensors (HID) · ${data.hid.length}`, 'Names are Apple\'s own. Read time = how long the sensor took to answer.');
      tbl(h('div', { class: 'scroll' }, c1), ['Sensor', 'Place', '°C', 'Read'], hid.map((r) => [r.name, r.place, r.c.toFixed(1), (r.us / 1000).toFixed(2) + ' ms']));
      const smc = data.smc.filter((r) => !q || (r.key + r.cat + (r.label || '')).toLowerCase().includes(q));
      const c2 = card(cards, `SMC keys · ${data.smc.length} sensor-like of ~2,000`, 'Temperature (T…), power (P…), voltage (V…), current (I…), fans (F…). Labels only where the community map names them.');
      tbl(h('div', { class: 'scroll' }, c2), ['Key', 'Kind', 'Value', 'Type', 'Read', 'Label'], smc.map((r) => [r.key, r.cat, typeof r.value === 'number' ? (Math.abs(r.value) < 100 ? r.value.toFixed(2) : r.value.toFixed(0)) : String(r.value), r.type, (r.us / 1000).toFixed(2) + ' ms', r.label || '']));
      const lat = data.latency || {};
      const c4 = card(cards, 'How fast each sensor family answers', 'Median read round trip in the last sweep.');
      kv(c4, Object.entries(lat).map(([k, v]) => [{ smc: 'SMC key', hid_pmu: 'PMU die sensor', hid_battery: 'Battery gas gauge', hid_ssd: 'NAND sensor' }[k] || k, `${(v.p50 / 1000).toFixed(2)} ms · ${v.n} sensors`]));
    }
    if (chans) {
      const rows = chans.filter((r) => !q || (r.group + r.examples.join(' ')).toLowerCase().includes(q));
      const c3 = card(cards, `IOReport counter groups · ${chans.reduce((s, r) => s + r.n, 0).toLocaleString()} channels`, 'Everything the kernel exposes without sudo. chipscope reads AMC Stats, Energy Model, CPU Stats, GPU Stats and Bandwidth.');
      tbl(h('div', { class: 'scroll' }, c3), ['Group', 'Channels', 'Units', 'Examples'], rows.map((r) => [r.group, String(r.n), r.units.join(' '), r.examples.slice(0, 4).join(', ')]));
    }
  };
  async function refresh() {
    data = await (await fetch('/api/sensors')).json();
    if (!chans) chans = await (await fetch('/api/channels')).json();
    draw();
  }
  return {
    tab: 'sensors',
    crumbs: () => [['Sensors', '#/sensors']],
    mount(stage) {
      p = page(stage, 'Every sensor and counter this Mac exposes', 'Read without sudo. The full SMC and HID sweep refreshes every 15 seconds.');
      filter = h('input', { class: 'filter', placeholder: 'Filter (e.g. nand, Tp0, GPU, battery)', oninput: () => draw() }, p);
      tables = h('div', { style: 'margin-top:12px' }, p);
      refresh();
      timer = setInterval(refresh, 15000);
    },
    unmount() { clearInterval(timer); },
    update() {},
    side(f, el) {
      h('h2', {}, el, 'Sensors');
      h('p', { class: 'explain' }, el, 'Three different paths: the SMC (a small processor in the SoC, about 2,000 keys), the HID event system (named sensors from the PMU, battery gas gauge and NAND), and IOReport (the kernel\'s performance counters behind the map).');
    },
  };
}

function tbl(parent, head, rows) {
  const t = h('table', { class: 't' }, parent);
  const hr = h('tr', {}, h('thead', {}, t));
  for (const x of head) h('th', {}, hr, x);
  const tb = h('tbody', {}, t);
  for (const r of rows) {
    const tr = h('tr', {}, tb);
    r.forEach((v, i) => h('td', { class: i > 1 && /^[-\d.]/.test(v) ? 'n' : '' }, tr, v));
  }
}
