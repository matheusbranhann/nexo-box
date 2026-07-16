'use strict';
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const api = async (path, opts = {}) => {
  // POST always with a body + Content-Length (HttpListener requires it; otherwise HTTP 411)
  if (opts.method === 'POST' && opts.body == null) {
    opts.headers = Object.assign({ 'Content-Type': 'application/json' }, opts.headers);
    opts.body = '{}';
  }
  const r = await fetch(path, opts);
  let data = null; try { data = await r.json(); } catch {}
  if (!r.ok || (data && data.error)) throw new Error((data && data.error) || ('HTTP ' + r.status));
  return data;
};
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

// ---------- routing ----------
const pages = $$('[data-page]');
function route(name) {
  const r = ['dashboard', 'transfer', 'docs'].includes(name) ? name : 'dashboard';
  pages.forEach(p => p.hidden = p.dataset.page !== r);
  $$('[data-route]').forEach(a => a.classList.toggle('active', a.dataset.route === r));
  location.hash = r;
  if (r === 'transfer') fillTransferSelects();
  window.scrollTo(0, 0);
}
$$('[data-route]').forEach(a => a.addEventListener('click', e => { e.preventDefault(); route(a.dataset.route); }));
window.addEventListener('hashchange', () => route(location.hash.slice(1)));

// ---------- toast + activity ----------
const toastRoot = $('#toast-root');
function toast(msg, sub, err) {
  const el = document.createElement('div');
  el.className = 'toast' + (err ? ' err' : '');
  el.innerHTML = `${esc(msg)}${sub ? `<small>${esc(sub)}</small>` : ''}`;
  toastRoot.appendChild(el);
  setTimeout(() => { el.style.opacity = '0'; el.style.transition = '.4s'; setTimeout(() => el.remove(), 400); }, 3600);
}
const activity = [];
function logEvent(text, detail, color) {
  activity.unshift({ text, detail, color: color || '', t: new Date() });
  if (activity.length > 6) activity.pop();
  renderActivity();
}
function since(d) {
  const s = Math.floor((Date.now() - d) / 1000);
  if (s < 60) return 'NOW'; if (s < 3600) return Math.floor(s / 60) + ' MIN'; return Math.floor(s / 3600) + ' H';
}
function renderActivity() {
  const ol = $('#activity-list');
  if (!activity.length) return;
  ol.innerHTML = activity.map(e =>
    `<li><i class="event-dot ${e.color}"></i><span><strong>${esc(e.text)}</strong><small>${esc(e.detail || '')}</small></span><time>${since(e.t)}</time></li>`
  ).join('');
}

// ---------- state ----------
let instances = [];
let overview = {};

function parseGB(s) {
  if (!s || s === '—') return 0;
  const m = String(s).match(/([\d.]+)\s*(G|M|T)/i);
  if (!m) return 0;
  let v = parseFloat(m[1]);
  const u = m[2].toUpperCase();
  if (u === 'M') v /= 1024; if (u === 'T') v *= 1024;
  return v;
}

// ---------- render metrics ----------
function renderOverview() {
  const o = overview;
  $('#tel-host').textContent = 'HOST · ' + (o.hostThreads || '—') + ' THREADS · ' + (o.hostRamGB || '—') + ' GB';
  $('#tel-dot').className = 'live-dot' + (o.dockerUp ? '' : ' off');
  $('#tel-status').textContent = o.dockerUp ? 'DOCKER OPERATIONAL' : 'DOCKER OFFLINE';
  $('#meta-base').textContent = o.baseReady ? 'READY' : 'MISSING';
  $('#meta-base-sub').textContent = 'DISK · ' + (o.baseDiskGB || 0) + ' GB';
  $('#m-docker').textContent = o.dockerUp ? 'Operational' : 'Offline';
  $('#m-docker-dot').className = 'live-dot' + (o.dockerUp ? '' : ' off');
  $('#m-docker-sub').textContent = o.dockerUp ? 'daemon responding' : 'start Docker Desktop';
  $('#m-total').innerHTML = (o.total || 0) + ' <small>/ ' + (o.running || 0) + ' active</small>';
  $('#m-run-trend').textContent = (o.provisioning ? '+' + o.provisioning + ' creating' : (o.running || 0) + ' up');
  $('#m-disk').innerHTML = (o.diskSumGB || 0) + ' <small>GB</small>';
  const pct = Math.min(100, Math.round((o.diskSumGB || 0) / ((o.hostRamGB || 1) * 8) * 100));
  $('#m-disk-bar').style.width = pct + '%';
  $('#m-ram').innerHTML = (o.hostRamFreeGB || '—') + ' <small>GB free</small>';
  $('#m-cpu-sub').textContent = (o.hostCpu || '—');
}

function iconClass(inst, i) {
  return i % 2 ? 'violet' : '';
}

function renderInstances() {
  const q = ($('#inst-search').value || '').toLowerCase();
  const tbody = $('#inst-list');
  const list = instances.filter(i => JSON.stringify(i).toLowerCase().includes(q));
  if (!instances.length) {
    tbody.innerHTML = `<tr class="empty-row"><td colspan="7">No instances yet.<br>Click “New instance” to clone the base.</td></tr>`;
  } else if (!list.length) {
    tbody.innerHTML = `<tr class="empty-row"><td colspan="7">Nothing found for “${esc(q)}”.</td></tr>`;
  } else {
    tbody.innerHTML = list.map((i, idx) => {
      const ramPct = Math.min(100, Math.round(parseGB(i.memLive) / (parseGB(i.ram) || 1) * 100));
      const running = i.status === 'running';
      const prov = i.status === 'provisioning';
      const acts = [];
      if (running) acts.push(`<button class="row-action" title="Open screen" data-open="${i.web}"><svg><use href="#i-external"/></svg></button>`);
      if (running) acts.push(`<button class="row-action" title="Copy AI access (MCP)" data-mcp="${i.name}"><svg><use href="#i-key"/></svg></button>`);
      if (!prov && !running) acts.push(`<button class="row-action" title="Start" data-act="start" data-name="${i.name}"><svg><use href="#i-play"/></svg></button>`);
      if (running) acts.push(`<button class="row-action" title="Stop" data-act="stop" data-name="${i.name}"><svg><use href="#i-power"/></svg></button>`);
      if (running) acts.push(`<button class="row-action" title="Restart" data-act="restart" data-name="${i.name}"><svg><use href="#i-refresh"/></svg></button>`);
      if (!prov) acts.push(`<button class="row-action danger" title="Delete" data-del="${i.name}"><svg><use href="#i-trash"/></svg></button>`);
      if (prov) acts.push(`<button class="row-action" disabled><svg><use href="#i-refresh"/></svg></button>`);
      const statusLabel = { running: 'Running', stopped: 'Stopped', provisioning: 'Creating', error: 'Error' }[i.status] || i.status;
      return `<tr>
        <td><div class="cell-name"><span class="device-icon ${iconClass(i, idx)}"><svg><use href="#i-monitor"/></svg></span>
          <span><strong>${esc(i.label || i.name)}</strong><small>${esc(i.os || 'Windows')} · clone of ${esc(i.source)}</small></span></div></td>
        <td><code>web ${i.web}</code><br><small style="color:var(--faint)">mcp ${i.mcp} · rdp ${i.rdp}</small></td>
        <td>${esc(i.cpuLive)}<br><small style="color:var(--faint)">${esc(i.cpu)} vCPU</small></td>
        <td>${esc(i.memLive)}<div class="meter"><span style="width:${ramPct}%"></span></div></td>
        <td>${i.diskGB} GB</td>
        <td><span class="status ${i.status}">${esc(statusLabel)}</span></td>
        <td><div class="row-actions">${acts.join('')}</div></td>
      </tr>`;
    }).join('');
  }
  $('#inst-count').textContent = list.length + ' of ' + instances.length + ' instance' + (instances.length === 1 ? '' : 's');
  bindRowActions();
}

function bindRowActions() {
  $$('[data-open]').forEach(b => b.onclick = () => window.open('http://localhost:' + b.dataset.open, '_blank'));
  $$('[data-mcp]').forEach(b => b.onclick = () => {
    const i = instances.find(x => x.name === b.dataset.mcp);
    const txt = `http://localhost:${i.mcp}/mcp  (Bearer ${i.mcpKey})`;
    navigator.clipboard.writeText(txt).then(() => toast('AI access copied', i.name)).catch(() => {});
  });
  $$('[data-act]').forEach(b => b.onclick = () => doAction(b.dataset.name, b.dataset.act));
  $$('[data-del]').forEach(b => b.onclick = () => confirmDelete(b.dataset.del));
}

// ---------- actions ----------
async function doAction(name, act) {
  const gerund = { start: 'Starting', stop: 'Stopping', restart: 'Restarting' };
  const past = { start: 'Started', stop: 'Stopped', restart: 'Restarted' };
  toast(gerund[act] + '…', name);
  try {
    await api(`/api/instances/${name}/${act}`, { method: 'POST' });
    logEvent(past[act] + ' ' + name, act, act === 'stop' ? '' : 'cyan');
    await refresh();
  } catch (e) { toast('Failed to ' + act, e.message, true); }
}

function confirmDelete(name) {
  openModal(`Delete instance`, `
    <p>This <strong>stops and removes</strong> the instance <code>${esc(name)}</code> and all of its disk. The base is not affected. This cannot be undone.</p>
    <div class="modal-foot">
      <button class="button ghost" data-close>Cancel</button>
      <button class="button" style="border-color:var(--red);color:var(--red)" id="do-del">Delete permanently</button>
    </div>`);
  $('#do-del').onclick = async () => {
    closeModal();
    toast('Deleting…', name);
    try { await api(`/api/instances/${name}/delete`, { method: 'POST' }); logEvent('Instance deleted', name, 'violet'); await refresh(); }
    catch (e) { toast('Failed to delete', e.message, true); }
  };
}

// ---------- create ----------
$('#create-form').addEventListener('submit', async e => {
  e.preventDefault();
  const body = {
    name: $('#c-name').value.trim(),
    source: $('#c-source').value,
    ram: $('#c-ram').value,
    cpu: $('#c-cpu').value,
    cpus: String(Math.max(2, parseInt($('#c-cpu').value, 10))) + '.0',
  };
  const st = $('#create-status');
  st.textContent = 'CLONING THE DISK · THIS TAKES A FEW MINUTES';
  try {
    await api('/api/instances', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    st.textContent = 'INSTANCE “' + body.name.toUpperCase() + '” PROVISIONING';
    logEvent('New instance', body.name + ' · cloning disk', 'cyan');
    toast('Creating instance', body.name);
    $('#create-form').reset();
    await refresh();
  } catch (err) { st.textContent = ''; toast('Could not create', err.message, true); }
});

$('#c-name').addEventListener('input', e => { e.target.value = e.target.value.toLowerCase().replace(/[^a-z0-9\-]/g, ''); });

// ---------- transfer ----------
function fillTransferSelects() {
  const opts = instances.map(i => `<option value="${i.name}">${esc(i.name)}</option>`).join('');
  const base = `<option value="base">base (template)</option>`;
  $('#t-from').innerHTML = base + opts;
  $('#t-to').innerHTML = base + opts;
  if (instances[0]) $('#t-to').value = instances[0].name;
}
$('#btn-transfer').addEventListener('click', async () => {
  const from = $('#t-from').value, to = $('#t-to').value;
  const st = $('#transfer-status');
  if (from === to) { st.textContent = 'SOURCE AND DESTINATION ARE THE SAME'; return; }
  st.textContent = 'TRANSFERRING…';
  try {
    const r = await api('/api/transfer', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ from, to }) });
    st.textContent = r.copied + ' FILE(S) COPIED · ' + from.toUpperCase() + ' → ' + to.toUpperCase();
    logEvent('Transfer', from + ' → ' + to + ' (' + r.copied + ')', 'violet');
    toast('Data transferred', r.copied + ' file(s)');
  } catch (e) { st.textContent = ''; toast('Transfer failed', e.message, true); }
});

// ---------- modal ----------
function openModal(title, html) {
  $('#modal-root').innerHTML = `<div class="overlay" id="ov"><div class="modal"><div class="modal-head"><h3>${esc(title)}</h3><button data-close>✕</button></div><div class="modal-body">${html}</div></div></div>`;
  $$('[data-close]').forEach(b => b.onclick = closeModal);
  $('#ov').onclick = e => { if (e.target.id === 'ov') closeModal(); };
}
function closeModal() { $('#modal-root').innerHTML = ''; }
$('#btn-new').addEventListener('click', () => { route('dashboard'); $('#c-name').focus(); });

// ---------- refresh loop ----------
async function refresh() {
  try {
    [overview, instances] = await Promise.all([api('/api/overview'), api('/api/instances')]);
    renderOverview();
    renderInstances();
    $('#c-source').innerHTML = `<option value="base">Base (template)</option>` + instances.map(i => `<option value="${i.name}">${esc(i.name)}</option>`).join('');
  } catch (e) {
    $('#tel-status').textContent = 'NO CONNECTION TO THE SERVER';
    $('#tel-dot').className = 'live-dot off';
  }
}
$('#inst-search').addEventListener('input', renderInstances);
$('#btn-refresh').onclick = () => { toast('Refreshing'); refresh(); };
$('#btn-refresh2').onclick = () => refresh();

route(location.hash.slice(1) || 'dashboard');
refresh();
setInterval(refresh, 4000);
