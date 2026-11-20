// The two map levels: the whole Mac (board) and the M1 Pro chip (SoC).
import {
  S, svg, h, kv, heat, bwHeat, lin, fmtBps, fmtBytes, fmtW, fmtPct, fmtMHz, bindTip, addFlow, setFlow, current,
} from './lib.js';

// ------------------------------------------------------------------ explanations (Explain mode)
export const EXPLAIN = {
  pclu: 'Performance cores: wide out-of-order cores for heavy work. Each P-cluster has 4 core slots sharing one 12 MB L2 cache; on this chip slot 3 of each cluster is fused off at the factory.',
  eclu: 'Efficiency cores: lower clock, a fraction of the power. macOS runs background work here. The 2 cores share a 4 MB L2 cache.',
  core: 'One CPU core. Busy = share of time not idle. Clock = average frequency while busy, from the time spent in each DVFS (voltage/frequency) state.',
  l2: 'L2 cache shared by the cluster. Its traffic to the fabric is what the memory controller counts for this cluster.',
  gpu: 'The GPU. The die has 16 cores; this chip has 14 enabled. macOS reports one utilisation for the whole GPU, so every core tile shows the same value.',
  ane: 'Neural Engine (16 cores). Runs Core ML / Vision models. Idle unless an app runs a model on it. Heat is its power against a 3 W reference.',
  slc: 'System Level Cache: 24 MB shared by every agent on the chip. Requests that hit here never reach DRAM. Hit rate is derived: 1 − DRAM traffic / all agent traffic.',
  afc: 'CPU side of the on-chip fabric (coherent). Its counter matches the sum of the three CPU clusters - checked live.',
  afr: 'GPU side of the fabric: two ports, each matching one GPU memory port - checked live.',
  afi: 'I/O + media side of the fabric: Neural Engine, display, camera, video, SSD, PCIe and USB-C traffic.',
  mc: 'Memory controllers (DCS): the traffic that actually reaches DRAM. LPDDR5-6400 on a 256-bit bus = 200 GB/s peak (Apple spec). Heat is linear against that peak.',
  dram: 'Unified memory: two LPDDR5 packages on the SoC package, shared by CPU, GPU and everything else - there is no separate video memory.',
  media: 'Fixed-function media engines: video decode/encode, ProRes, JPEG and scaling. Counters are their memory traffic.',
  disp: 'Display engines read the frame buffer from memory on every refresh and send it to the screen.',
  isp: 'Image signal processor for the FaceTime camera. Busy only while the camera is on.',
  ans: 'Apple NVMe storage controller, inside the SoC. The NAND flash chips sit on the logic board.',
  pcie: 'PCIe links to the Wi-Fi/Bluetooth module and the SD card reader.',
  atc: 'USB-C / Thunderbolt 4 port controllers. Which physical port each one drives is not exposed.',
  smc: 'System Management Controller: a small processor inside the SoC that runs fans, sensors and power policy. About 2,000 keys; each read is a round trip to it.',
  sep: 'Secure Enclave: keys and Touch ID. It exposes no performance counters, by design.',
  dcp: 'Display coprocessor: firmware that drives the display pipeline. Only stack-usage counters are exposed.',
  pmgr: 'Power manager: sets every block\'s clock and voltage. The frequency tables used here come from its device-tree node.',
  soc: 'The M1 Pro: CPU, GPU, Neural Engine, caches, memory controllers, media and I/O on one 5 nm die (33.7 billion transistors, Apple spec).',
  nand: 'NAND flash chips that store your data. The controller that runs them is inside the SoC.',
  wifi: 'Wi-Fi 6 / Bluetooth module, connected to the SoC over PCIe.',
  battery: 'Battery. Power numbers come from the battery controller (AppleSmartBattery).',
  fan: 'Cooling fan. RPM from the SMC.',
  display: 'Built-in Liquid Retina XDR display. Heat = how much memory the display engine reads to refresh it.',
  pmu: 'Power-management ICs on the board report dozens of temperature sensors ("PMU tdie/tdev").',
  port: 'External port.',
};

function src(...lines) { return lines.join(' · '); }
// Rough capacity of each I/O block, for colour only (linear share).
const IO_PEAK = { media: 20e9, disp: 10e9, isp: 5e9, ans: 7e9, pcie: 4e9, atc: 10e9 };

// ------------------------------------------------------------------ metrics
const fmax = (type) => Math.max(...(S.topo.freqs[type] || [1]));
export function coreHeat(c, type) {
  if (!c) return null;
  if (S.heatBy === 'work') return c.busy * (c.mhz || 0) / fmax(type);
  if (S.heatBy === 'power') return c.w / (type === 'P' ? 5 : 0.6);
  return c.busy;
}
export function gpuHeat(g) {
  if (!g) return null;
  const u = g.util ?? g.busy;
  if (S.heatBy === 'power') return g.w / 20;
  if (S.heatBy === 'work') return u * (g.mhz || 0) / fmax('GPU');
  return u;
}
const agentBw = (f, a) => { const v = f.bw[a]; return v ? v[0] + v[1] : 0; };
const sumBw = (f, list) => list.reduce((s, a) => s + agentBw(f, a), 0);
const clusterOf = (id) => S.topo.clusters.find((c) => c.id === id);

export function coreTip(cl, core, f) {
  const c = f.cores[core.id];
  if (!c) return null;
  return {
    value: fmtPct(c.busy) + ' busy',
    label: `${cl.type}-core ${core.slot} · ${cl.label}`,
    rows: [['Clock (while busy)', fmtMHz(c.mhz) + ` of ${fmtMHz(fmax(cl.type))}`], ['Power (model)', fmtW(c.w)],
      ['Logical CPU', core.logical]],
    explain: EXPLAIN.core,
    src: src('IOReport CPU Core Performance States ' + core.ioreport, 'Energy Model ' + core.energy + ' (Apple estimate)'),
  };
}

// ------------------------------------------------------------------ shared SVG bits
function defs(root) {
  const d = svg('defs', {}, root);
  const p = svg('pattern', { id: 'hatch', width: 8, height: 8, patternUnits: 'userSpaceOnUse', patternTransform: 'rotate(45)' }, d);
  svg('rect', { width: 8, height: 8, fill: '#161615' }, p);
  svg('line', { x1: 0, y1: 0, x2: 0, y2: 8, stroke: '#3a3935', 'stroke-width': 3 }, p);
}

function rectBlock(g, o) {
  const r = svg('rect', { x: o.x, y: o.y, width: o.w, height: o.h, rx: o.rx ?? 6, class: o.cls || 'blk', fill: '#202124' }, g);
  let lbl = null, val = null, val2 = null;
  if (o.label) lbl = svg('text', { x: o.x + (o.center ? o.w / 2 : 8), y: o.y + (o.ly ?? 17), class: 'lbl', 'text-anchor': o.center ? 'middle' : 'start' }, g, o.label);
  if (o.value !== false) val = svg('text', { x: o.x + (o.center ? o.w / 2 : 8), y: o.y + (o.vy ?? 33), class: 'val', 'text-anchor': o.center ? 'middle' : 'start' }, g, '');
  if (o.value2) val2 = svg('text', { x: o.x + (o.center ? o.w / 2 : 8), y: o.y + (o.vy2 ?? 48), class: 'val', 'text-anchor': o.center ? 'middle' : 'start' }, g, '');
  if (o.nav) r.addEventListener('click', () => { location.hash = o.nav; });
  else if (o.sel) r.addEventListener('click', () => { S.sel = o.sel; window.dispatchEvent(new Event('chipscope:select')); });
  if (o.tip) bindTip(r, () => { const f = current(); return f ? o.tip(f) : null; });
  return { r, lbl, val, val2 };
}

function flowPair(g, d, dx = 3, dy = 0) {
  // Two lanes on one route: writes travel toward memory (dir +1), reads come back (dir -1).
  const wr = svg('path', { d, class: 'flow wr', transform: `translate(${dx},${dy})` }, g);
  const rd = svg('path', { d, class: 'flow rd', transform: `translate(${-dx},${-dy})` }, g);
  return { wr: addFlow(wr, 1), rd: addFlow(rd, -1) };
}
function setPair(p, rd, wr, peak) { setFlow(p.rd, rd, peak); setFlow(p.wr, wr, peak); }

// ================================================================== SoC view
export function socView() {
  let root, parts = {}, pairs = {};
  return {
    tab: 'map',
    crumbs: () => [['Mac', '#/mac'], [S.topo.chip, '#/soc']],
    mount(stage) {
      const T = S.topo;
      root = svg('svg', { viewBox: '0 0 1180 810', preserveAspectRatio: 'xMidYMin meet' }, stage);
      defs(root);
      const spec = T.spec || {};
      const pc = T.clusters.filter((c) => c.type === 'P').reduce((n, c) => n + c.cores.filter((x) => !x.fused).length, 0);
      const ec = T.clusters.filter((c) => c.type === 'E').reduce((n, c) => n + c.cores.filter((x) => !x.fused).length, 0);
      svg('text', { x: 24, y: 28, class: 'title' }, root,
        `${T.chip} · ${pc}P + ${ec}E CPU · ${T.gpu.cores}-core GPU · ${spec.ane_cores || '?'}-core Neural Engine`);
      svg('text', { x: 1160, y: 28, class: 'cap', 'text-anchor': 'end' }, root, 'architectural schematic · not to scale · click a block');
      svg('rect', { x: 20, y: 40, width: 1145, height: 755, rx: 14, class: 'pkg' }, root);
      svg('rect', { x: 40, y: 70, width: 860, height: 705, rx: 8, class: 'die' }, root);
      svg('text', { x: 52, y: 62, class: 'cap' }, root, 'SoC package');
      svg('text', { x: 892, y: 88, class: 'cap', 'text-anchor': 'end' }, root, 'die');
      const flowsG = svg('g', {}, root);
      const g = svg('g', {}, root);

      // ---- CPU clusters
      let x = 60;
      for (const cl of T.clusters.slice().sort((a, b) => (a.type === b.type ? a.id.localeCompare(b.id) : a.type === 'P' ? -1 : 1))) {
        const w = cl.type === 'P' ? 190 : 130;
        const y = 90;
        rectBlock(g, { x, y, w, h: 270, cls: 'blk', nav: `#/cluster/${cl.id}`, label: cl.type === 'P' ? cl.label.replace(' (performance)', '') : 'E-cluster', value: false,
          tip: (f) => { const c = f.clusters[cl.id]; return { value: fmtPct(c.busy) + ' avg busy', label: cl.label,
            rows: [['Cluster clock', fmtMHz(c.mhz)], ['Cores power (model)', fmtW(c.w_cores)], ['Shared logic power', fmtW(c.w_shared)],
              ['L2 ↔ fabric', fmtBps(agentBw(f, cl.amc))]], explain: EXPLAIN[cl.type === 'P' ? 'pclu' : 'eclu'],
            src: src('IOReport CPU Complex Performance States ' + cl.ioreport, 'Energy Model ' + cl.energy + '_CPU/_CPM') }; } }).r.setAttribute('fill', '#1b1b1a');
        cl.cores.forEach((core, i) => {
          const cx = cl.type === 'P' ? x + 12 + (i % 2) * 86 : x + 12;
          const cy = cl.type === 'P' ? y + 30 + Math.floor(i / 2) * 88 : y + 30 + i * 88;
          const cw = cl.type === 'P' ? 80 : 106;
          if (core.fused) {
            const r = svg('rect', { x: cx, y: cy, width: cw, height: 80, rx: 5, class: 'ghost' }, g);
            svg('text', { x: cx + cw / 2, y: cy + 36, class: 'tiny', 'text-anchor': 'middle' }, g, 'fused off');
            svg('text', { x: cx + cw / 2, y: cy + 50, class: 'tiny', 'text-anchor': 'middle' }, g, `slot ${core.slot}`);
            bindTip(r, () => ({ value: 'Fused off', label: `${cl.label}, slot ${core.slot}`,
              rows: [['Evidence', 'no cpu node in the device tree'], ['Energy channel', `${cl.energy}_CPU${core.slot} exists, reads 0`]],
              explain: 'Disabled at the factory in one-time fuses (binning). Nothing in software can turn it on.',
              src: 'device tree /cpus · IOReport Energy Model' }));
            return;
          }
          parts[core.id] = rectBlock(g, { x: cx, y: cy, w: cw, h: 80, rx: 5, label: `${cl.type}${core.slot}`, value2: true, vy: 52, vy2: 68,
            nav: `#/core/${core.id}`, tip: (f) => coreTip(cl, core, f) });
        });
        parts['l2_' + cl.id] = rectBlock(g, { x: x + 12, y: y + 208, w: w - 24, h: 50, rx: 5, label: `${(cl.l2 / 2 ** 20).toFixed(0)} MB L2`, nav: `#/cluster/${cl.id}`,
          tip: (f) => { const v = f.bw[cl.amc] || [0, 0, 0, 0]; return { value: fmtBps(v[0] + v[1]), label: `${cl.label} L2 ↔ fabric`,
            rows: [['Read', fmtBps(v[0])], ['Write', fmtBps(v[1])], ['…of which reached DRAM', fmtBps(v[2] + v[3])]], explain: EXPLAIN.l2,
            src: src('IOReport AMC Stats ' + cl.amc + ' RD/WR') }; } });
        pairs[cl.id] = flowPair(flowsG, `M${x + w / 2},360 L${x + w / 2},392`, 4, 0);
        x += w + 12;
      }

      // ---- GPU
      const GX = 614, GY = 90;
      rectBlock(g, { x: GX, y: GY, w: 266, h: 270, label: `GPU · ${T.gpu.cores} of ${spec.gpu_die_cores || T.gpu.cores} cores`, nav: '#/gpu', value: false,
        tip: (f) => gpuTip(f) }).r.setAttribute('fill', '#1b1b1a');
      const dieCores = spec.gpu_die_cores || T.gpu.cores;
      parts.gpuTiles = [];
      for (let i = 0; i < dieCores; i++) {
        const tx = GX + 14 + (i % 4) * 62, ty = GY + 28 + Math.floor(i / 4) * 56;
        if (i >= T.gpu.cores) {
          const r = svg('rect', { x: tx, y: ty, width: 54, height: 48, rx: 4, class: 'ghost' }, g);
          svg('text', { x: tx + 27, y: ty + 29, class: 'tiny', 'text-anchor': 'middle' }, g, '?');
          bindTip(r, () => ({ value: `${dieCores - T.gpu.cores} of ${dieCores} fused off`, label: 'GPU core slots',
            explain: 'The die has ' + dieCores + ' GPU cores; ' + T.gpu.cores + ' are enabled. Which positions are off is not exposed, so these two tiles are placeholders.',
            src: 'IOKit gpu-core-count · Apple spec' }));
          continue;
        }
        const r = svg('rect', { x: tx, y: ty, width: 54, height: 48, rx: 4, class: 'blk', fill: '#202124' }, g);
        r.addEventListener('click', () => { location.hash = '#/gpu'; });
        bindTip(r, () => { const f = current(); return f ? gpuTip(f) : null; });
        parts.gpuTiles.push(r);
      }
      parts.gpuVal = svg('text', { x: GX + 133, y: GY + 262, class: 'val', 'text-anchor': 'middle' }, g, '');
      pairs.gfx = flowPair(flowsG, `M${GX + 80},360 L${GX + 80},392`, 4, 0);
      pairs.gfx1 = flowPair(flowsG, `M${GX + 186},360 L${GX + 186},392`, 4, 0);

      // ---- fabric + SLC + memory controllers
      parts.afc = rectBlock(g, { x: 60, y: 392, w: 534, h: 20, rx: 4, label: 'CPU fabric · AFC', ly: 14, value: false, sel: 'afc',
        tip: (f) => fabricTip(f, 'AFC', EXPLAIN.afc) });
      parts.afr = rectBlock(g, { x: 614, y: 392, w: 266, h: 20, rx: 4, label: 'GPU fabric · AFR A/B', ly: 14, value: false, sel: 'afr',
        tip: (f) => fabricTip(f, 'AFR_A', EXPLAIN.afr, 'AFR_B') });
      pairs.afc = flowPair(flowsG, 'M327,412 L327,450', 5, 0);
      pairs.afr = flowPair(flowsG, 'M747,412 L747,450', 5, 0);
      parts.slc = rectBlock(g, { x: 60, y: 450, w: 640, h: 66, label: `System Level Cache · ${((spec.slc_bytes || 0) / 2 ** 20).toFixed(0)} MB`, value2: true, sel: 'slc',
        tip: (f) => ({ value: f.mem.slc_hit === null ? '— (too little traffic)' : fmtPct(f.mem.slc_hit) + ' served on-chip',
          label: 'System Level Cache (derived hit rate)', rows: [['All agent traffic', fmtBps(f.mem.agents_total)],
            ['Reached DRAM', fmtBps(f.mem.dram_rd + f.mem.dram_wr)], ['Cache + controller power', fmtW(f.mem.amcc_w)]],
          explain: EXPLAIN.slc, src: src('IOReport AMC Stats: sum of agent RD/WR vs DCS RD/WR', 'Energy Model AMCC0') }) });
      parts.mc = rectBlock(g, { x: 712, y: 450, w: 168, h: 66, label: 'Memory controllers', value2: true, nav: '#/memory',
        tip: (f) => ({ value: fmtBps(f.mem.dram_rd + f.mem.dram_wr), label: 'Traffic reaching DRAM',
          rows: [['Read', fmtBps(f.mem.dram_rd)], ['Write', fmtBps(f.mem.dram_wr)], ['Of peak', fmtPct((f.mem.dram_rd + f.mem.dram_wr) / (spec.mem_peak_bw || 200e9))],
            ['Controller power', fmtW(f.mem.dcs_w)]], explain: EXPLAIN.mc, src: src('IOReport AMC Stats DCS RD/WR', 'Energy Model DCS0') }) });
      pairs.slcmc = flowPair(flowsG, 'M700,483 L712,483', 0, 4);
      parts.afi = rectBlock(g, { x: 60, y: 556, w: 820, h: 20, rx: 4, label: 'I/O + media fabric · AF_I', ly: 14, value: false, sel: 'afi',
        tip: (f) => fabricTip(f, 'AF_I', EXPLAIN.afi) });
      pairs.afi = flowPair(flowsG, 'M380,556 L380,516', 5, 0);

      // ---- DRAM packages
      svg('text', { x: 925, y: 96, class: 'lbl' }, root, `Unified memory · ${fmtBytes(T.memory_bytes)}`);
      svg('text', { x: 925, y: 112, class: 'cap' }, root, `${spec.mem_type || 'LPDDR'} · ${spec.mem_bus_bits || '?'}-bit · ${fmtBps(spec.mem_peak_bw)} peak`);
      parts.dram = [];
      for (let i = 0; i < (spec.mem_packages || 2); i++) {
        const y = 130 + i * 300;
        parts.dram.push(rectBlock(g, { x: 930, y, w: 215, h: 260, label: `LPDDR5 package ${i + 1}`, value2: true, nav: '#/memory',
          tip: (f) => ({ value: fmtBps(f.mem.dram_rd + f.mem.dram_wr), label: 'DRAM traffic (both packages)',
            rows: [['DRAM power', fmtW(f.mem.dram_w)]], explain: EXPLAIN.dram, src: src('IOReport AMC Stats DCS', 'Energy Model DRAM0') }) }));
      }
      pairs.dramA = flowPair(flowsG, 'M880,470 C905,470 905,260 930,260', 0, 4);
      pairs.dramB = flowPair(flowsG, 'M880,500 C905,500 905,560 930,560', 0, 4);

      // ---- bottom band: accelerators + I/O
      const B = 610;
      parts.ane = rectBlock(g, { x: 60, y: B, w: 150, h: 112, label: 'Neural Engine', sel: 'ane', value: false,
        tip: (f) => ({ value: fmtW(f.ane.w), label: `Neural Engine (${spec.ane_cores || 16} cores)`,
          rows: [['Memory traffic', fmtBps(agentBw(f, 'ANE0'))]], explain: EXPLAIN.ane, src: src('Energy Model ANE0', 'AMC Stats ANE0') }) });
      parts.aneCells = [];
      for (let i = 0; i < 16; i++) {
        parts.aneCells.push(svg('rect', { x: 72 + (i % 8) * 16.5, y: B + 30 + Math.floor(i / 8) * 18, width: 13, height: 14, rx: 2, fill: '#202124', 'pointer-events': 'none' }, g));
      }
      parts.aneVal = svg('text', { x: 68, y: B + 100, class: 'val' }, g, '');
      const ioBlocks = [
        ['media', 'Media', 218, 150, ['VDEC', 'VENC0', 'STRM CODEC', 'JPG0', 'JPG1', 'MSR0'], EXPLAIN.media],
        ['disp', 'Display', 376, 110, ['DISP', 'EXT DISP0', 'EXT DISP1'], EXPLAIN.disp],
        ['isp', 'Camera ISP', 494, 80, ['ISP'], EXPLAIN.isp],
        ['ans', 'SSD ctrl', 582, 80, ['ANS'], EXPLAIN.ans],
        ['pcie', 'PCIe', 670, 70, ['PCIE LN'], EXPLAIN.pcie],
        ['atc', 'USB-C / TB', 748, 132, ['ATC0', 'ATC1', 'ATC2', 'ATC3'], EXPLAIN.atc],
      ];
      parts.io = [];
      for (const [id, label, bx, bw, agents, ex] of ioBlocks) {
        const b = rectBlock(g, { x: bx, y: B, w: bw, h: 112, label, value2: true, sel: id,
          tip: (f) => ({ value: fmtBps(sumBw(f, agents)), label: label + ' memory traffic',
            rows: agents.filter((a) => f.bw[a]).map((a) => [T.agents[a].label + (T.agents[a].guess ? ' (name guessed)' : ''), fmtBps(agentBw(f, a))]),
            explain: ex, src: src('IOReport AMC Stats ' + agents.join(', ')) }) });
        parts.io.push({ b, agents, id });
        pairs['io_' + id] = flowPair(flowsG, `M${bx + bw / 2},${B} L${bx + bw / 2},576`, 4, 0);
      }
      // ---- infrastructure row (no live counters, or sensors only)
      const infra = [['smc', 'SMC · fans & sensors'], ['sep', 'Secure Enclave'], ['dcp', 'Display coprocessor'], ['pmgr', 'Power manager']];
      infra.forEach(([id, label], i) => {
        const b = rectBlock(g, { x: 60 + i * 207, y: 732, w: 200, h: 32, label, ly: 21, value: false, sel: id, cls: 'blk',
          tip: () => ({ label, explain: EXPLAIN[id], value: id === 'smc' ? 'sensor hub' : 'no load counters', src: id === 'pmgr' ? 'device tree pmgr voltage-states' : '' }) });
        b.r.setAttribute('fill', '#1b1b1a');
      });
    },
    update(f) {
      const T = S.topo;
      for (const cl of T.clusters) {
        for (const core of cl.cores) {
          if (core.fused) continue;
          const p = parts[core.id], c = f.cores[core.id];
          if (!p || !c) continue;
          p.r.setAttribute('fill', heat(coreHeat(c, cl.type)));
          p.val.textContent = fmtPct(c.busy);
          p.val2.textContent = fmtMHz(c.mhz);
        }
        const l2 = parts['l2_' + cl.id];
        const v = f.bw[cl.amc] || [0, 0];
        l2.r.setAttribute('fill', heat(lin(v[0] + v[1], 100e9)));
        l2.val.textContent = fmtBps(v[0] + v[1]);
        setPair(pairs[cl.id], v[0], v[1]);
      }
      const gh = heat(gpuHeat(f.gpu));
      for (const r of parts.gpuTiles) r.setAttribute('fill', gh);
      parts.gpuVal.textContent = `${fmtPct(f.gpu.util ?? f.gpu.busy)} · ${fmtMHz(f.gpu.mhz)} · ${fmtW(f.gpu.w)}`;
      const g0 = f.bw.GFX || [0, 0], g1 = f.bw.GFX1 || [0, 0];
      setPair(pairs.gfx, g0[0], g0[1]);
      setPair(pairs.gfx1, g1[0], g1[1]);
      const fab = (k) => f.fabric[k] || [0, 0, 0];
      parts.afc.r.setAttribute('fill', heat(lin(fab('AFC')[0] + fab('AFC')[1], 200e9)));
      parts.afr.r.setAttribute('fill', heat(lin(fab('AFR_A')[0] + fab('AFR_A')[1] + fab('AFR_B')[0] + fab('AFR_B')[1], 200e9)));
      parts.afi.r.setAttribute('fill', heat(lin(fab('AF_I')[0] + fab('AF_I')[1], 50e9)));
      setPair(pairs.afc, fab('AFC')[0], fab('AFC')[1]);
      setPair(pairs.afr, fab('AFR_A')[0] + fab('AFR_B')[0], fab('AFR_A')[1] + fab('AFR_B')[1]);
      setPair(pairs.afi, fab('AF_I')[0], fab('AF_I')[1]);
      parts.slc.r.setAttribute('fill', heat(lin(f.mem.agents_total, 200e9)));
      parts.slc.val.textContent = `${fmtBps(f.mem.agents_total)} from all agents`;
      parts.slc.val2.textContent = f.mem.slc_hit === null ? 'hit rate: — (little traffic)' : `≈ ${fmtPct(f.mem.slc_hit)} served on-chip (derived)`;
      const dram = f.mem.dram_rd + f.mem.dram_wr;
      const peak = (T.spec && T.spec.mem_peak_bw) || 200e9;
      parts.mc.r.setAttribute('fill', heat(dram / peak));
      parts.mc.val.textContent = fmtBps(dram);
      parts.mc.val2.textContent = fmtPct(dram / peak) + ' of peak';
      setPair(pairs.slcmc, f.mem.dram_rd, f.mem.dram_wr);
      setPair(pairs.dramA, f.mem.dram_rd / 2, f.mem.dram_wr / 2);
      setPair(pairs.dramB, f.mem.dram_rd / 2, f.mem.dram_wr / 2);
      for (const d of parts.dram) {
        d.r.setAttribute('fill', heat(dram / peak));
        d.val.textContent = fmtBps(dram / parts.dram.length) + ' (share)';
        d.val2.textContent = 'DRAM ' + fmtW(f.mem.dram_w) + ' total';
      }
      const ah = heat(f.ane.w / 3);
      parts.ane.r.setAttribute('fill', f.ane.w > 0.005 ? '#26201f' : '#202124');
      for (const c of parts.aneCells) c.setAttribute('fill', ah);
      parts.aneVal.textContent = fmtW(f.ane.w);
      for (const { b, agents, id } of parts.io) {
        const bw = sumBw(f, agents);
        b.r.setAttribute('fill', heat(lin(bw, IO_PEAK[id])));
        b.val.textContent = fmtBps(bw);
        const rd = agents.reduce((s, a) => s + (f.bw[a] ? f.bw[a][0] : 0), 0);
        setPair(pairs['io_' + id], rd, bw - rd, 10e9);
        b.val2.textContent = id === 'media' ? fmtW(f.media.ave_w + f.media.msr_w) : id === 'isp' ? fmtW(f.media.isp_w) : id === 'pcie' ? fmtW(f.pcie.w) : '';
      }
    },
    side(f, el) { socSide(f, el); },
  };
}

function gpuTip(f) {
  const g = f.gpu;
  return {
    value: fmtPct(g.util ?? g.busy) + ' utilised', label: `GPU (${S.topo.gpu.cores} cores)`,
    rows: [['Clock', fmtMHz(g.mhz)], ['Powered on', fmtPct(g.busy)], ['Power (model)', fmtW(g.w)], ['Memory in use', fmtBytes(g.mem_used)],
      ['Memory traffic', fmtBps(agentBw(f, 'GFX') + agentBw(f, 'GFX1'))]],
    explain: EXPLAIN.gpu, src: src('IOKit AGX PerformanceStatistics', 'IOReport GPU Performance States', 'Energy Model GPU'),
  };
}

function fabricTip(f, a, ex, b) {
  const v = (k) => f.fabric[k] || [0, 0, 0];
  const total = v(a)[0] + v(a)[1] + (b ? v(b)[0] + v(b)[1] : 0);
  const members = v(a)[2] + (b ? v(b)[2] : 0);
  return {
    value: fmtBps(total), label: S.topo.fabric[a].label + (b ? ' + ' + S.topo.fabric[b].label : ''),
    rows: [['Read', fmtBps(v(a)[0] + (b ? v(b)[0] : 0))], ['Write', fmtBps(v(a)[1] + (b ? v(b)[1] : 0))],
      ['Sum of its agents', fmtBps(members)], ['Check', total > 1e6 ? (members / total * 100).toFixed(1) + '% of port traffic' : '—']],
    explain: ex, src: src('IOReport AMC Stats ' + a + (b ? ', ' + b : '') + ' RD/WR'),
  };
}

function socSide(f, el) {
  const T = S.topo;
  h('h2', {}, el, T.chip);
  h('div', { class: 'sub' }, el, `${T.spec?.process || ''} · ${T.spec?.transistors || ''} transistors`);
  if (S.explain) h('p', { class: 'explain' }, el, EXPLAIN.soc);
  h('h3', {}, el, 'Power (Apple energy model)');
  const total = f.cpu_w + f.gpu.w + f.ane.w + f.mem.dram_w + f.mem.amcc_w + f.mem.dcs_w;
  kv(el, [['CPU', fmtW(f.cpu_w)], ['GPU', fmtW(f.gpu.w)], ['Neural Engine', fmtW(f.ane.w)], ['DRAM', fmtW(f.mem.dram_w)],
    ['Cache + memory controllers', fmtW(f.mem.amcc_w + f.mem.dcs_w)], ['Sum of these', fmtW(total)]]);
  h('div', { class: 'src' }, el, 'IOReport "Energy Model": Apple\'s on-chip estimate, not a shunt measurement.');
  h('h3', {}, el, 'Who is using memory bandwidth');
  const rows = Object.entries(f.bw).map(([a, v]) => [a, v[0] + v[1]]).filter(([, v]) => v > 1e5).sort((a, b) => b[1] - a[1]).slice(0, 8);
  kv(el, rows.map(([a, v]) => [T.agents[a]?.label || a, fmtBps(v)]));
  if (!rows.length) h('div', { class: 'src' }, el, 'Nothing above 100 kB/s.');
  if (S.sel) blockSide(f, el, S.sel);
  procsSide(f, el);
}

function blockSide(f, el, id) {
  const T = S.topo;
  const names = { afc: 'CPU fabric', afr: 'GPU fabric', afi: 'I/O + media fabric', slc: 'System Level Cache', ane: 'Neural Engine', media: 'Media engines',
    disp: 'Display engines', isp: 'Camera ISP', ans: 'SSD controller', pcie: 'PCIe', atc: 'USB-C / Thunderbolt', smc: 'SMC', sep: 'Secure Enclave', dcp: 'Display coprocessor', pmgr: 'Power manager' };
  if (!names[id]) return;
  h('h3', {}, el, 'Selected: ' + names[id]);
  h('p', { class: 'explain' }, el, EXPLAIN[id] || '');
  if (id === 'smc') {
    const b = f.board || {};
    kv(el, [...(b.fans || []).map((x, i) => [`Fan ${i + 1}`, `${x.rpm} rpm (${x.min}–${x.max})`]),
      ...Object.entries(b.smc_power || {}).map(([k, v]) => [k, v + ' W (raw key)'])]);
  }
  if (id === 'pmgr') {
    kv(el, [['E-core clocks', T.freqs.E.join(', ') + ' MHz'], ['P-core clocks', T.freqs.P.join(', ') + ' MHz'], ['GPU clocks', T.freqs.GPU.filter((x) => x).join(', ') + ' MHz']]);
  }
  const agentsFor = { ane: ['ANE0'], media: ['VDEC', 'VENC0', 'STRM CODEC', 'JPG0', 'JPG1', 'MSR0'], disp: ['DISP', 'EXT DISP0', 'EXT DISP1'], isp: ['ISP'], ans: ['ANS'], pcie: ['PCIE LN'], atc: ['ATC0', 'ATC1', 'ATC2', 'ATC3'] };
  if (agentsFor[id]) {
    kv(el, agentsFor[id].filter((a) => f.bw[a]).flatMap((a) => [[T.agents[a].label + ' read', fmtBps(f.bw[a][0])], [T.agents[a].label + ' write', fmtBps(f.bw[a][1])]]));
  }
  if (id === 'ans' && f.board?.disk) {
    const d = f.board.disk;
    kv(el, [['Disk read', fmtBps(d.rd_bps)], ['Disk write', fmtBps(d.wr_bps)], ['Read latency (driver avg)', d.rd_lat_us ? d.rd_lat_us.toFixed(0) + ' µs' : '—']]);
  }
}

export function procsSide(f, el) {
  const b = f.board || {};
  if (!b.procs) return;
  h('h3', {}, el, 'Top processes (CPU)');
  const t = h('table', { class: 't procs' }, el);
  const hr = h('tr', {}, h('thead', {}, t));
  h('th', {}, hr, 'Process'); h('th', {}, hr, 'CPU'); h('th', {}, hr, 'Memory');
  const tb = h('tbody', {}, t);
  for (const [, name, pcpu, rss] of b.procs.slice(0, 10)) {
    const tr = h('tr', {}, tb);
    h('td', { title: name }, tr, name);
    h('td', { class: 'n' }, tr, pcpu.toFixed(0) + '%');
    h('td', { class: 'n' }, tr, fmtBytes(rss));
  }
  h('div', { class: 'src' }, el, `ps %CPU (100% = one core, decaying average) · load average ${(b.load || []).join(' / ')} · chipscope itself: ${b.self_cpu ?? '—'}% of a core`);
}

// ================================================================== Mac (board) view
export function macView() {
  let root, p = {}, pairs = {}, fans = [], fanAngle = [0, 0], raf = null, last = performance.now();
  return {
    tab: 'map',
    crumbs: () => [['Mac', '#/mac']],
    mount(stage) {
      const T = S.topo;
      const board = T.board || {};
      root = svg('svg', { viewBox: '0 0 1180 800', preserveAspectRatio: 'xMidYMin meet' }, stage);
      defs(root);
      svg('text', { x: 24, y: 24, class: 'title' }, root, `${board.name || T.model} · ${T.model}`);
      svg('text', { x: 1160, y: 24, class: 'cap', 'text-anchor': 'end' }, root, 'inside view from above · schematic, not to scale · click the chip to go deeper');
      // display along the hinge
      p.display = rectBlock(root, { x: 40, y: 40, w: 1100, h: 26, rx: 6, label: 'Display · ' + (board.display || ''), ly: 18, value: false, sel: 'display',
        tip: (f) => ({ value: fmtBps(agentBw(f, 'DISP')), label: 'Display engine reads (frame refresh)', explain: EXPLAIN.display, src: 'IOReport AMC Stats DISP' }) });
      p.camera = svg('circle', { cx: 590, cy: 53, r: 7, class: 'blk', fill: '#202124' }, root);
      bindTip(p.camera, () => { const f = current(); return f ? { value: fmtBps(agentBw(f, 'ISP')), label: 'FaceTime camera → ISP', explain: EXPLAIN.isp, src: 'IOReport AMC Stats ISP' } : null; });
      svg('rect', { x: 40, y: 76, width: 1100, height: 700, rx: 40, class: 'chassis' }, root);
      const flowsG = svg('g', {}, root);
      const g = svg('g', {}, root);
      // fans
      for (const [i, cx] of [[0, 160], [1, 1020]]) {
        const fg = svg('g', { transform: `translate(${cx},200)` }, g);
        const ring = svg('circle', { r: 70, class: 'blk', fill: '#202124' }, fg);
        const blades = svg('g', {}, fg);
        for (let k = 0; k < 9; k++) svg('path', { d: 'M0,-10 C18,-30 22,-52 6,-64 L-4,-12 Z', fill: '#4a4944', transform: `rotate(${k * 40})` }, blades);
        svg('circle', { r: 12, fill: '#2c2c2a' }, fg);
        svg('text', { y: 92, class: 'val', 'text-anchor': 'middle' }, fg, '');
        fans.push({ ring, blades, txt: fg.lastChild });
        bindTip(ring, () => { const f = current(); const x = f?.board?.fans?.[i]; return x ? { value: `${x.rpm} rpm`, label: `Fan ${i + 1}`, rows: [['Range', `${x.min}–${x.max} rpm`]], explain: EXPLAIN.fan, src: `SMC F${i}Ac / F${i}Mn / F${i}Mx` } : null; });
      }
      // logic board
      svg('path', { d: 'M260,96 L920,96 L920,370 L760,370 L740,400 L440,400 L420,370 L260,370 Z', class: 'board' }, g);
      svg('text', { x: 272, y: 116, class: 'cap' }, g, 'logic board');
      // SoC package with die + DRAM
      svg('rect', { x: 470, y: 130, width: 340, height: 210, rx: 10, class: 'pkg' }, g);
      svg('text', { x: 480, y: 146, class: 'tiny' }, g, 'SoC package');
      p.soc = rectBlock(g, { x: 485, y: 155, w: 205, h: 170, label: T.chip, value2: true, nav: '#/soc',
        tip: (f) => ({ value: fmtW(f.cpu_w + f.gpu.w + f.ane.w), label: T.chip + ' (CPU + GPU + Neural Engine power)',
          rows: [['CPU', fmtW(f.cpu_w)], ['GPU', fmtW(f.gpu.w)], ['Neural Engine', fmtW(f.ane.w)], ['Die sensors (max)', f.board?.hid?.soc ? f.board.hid.soc.max + ' °C' : '—']],
          explain: EXPLAIN.soc, src: 'IOReport Energy Model · HID PMU sensors' }) });
      p.socTemp = svg('text', { x: 493, y: 223, class: 'val' }, g, '');
      p.ram = [0, 1].map((i) => rectBlock(g, { x: 700, y: 155 + i * 88, w: 100, h: 82, label: 'LPDDR5', value2: true, nav: '#/memory',
        tip: (f) => ({ value: fmtBps(f.mem.dram_rd + f.mem.dram_wr), label: `Unified memory (${fmtBytes(T.memory_bytes)}, both packages)`,
          rows: [['Read', fmtBps(f.mem.dram_rd)], ['Write', fmtBps(f.mem.dram_wr)], ['Power', fmtW(f.mem.dram_w)]], explain: EXPLAIN.dram, src: 'IOReport AMC Stats DCS · Energy Model DRAM0' }) }));
      // NAND
      p.nand = [0, 1].map((i) => rectBlock(g, { x: 290, y: 150 + i * 92, w: 120, h: 80, label: 'NAND flash', value2: true, sel: 'ans',
        tip: (f) => { const d = f.board?.disk || {}; return { value: fmtBps((d.rd_bps || 0) + (d.wr_bps || 0)), label: `SSD · ${T.ssd?.model || ''}`,
          rows: [['Read', fmtBps(d.rd_bps)], ['Write', fmtBps(d.wr_bps)], ['Read latency (driver avg)', d.rd_lat_us ? d.rd_lat_us.toFixed(0) + ' µs' : '—'],
            ['NAND temperature', f.board?.hid?.ssd ? f.board.hid.ssd.max + ' °C' : '—']], explain: EXPLAIN.nand, src: 'IOBlockStorageDriver Statistics · HID "NAND CH0 temp"' }; } }));
      // Wi-Fi + PMU
      p.wifi = rectBlock(g, { x: 830, y: 150, w: 80, h: 90, label: 'Wi-Fi/BT', value2: true, sel: 'pcie',
        tip: (f) => { const n = f.board?.net?.en0 || [0, 0]; return { value: fmtBps(n[0] + n[1]), label: 'Wi-Fi ' + (T.wifi?.card || ''),
          rows: [['Receive', fmtBps(n[0])], ['Send', fmtBps(n[1])], ['Link', T.wifi?.phy ? `${T.wifi.phy}, ch ${T.wifi.channel}` : '—']], explain: EXPLAIN.wifi, src: 'netstat -ib en0 · system_profiler' }; } });
      p.pmu = rectBlock(g, { x: 830, y: 255, w: 80, h: 70, label: 'PMU', value2: true, sel: 'smc',
        tip: (f) => ({ value: f.board?.hid?.soc ? f.board.hid.soc.max + ' °C max' : '—', label: 'Power-management sensors',
          rows: [['Average', f.board?.hid?.soc ? f.board.hid.soc.avg + ' °C' : '—']], explain: EXPLAIN.pmu, src: 'HID event system, "PMU tdie/tdev" sensors' }) });
      // ports
      const ports = board.ports || [];
      const left = ports.filter((x) => x.includes('left')), right = ports.filter((x) => x.includes('right'));
      p.portSlots = [];
      left.forEach((name, i) => p.portSlots.push(portBlock(g, 24, 430 + i * 56, name.replace(' (left)', ''), 'left')));
      right.forEach((name, i) => p.portSlots.push(portBlock(g, 1128, 430 + i * 56, name.replace(' (right)', ''), 'right')));
      // battery
      p.batt = rectBlock(g, { x: 200, y: 470, w: 780, h: 270, rx: 16, label: 'Battery', value2: true, sel: 'battery',
        tip: (f) => { const b = f.board?.battery || {}; return { value: `${b.percent ?? '—'}%`, label: b.charging ? 'Charging' : b.plugged ? 'Plugged in' : 'On battery',
          rows: [['Power into battery', b.batt_w !== null && b.batt_w !== undefined ? fmtW(b.batt_w) : '—'], ['Adapter in', fmtW(b.sys_in_w)], ['System load', fmtW(b.sys_load_w)],
            ['Voltage / current', b.volts ? `${b.volts.toFixed(2)} V / ${b.amps.toFixed(2)} A` : '—'], ['Temperature', b.temp_c ? b.temp_c.toFixed(1) + ' °C' : '—'],
            ['Health', b.health ? fmtPct(b.health) + ` · ${b.cycles} cycles` : '—']], explain: EXPLAIN.battery, src: 'IOKit AppleSmartBattery (PowerTelemetryData)' }; } });
      p.battCells = [];
      for (let i = 0; i < 6; i++) {
        const cx = 230 + (i % 3) * 245, cy = 520 + Math.floor(i / 3) * 105;
        svg('rect', { x: cx, y: cy, width: 225, height: 90, rx: 8, fill: '#151515', stroke: '#34332f', 'pointer-events': 'none' }, g);
        p.battCells.push(svg('rect', { x: cx + 2, y: cy + 2, width: 0, height: 86, rx: 7, fill: '#0ca30c', opacity: 0.35, 'pointer-events': 'none' }, g));
      }
      // speakers
      for (const sx of [70, 1060]) {
        const r = svg('rect', { x: sx, y: 320, width: 50, height: 120, rx: 10, fill: 'url(#hatch)', stroke: '#34332f' }, g);
        bindTip(r, () => ({ label: 'Speaker', value: 'no counters' }));
      }
      // flows
      pairs.nand = flowPair(flowsG, 'M410,240 L485,240', 0, 4);
      pairs.ram = flowPair(flowsG, 'M690,240 L700,240', 0, 4);
      pairs.wifi = flowPair(flowsG, 'M830,195 C800,195 760,120 690,170', 0, 4);
      pairs.disp = flowPair(flowsG, 'M587,155 L587,66', 4, 0);
      // Charger power arrives through MagSafe or any USB-C port; drawn from the MagSafe side.
      p.pwrIn = addFlow(svg('path', { d: 'M54,560 C150,560 200,420 300,380', class: 'flow pw' }, flowsG), 1);
      p.pwrBatt = svg('path', { d: 'M590,325 L590,470', class: 'flow pw' }, flowsG);
      p.pwrBattF = addFlow(p.pwrBatt, 1);
      const spin = (t) => {
        const dt = Math.min(0.1, (t - last) / 1000);
        last = t;
        const f = current();
        fans.forEach((fan, i) => {
          const rpm = f?.board?.fans?.[i]?.rpm || 0;
          fanAngle[i] = (fanAngle[i] + rpm / 60 * 360 * dt * 0.02) % 360;  // slowed 50x so it reads as motion
          fan.blades.setAttribute('transform', `rotate(${fanAngle[i].toFixed(1)})`);
        });
        raf = requestAnimationFrame(spin);
      };
      raf = requestAnimationFrame(spin);
    },
    unmount() { if (raf) cancelAnimationFrame(raf); },
    update(f) {
      const T = S.topo;
      const b = f.board || {};
      const socW = f.cpu_w + f.gpu.w + f.ane.w;
      p.soc.r.setAttribute('fill', heat(socW / 40));
      p.soc.val.textContent = `${fmtW(socW)} CPU+GPU+ANE`;
      p.soc.val2.textContent = `CPU ${fmtPct(avgBusy(f))} · GPU ${fmtPct(f.gpu.util ?? f.gpu.busy)}`;
      p.socTemp.textContent = b.hid?.soc ? `die sensors ${b.hid.soc.max} °C` : '';
      const dram = f.mem.dram_rd + f.mem.dram_wr;
      for (const r of p.ram) { r.r.setAttribute('fill', heat(dram / ((T.spec && T.spec.mem_peak_bw) || 200e9))); r.val.textContent = fmtBps(dram / 2); r.val2.textContent = 'share'; }
      setPair(pairs.ram, f.mem.dram_rd, f.mem.dram_wr);
      const d = b.disk || {};
      for (const n of p.nand) { n.r.setAttribute('fill', heat(lin((d.rd_bps || 0) + (d.wr_bps || 0), 7e9))); n.val.textContent = `R ${fmtBps(d.rd_bps)}`; n.val2.textContent = `W ${fmtBps(d.wr_bps)}`; }
      setPair(pairs.nand, d.rd_bps || 0, d.wr_bps || 0, 5e9);
      const n = b.net?.en0 || [0, 0];
      p.wifi.r.setAttribute('fill', heat(lin(n[0] + n[1], 150e6)));
      p.wifi.val.textContent = '↓ ' + fmtBps(n[0]);
      p.wifi.val2.textContent = '↑ ' + fmtBps(n[1]);
      setPair(pairs.wifi, n[0], n[1], 150e6);
      p.pmu.r.setAttribute('fill', heat(b.hid?.soc ? (b.hid.soc.max - 35) / 70 : 0));
      p.pmu.val.textContent = b.hid?.soc ? b.hid.soc.max + ' °C' : '';
      const disp = agentBw(f, 'DISP');
      p.display.r.setAttribute('fill', heat(lin(disp, 10e9)));
      setPair(pairs.disp, disp, 0, 10e9);
      p.camera.setAttribute('fill', heat(lin(agentBw(f, 'ISP'), 5e9)));
      (b.fans || []).forEach((x, i) => {
        if (!fans[i]) return;
        fans[i].ring.setAttribute('fill', heat(x.max ? (x.rpm - x.min) / (x.max - x.min) : 0));
        fans[i].txt.textContent = `Fan ${i + 1} · ${x.rpm} rpm`;
      });
      const bt = b.battery || {};
      p.batt.val.textContent = `${bt.percent ?? '—'}% · ${bt.charging ? 'charging' : bt.plugged ? 'plugged in' : 'on battery'}`;
      p.batt.val2.textContent = bt.batt_w !== undefined && bt.batt_w !== null ? `${bt.batt_w >= 0 ? 'into' : 'out of'} battery ${fmtW(Math.abs(bt.batt_w))} · system ${fmtW(bt.sys_load_w)}` : '';
      p.batt.r.setAttribute('fill', '#1d1d1c');  // not a processing load: no heat colour
      for (const c of p.battCells) c.setAttribute('width', Math.max(0, 221 * (bt.percent || 0) / 100));
      paintPorts(p.portSlots, b.ports || []);
      setFlow(p.pwrIn, (bt.sys_in_w || 0) * 1e9, 100e9);
      // battery flow: down into the battery when charging, up out of it when discharging
      p.pwrBattF.dir = (bt.batt_w || 0) >= 0 ? 1 : -1;
      setFlow(p.pwrBattF, Math.abs(bt.batt_w || 0) * 1e9, 100e9);
    },
    side(f, el) { macSide(f, el); },
  };
}

function avgBusy(f) {
  const v = Object.values(f.cores).map((c) => c.busy);
  return v.length ? v.reduce((a, b) => a + b, 0) / v.length : 0;
}

// Which live port (IOKit "Port-<type>@<n>") sits in which drawn socket. MagSafe, HDMI and SD are
// unambiguous. The USB-C numbers are mapped per model once confirmed by plugging something in.
const SOCKET_OF = {
  MacBookPro18_3: { 'MagSafe 3': 'MagSafe 3@1', HDMI: 'HDMI@1', 'SDXC card': 'SD Card@1', TB: [null, null, null] },
};

function portBlock(g, x, y, name, side) {
  const r = svg('rect', { x, y, width: 28, height: 40, rx: 5, class: 'blk', fill: '#202124' }, g);
  const t = svg('text', { x: side === 'left' ? x + 36 : x - 8, y: y + 24, class: 'tiny', 'text-anchor': side === 'left' ? 'start' : 'end' }, g, name);
  const slot = { r, t, name, side, live: null };
  bindTip(r, () => portTip(slot));
  return slot;
}

function portLine(pt) {
  if (!pt || !pt.connected) return 'nothing connected';
  const who = pt.power === 'into Mac' ? `${pt.device ? pt.device.vendor + ' ' : ''}charger${pt.charger?.rated_w ? ' (' + pt.charger.rated_w + ' W)' : ''}` : pt.device ? `${pt.device.vendor} device` : 'something';
  const data = pt.usb_data ? (pt.superspeed ? 'USB data (SuperSpeed)' : 'USB data') : 'charge only, no data';
  const c = pt.charger?.chosen;
  const pwr = pt.power === 'into Mac' ? `charging the Mac${c ? ` at up to ${c.volts} V × ${c.amps} A` : ''}` : pt.power === 'out to device' ? 'Mac is powering it' : '';
  return [who, data, pwr].filter(Boolean).join(' · ');
}

function portTip(slot) {
  const pt = slot.live;
  const f = current();
  const atc = f ? ['ATC0', 'ATC1', 'ATC2', 'ATC3'].reduce((s, a) => s + agentBw(f, a), 0) : 0;
  if (!pt) {
    const isTB = slot.name.startsWith('Thunderbolt');
    return { label: slot.name, value: isTB ? 'USB-C port (number not mapped yet)' : 'no live state',
      rows: isTB ? [['All USB-C memory traffic', fmtBps(atc)]] : [],
      explain: isTB ? 'macOS numbers the USB-C ports 1–3; which physical socket each number is gets confirmed by plugging something in. Live state for every port is in the side panel.' : EXPLAIN.port,
      src: isTB ? 'IOKit AppleHPM port controllers' : 'Apple spec' };
  }
  const rows = [['Port', pt.id], ['Status', pt.connected ? 'connected' : 'empty']];
  if (pt.connected) {
    rows.push(['Device', pt.device ? `${pt.device.vendor} (product ${pt.device.pid})` : '—'], ['Cable', pt.cable ? `${pt.cable.vendor || ''} ${pt.cable.kind}` : '—'],
      ['Data', pt.usb_data ? 'USB' : 'none (charge only)'], ['Power', pt.power || '—'], ['Plug', pt.orientation === 2 ? 'flipped' : pt.orientation === 1 ? 'normal' : '—']);
    if (pt.charger?.chosen) rows.push(['Charger contract', `${pt.charger.chosen.volts} V × ${pt.charger.chosen.amps} A = ${pt.charger.chosen.watts} W`]);
    if (pt.charger?.menu?.length) rows.push(['Charger offers', pt.charger.menu.map((m) => `${m.volts} V`).join(' / ')]);
  }
  rows.push(['Plugged in since boot', pt.connections]);
  return { value: portLine(pt), label: slot.name, rows, src: 'IOKit AppleHPM port controller + USB-PD (CC) identity' };
}

function paintPorts(slots, live) {
  const model = (S.topo.model || '').replace(',', '_');
  const map = SOCKET_OF[model] || {};
  let tb = 0;
  for (const slot of slots) {
    let id = map[slot.name] || null;
    if (slot.name.startsWith('Thunderbolt')) id = (map.TB || [])[tb++] || null;
    slot.live = id ? live.find((x) => x.id === id) || null : null;
    const on = slot.live && slot.live.connected;
    slot.r.setAttribute('fill', on ? (slot.live.power === 'out to device' ? '#7a5a00' : slot.live.power === 'into Mac' ? '#0a5a0a' : '#1c3b66') : '#202124');
    slot.t.textContent = slot.name + (on ? ' · ' + (slot.live.device ? slot.live.device.vendor : 'connected') : '');
  }
}

export function portsSide(f, el) {
  const live = f.board?.ports || [];
  if (!live.length) return;
  h('h3', {}, el, 'Ports (live)');
  const t = h('table', { class: 't' }, el);
  const tb = h('tbody', {}, t);
  for (const pt of live) {
    const tr = h('tr', {}, tb);
    h('td', { style: 'white-space:nowrap' }, tr, pt.type === 'USB-C' ? `USB-C ${pt.number}` : pt.type);
    h('td', { style: pt.connected ? 'color:#f0efec' : 'color:#898781' }, tr, portLine(pt));
  }
  h('div', { class: 'src' }, el, 'Port state from the AppleHPM port controllers; device/cable identity from USB Power Delivery; charger contract from the battery controller.');
}

function macSide(f, el) {
  const T = S.topo;
  const b = f.board || {};
  h('h2', {}, el, T.board?.name || T.model);
  h('div', { class: 'sub' }, el, `${T.chip} · ${fmtBytes(T.memory_bytes)} unified memory · ${T.ssd?.model || ''}`);
  h('h3', {}, el, 'Power');
  const bt = b.battery || {};
  kv(el, [['Adapter in', fmtW(bt.sys_in_w)], ['System load', fmtW(bt.sys_load_w)], ['Battery', bt.batt_w !== undefined ? `${bt.batt_w >= 0 ? '+' : ''}${fmtW(bt.batt_w)}` : '—'],
    ['Charge', bt.percent !== undefined ? `${bt.percent}%` : '—'], ['Adapter rating', bt.adapter_w ? bt.adapter_w + ' W' : '—']]);
  h('h3', {}, el, 'Cooling & temperature');
  kv(el, [...(b.fans || []).map((x, i) => [`Fan ${i + 1}`, `${x.rpm} rpm`]),
    ['SoC die sensors (max)', b.hid?.soc ? b.hid.soc.max + ' °C' : '—'], ['NAND', b.hid?.ssd ? b.hid.ssd.max + ' °C' : '—'],
    ['Battery', b.hid?.battery ? b.hid.battery.max + ' °C' : '—']]);
  h('h3', {}, el, 'Memory');
  const m = b.mem || {};
  kv(el, [['Used by apps', fmtBytes(m.app)], ['Wired (kernel)', fmtBytes(m.wired)], ['Compressed', fmtBytes(m.compressed)], ['Swap used', fmtBytes(m.swap_used)],
    ['Pressure', ({ 1: 'normal', 2: 'warning', 4: 'critical' })[m.pressure_level] || '—']]);
  portsSide(f, el);
  if (T.wifi?.card) {
    h('h3', {}, el, 'Radios');
    kv(el, [['Wi-Fi chip', T.wifi.card], ['Link', T.wifi.phy ? `${T.wifi.phy} · ch ${T.wifi.channel}` : '—']]);
  }
  procsSide(f, el);
}
