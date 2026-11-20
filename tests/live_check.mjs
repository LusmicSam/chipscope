// Live UI check: open each view in headless Chrome over the DevTools protocol (no snapshot
// mode, real EventSource), read the page twice 3 s apart, and fail on JS errors or a frozen page.
//   node tests/live_check.mjs [http://127.0.0.1:7878]
import { spawn } from 'node:child_process';
import { setTimeout as sleep } from 'node:timers/promises';

const BASE = process.argv[2] || 'http://127.0.0.1:7878';
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = 9333;
const VIEWS = ['mac', 'soc', 'cluster/pclu0', 'core/pclu1.2', 'gpu', 'memory', 'atlas', 'sensors'];

const chrome = spawn(CHROME, ['--headless=new', '--disable-gpu', `--remote-debugging-port=${PORT}`,
  '--user-data-dir=/tmp/chipscope-chrome-live', '--window-size=1680,1050', 'about:blank'], { stdio: 'ignore' });
let ws;
try {
  let target;
  for (let i = 0; i < 50 && !target; i++) {
    await sleep(200);
    try { target = (await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json()).find((t) => t.type === 'page'); } catch { /* not up yet */ }
  }
  ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener('open', r));
  let id = 0;
  const pending = new Map();
  const errors = [];
  ws.addEventListener('message', (m) => {
    const d = JSON.parse(m.data);
    if (d.id && pending.has(d.id)) { pending.get(d.id)(d.result); pending.delete(d.id); }
    if (d.method === 'Runtime.exceptionThrown') errors.push(d.params.exceptionDetails.exception?.description || d.params.exceptionDetails.text);
    if (d.method === 'Runtime.consoleAPICalled' && d.params.type === 'error') errors.push(d.params.args.map((a) => a.value).join(' '));
  });
  const send = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  const evaluate = async (expr) => (await send('Runtime.evaluate', { expression: expr, returnByValue: true })).result.value;
  await send('Runtime.enable');
  let failed = false;
  for (const v of VIEWS) {
    errors.length = 0;
    await send('Page.navigate', { url: `${BASE}/#/${v}` });
    await sleep(2500);
    const probe = `JSON.stringify({conn: document.getElementById('conn').textContent,
      err: document.getElementById('err').style.display === 'block' ? document.getElementById('err').textContent : '',
      text: document.getElementById('side').innerText.slice(0, 4000) + document.getElementById('stage').textContent.slice(0, 4000)})`;
    const a = JSON.parse(await evaluate(probe));
    await sleep(3000);
    const b = JSON.parse(await evaluate(probe));
    const live = b.conn.startsWith('live');
    const changed = a.text !== b.text;
    const jsErr = b.err || errors.join(' | ');
    const ok = live && !jsErr && (changed || v === 'sensors' || v === 'atlas');
    failed ||= !ok;
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${v.padEnd(14)} conn="${b.conn}" updates=${changed} ${jsErr ? 'ERR: ' + jsErr.slice(0, 300) : ''}`);
  }
  process.exitCode = failed ? 1 : 0;
} finally {
  try { ws?.close(); } catch { /* ignore */ }
  chrome.kill();
}
