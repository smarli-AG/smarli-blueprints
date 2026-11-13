// Step times of the longest stored run, finished runs first: where a run spends its time.
// Usage: RIG_TOKEN=<token> node trace-steps.mjs <prefix> [maxItems]   e.g. "script.smarli_cover_resolve"
// A step's time is the gap to the next step's timestamp, so it includes the step's own templates
// and anything HA ran in between (a run does not yield inside a step, see the step 2 plan).
const prefix = process.argv[2] || '';
const maxItems = Number(process.argv[3] || 1);
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
  const runs = [];
  for (const domain of ['automation', 'script']) {
    const l = await send({ type: 'trace/list', domain });
    for (const t of l.result || []) {
      if (!`${domain}.${t.item_id}`.startsWith(prefix) || !t.timestamp.finish) continue;
      runs.push({ domain, t, ms: new Date(t.timestamp.finish) - new Date(t.timestamp.start) });
    }
  }
  // Finished runs first: a run that ended early (a skip) spends its time waiting in the queue.
  const done = (r) => (r.t.script_execution === 'finished' ? 1 : 0);
  runs.sort((a, b) => done(b) - done(a) || b.ms - a.ms);
  for (const { domain, t, ms } of runs.slice(0, maxItems)) {
    const g = (await send({ type: 'trace/get', domain, item_id: t.item_id, run_id: t.run_id })).result;
    const steps = [];
    for (const [path, entries] of Object.entries(g.trace || {})) {
      for (const e of entries) steps.push({ path, at: new Date(e.timestamp) });
    }
    steps.sort((a, b) => a.at - b.at);
    console.log(`${domain}.${t.item_id} [${t.script_execution}] ${ms} ms, trigger: ${t.trigger || '-'}`);
    const end = new Date(t.timestamp.finish);
    steps.forEach((s, i) => {
      const next = i + 1 < steps.length ? steps[i + 1].at : end;
      console.log(`  ${String(next - s.at).padStart(5)} ms  ${s.path}`);
    });
  }
}
