// Run times from the stored traces (HA keeps 5 per automation or script), grouped by item and outcome.
// Usage: RIG_TOKEN=<token> node trace-durations.mjs <prefix>   e.g. "automation.load_" or "script.smarli_cover_resolve"
const prefix = process.argv[2] || '';
const ws = new WebSocket('ws://localhost:8123/api/websocket');
let id = 1; const pend = {};
const send = (o) => new Promise(r => { const i = id++; pend[i] = r; ws.send(JSON.stringify({ id: i, ...o })); });
ws.onmessage = async (m) => {
  const d = JSON.parse(m.data);
  if (d.type === 'auth_required') { ws.send(JSON.stringify({ type: 'auth', access_token: process.env.RIG_TOKEN })); return; }
  if (d.type === 'auth_ok') { await run(); ws.close(); return; }
  if (d.id && pend[d.id]) { pend[d.id](d); delete pend[d.id]; }
};
async function run() {
  const all = {};
  let first = null, last = null;
  for (const domain of ['automation', 'script']) {
    const l = await send({ type: 'trace/list', domain });
    for (const t of l.result || []) {
      const name = `${domain}.${t.item_id}`;
      if (!name.startsWith(prefix) || !t.timestamp.finish) continue;
      const s = new Date(t.timestamp.start), f = new Date(t.timestamp.finish);
      (all[t.script_execution] = all[t.script_execution] || []).push(f - s);
      if (!first || s < first) first = s;
      if (!last || f > last) last = f;
    }
  }
  for (const [k, v] of Object.entries(all)) {
    v.sort((a, b) => a - b);
    console.log(`${prefix}* [${k}] n=${v.length} min=${v[0]}ms median=${v[Math.floor(v.length / 2)]}ms max=${v[v.length - 1]}ms`);
  }
  if (first) console.log(`${prefix}* stored traces span ${((last - first) / 1000).toFixed(1)} s (first start to last finish)`);
}
