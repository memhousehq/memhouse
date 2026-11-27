// SPDX-License-Identifier: Apache-2.0
// The MemHouse admin console. One page that calls the REST API as the principal that logged in.
//
// Rules this file keeps (threat model T3; the server's tests check them):
// - It decides nothing. Every action is an API call; the server authorizes it and may refuse.
//   A control shown here is a convenience, never a permission.
// - The API key is sent once, to open the session, and is not kept: no variable outlives the
//   login call, and nothing is written to the browser's storage. The session is a cookie that
//   script cannot read. The CSRF token is held in memory only and asked for again on reload.
// - Data is put on the page as text nodes and attributes through the DOM, never as markup.
'use strict';

// `epoch` counts sessions: it moves at every login and logout, and an answer that belongs to
// an earlier one is dropped, so nothing of one principal's session reaches the next one's page.
// `listing` counts requests for the memory list, so a late answer for another subject or
// filter does not replace the list on screen.
const state = { csrf: '', session: null, subject: null, cursor: null, queueCursor: null, epoch: 0, listing: 0 };

// Thrown for an answer that arrived after its session ended; nothing is shown for it.
class Stale extends Error {}
const KINDS = ['semantic', 'preference', 'procedural', 'commitment', 'episodic', 'document', 'working', 'taxonomic'];

const $ = (id) => document.getElementById(id);

// Build an element: h('button', {class: 'small', type: 'button'}, 'text', child, ...).
function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === false || v === null || v === undefined) continue;
    if (k === 'class') el.className = v;
    else if (k === 'onclick') el.addEventListener('click', v);
    else el.setAttribute(k, v === true ? '' : String(v));
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

function fill(target, ...children) {
  const el = typeof target === 'string' ? $(target) : target;
  el.replaceChildren(...children.flat().filter((c) => c !== null && c !== undefined && c !== false).map((c) => (c instanceof Node ? c : document.createTextNode(String(c)))));
}

function notice(text, bad) {
  const n = $('notice');
  n.textContent = text || '';
  n.className = bad ? 'bad' : '';
}

class ApiError extends Error {
  constructor(status, body) {
    super((body && body.error) || `HTTP ${status}`);
    this.status = status;
    this.code = body && body.code;
  }
}

// Every call goes to this server with the session cookie; one that changes something carries
// the session's CSRF token. A 401 means the session ended: back to the login form.
async function api(method, path, body, extra) {
  const epoch = state.epoch;
  const headers = { ...(extra || {}) };
  if (body !== undefined) headers['content-type'] = 'application/json';
  if (method !== 'GET' && state.csrf) headers['x-memhouse-csrf'] = state.csrf;
  const resp = await fetch(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), credentials: 'same-origin', cache: 'no-store', redirect: 'error' });
  let data = null;
  try {
    data = await resp.json();
  } catch (_) {
    data = null;
  }
  if (epoch !== state.epoch) throw new Stale();
  if (resp.status === 401 && path !== '/v1/session') {
    showLogin('The session ended. Log in again.');
  }
  if (!resp.ok) throw new ApiError(resp.status, data);
  return data;
}

// Run an action, say what happened, and reload what it changed.
async function act(label, fn, after) {
  try {
    const r = await fn();
    notice(typeof label === 'function' ? label(r) : label);
    if (after) await after(r);
  } catch (e) {
    if (e instanceof Stale) return;
    notice(e.status === 403 ? `Refused by the server: ${e.message}` : e.message, true);
  }
}

function ask(title, text, value, okLabel) {
  return new Promise((resolve) => {
    const d = $('dialog');
    $('dialog-title').textContent = title;
    $('dialog-text').textContent = text || '';
    const input = $('dialog-input');
    input.hidden = value === null;
    input.value = value || '';
    $('dialog-ok').textContent = okLabel || 'OK';
    const done = (result) => {
      d.close();
      $('dialog-form').onsubmit = null;
      $('dialog-cancel').onclick = null;
      d.oncancel = null;
      resolve(result);
    };
    $('dialog-form').onsubmit = (ev) => {
      ev.preventDefault();
      done(value === null ? true : input.value.trim());
    };
    $('dialog-cancel').onclick = () => done(null);
    d.oncancel = () => done(null);
    d.showModal();
  });
}

const day = (t) => (t ? String(t).slice(0, 10) : '');
const stamp = (t) => (t ? String(t).slice(0, 19).replace('T', ' ') : '');
const list = (v) => v.split(',').map((x) => x.trim()).filter(Boolean);
const pct = (v) => (v === null || v === undefined ? '–' : (v * 100).toFixed(1));
const chip = (text, cls) => h('span', { class: `chip ${cls || ''}` }, text);

function table(head, rows) {
  if (!rows.length) return h('p', { class: 'muted' }, 'Nothing here.');
  return h('table', {}, h('thead', {}, h('tr', {}, head.map((c) => h('th', { class: c.startsWith('#') ? 'num' : '' }, c.replace(/^#/, ''))))), h('tbody', {}, rows.map((r) => h('tr', {}, r.map((c, i) => h('td', { class: head[i] && head[i].startsWith('#') ? 'num' : '' }, c))))));
}

// ---- session ----

// Everything a session put on the page, and everything the page remembers of it: memories,
// tables, an issued key, form values, the selected subject, cursors. Cleared at every login
// and logout, so the next principal starts with an empty page and sees only what the server
// answers to it.
const VIEWS = ['subjects', 'memories', 'explanation', 'queue', 'principals', 'keys', 'policy-specs', 'policy-history', 'eval-trend', 'eval-suites', 'eval-runs', 'advisor', 'stats', 'session', 'audit'];
const TEXTS = ['memories-summary', 'queue-summary', 'policy-running', 'policy-warning', 'policy-output', 'new-key-value', 'notice'];

function clearSessionData() {
  state.epoch += 1;
  state.listing += 1;
  state.csrf = '';
  state.session = null;
  state.subject = null;
  state.cursor = null;
  state.queueCursor = null;
  for (const id of VIEWS) fill(id);
  for (const id of TEXTS) $(id).textContent = '';
  $('new-key').hidden = true;
  $('memories-more').hidden = true;
  $('queue-more').hidden = true;
  for (const form of document.querySelectorAll('main form')) form.reset();
  if ($('dialog').open) $('dialog').close();
  $('dialog-input').value = '';
}

function showLogin(message) {
  clearSessionData();
  $('app').hidden = true;
  $('logout').hidden = true;
  $('login').hidden = false;
  $('who').textContent = '';
  $('login-error').textContent = message || '';
  $('login-key').focus();
}

function showApp(session) {
  clearSessionData();
  state.session = session;
  state.csrf = session.csrf_token;
  $('login').hidden = true;
  $('app').hidden = false;
  $('logout').hidden = false;
  $('who').textContent = `${session.principal} · tenant ${session.tenant} · session until ${stamp(session.expires_at)} UTC`;
  openTab('memories');
}

async function login(ev) {
  ev.preventDefault();
  const field = $('login-key');
  const key = field.value.trim();
  field.value = '';
  if (!key) return;
  try {
    const resp = await fetch('/v1/session', { method: 'POST', headers: { authorization: `Bearer ${key}` }, credentials: 'same-origin', cache: 'no-store', redirect: 'error' });
    const data = await resp.json().catch(() => null);
    if (!resp.ok) throw new ApiError(resp.status, data);
    showApp(data);
  } catch (e) {
    $('login-error').textContent = e.message;
  }
}

// Logged out only when the server says the session is over: it answered the request, or it
// no longer knows the session (401). Anything else (no connection, a server error) leaves the
// session alive on the server and in the cookie, so the page says so and stays, to try again.
async function logout() {
  try {
    await api('DELETE', '/v1/session');
  } catch (e) {
    if (e instanceof Stale) return;
    if (e.status !== 401) {
      notice(`Not logged out: ${e.message || 'the server did not answer'}. The session is still open; try again.`, true);
      return;
    }
  }
  showLogin('Logged out.');
}

async function start() {
  try {
    showApp(await api('GET', '/v1/session'));
  } catch (_) {
    showLogin('');
  }
}

// ---- tabs ----

const loaders = {
  memories: loadSubjects,
  review: () => loadQueue(true),
  principals: loadPrincipals,
  policies: loadPolicies,
  evaluation: loadEvaluation,
  status: loadStatus,
  audit: loadAudit,
};

function openTab(name) {
  for (const b of $('tabs').querySelectorAll('button')) b.classList.toggle('on', b.dataset.tab === name);
  for (const s of document.querySelectorAll('.tab')) s.hidden = s.id !== `tab-${name}`;
  notice('');
  act('', loaders[name]);
}

// ---- memories (PROF-09: view, search, edit, supersede, delete, explanation) ----

async function loadSubjects() {
  let subjects = [];
  try {
    subjects = await api('GET', '/v1/subjects');
  } catch (e) {
    // Listing subjects needs ops:read; a principal without it names a subject itself.
    if (e.status !== 403) throw e;
  }
  if (!state.subject && subjects.length) state.subject = subjects[0].subject;
  fill('subjects', subjects.length ? subjects.map((s) => h('button', { type: 'button', class: `subj ${s.subject === state.subject ? 'on' : ''}`, onclick: () => pickSubject(s.subject) }, h('span', {}, s.subject), h('span', { class: 'muted' }, s.memories))) : h('p', { class: 'muted' }, 'No subject listed. Name one above.'));
  if (state.subject) await loadMemories(true);
}

function pickSubject(subject) {
  state.subject = subject;
  $('search-q').value = '';
  fill('explanation');
  act('', loadSubjects);
}

function memoryCard(m, extra, actions) {
  return h(
    'div',
    { class: 'card' },
    h('div', { class: 'content' }, m.content),
    h(
      'div',
      { class: 'chips' },
      chip(m.status, `st-${m.status}`),
      chip(m.kind),
      chip(day(m.occurred_at || m.created_at)),
      chip(`source: ${m.source}`),
      (m.labels || []).map((l) => chip(`label: ${l}`)),
      (m.tags || []).map((t) => chip(`#${t}`)),
      m.stale_since ? chip('stale', 'warn-text') : null,
      m.metadata && m.metadata.quarantine_reasons ? chip(`held: ${m.metadata.quarantine_reasons.join(', ')}`, 'bad') : null,
      extra || null,
      h('span', { class: 'chip mono' }, m.id),
      actions || null,
    ),
  );
}

function memoryActions(m) {
  const live = m.status === 'committed';
  return [
    live ? h('button', { type: 'button', class: 'small', onclick: () => editMemory(m) }, 'Edit') : null,
    live ? h('button', { type: 'button', class: 'small', onclick: () => supersedeMemory(m) }, 'Supersede') : null,
    h('button', { type: 'button', class: 'small danger', onclick: () => deleteMemory(m) }, 'Delete'),
  ];
}

async function loadMemories(reset) {
  if (!state.subject) return;
  if (reset) state.cursor = null;
  const kind = $('search-kind').value;
  const params = new URLSearchParams({ limit: '50' });
  if (kind) params.set('kinds', kind);
  if ($('show-inactive').checked) params.set('include_inactive', 'true');
  if (state.cursor) params.set('cursor', state.cursor);
  const subject = state.subject;
  const request = ++state.listing;
  const page = await api('GET', `/v1/subjects/${encodeURIComponent(subject)}/memories?${params}`);
  // Another list was asked for meanwhile (another subject, filter or page): this answer is
  // not the one on screen and must not replace it or its cursor.
  if (request !== state.listing || subject !== state.subject) return;
  const cards = page.items.map((m) => memoryCard(m, null, memoryActions(m)));
  if (reset) fill('memories', cards);
  else $('memories').append(...cards);
  state.cursor = page.next_cursor || null;
  $('memories-more').hidden = !state.cursor;
  $('memories-summary').textContent = `Memories of ${state.subject}, newest first`;
}

async function search(ev) {
  ev.preventDefault();
  const query = $('search-q').value.trim();
  if (!state.subject) return notice('Open a subject first.', true);
  if (!query) return act('', () => loadMemories(true));
  const kind = $('search-kind').value;
  await act('', async () => {
    const subject = state.subject;
    const request = ++state.listing;
    const r = await api('POST', '/v1/recall', { subject, query, k: 20, kinds: kind ? [kind] : null });
    if (request !== state.listing || subject !== state.subject) return;
    state.cursor = null;
    $('memories-more').hidden = true;
    $('memories-summary').textContent = `${r.hits.length} results in ${r.took_ms.toFixed(1)} ms${r.reranked ? ' (reranked)' : ''}${r.degraded ? ` · degraded: ${r.degraded}` : ''}`;
    fill(
      'memories',
      r.recall_id ? h('div', { class: 'row' }, h('button', { type: 'button', onclick: () => explain(r.recall_id) }, 'Explain this recall'), h('span', { class: 'muted mono' }, r.recall_id)) : null,
      r.hits.map((x) => memoryCard(x.memory, chip(`score ${x.score.toFixed(3)}${x.keyword_rank ? ` · kw #${x.keyword_rank}` : ''}${x.vector_rank ? ` · vec #${x.vector_rank}` : ''}`), memoryActions(x.memory))),
    );
    fill('explanation');
  });
}

async function explain(id) {
  await act('', async () => {
    const e = await api('GET', `/v1/recalls/${encodeURIComponent(id)}/explanation`);
    const rec = e.recall;
    const hidden = Object.entries(e.hidden || {});
    fill(
      'explanation',
      h('h2', {}, 'Why this recall returned what it did'),
      h('p', { class: 'muted' }, `Query "${rec.query}" by ${rec.principal} at ${stamp(rec.at)} UTC, policy ${rec.policy_version}, authorizer ${rec.authorizer}, mode ${rec.mode}, k ${rec.k}.`),
      h('h3', {}, 'Returned'),
      table(['#Rank', 'Id', '#Score', '#Keyword rank', '#Vector rank', '#Similarity', '#Tokens'], rec.returned.map((x) => [x.rank, h('span', { class: 'mono' }, x.id), x.score.toFixed(4), x.keyword_rank ?? '–', x.vector_rank ?? '–', x.similarity === null || x.similarity === undefined ? '–' : x.similarity.toFixed(3), x.tokens])),
      h('h3', {}, 'Matched but left out'),
      table(['Id', 'Reason', 'Detail'], e.excluded.map((x) => [h('span', { class: 'mono' }, x.id), x.reason, x.detail])),
      hidden.length ? h('p', { class: 'muted' }, `Also left out, by reason (ids are shown to audit:read): ${hidden.map(([k, v]) => `${k} ${v}`).join(', ')}`) : null,
    );
  });
}

async function addMemory(ev) {
  ev.preventDefault();
  const content = $('add-content').value.trim();
  if (!content || !state.subject) return notice('Open a subject and write something first.', true);
  await act((r) => `Stored as ${r.status}${r.note ? `: ${r.note}` : ''}`, () => api('POST', '/v1/remember', { subject: state.subject, content, wait: true }), () => {
    $('add-content').value = '';
    return loadSubjects();
  });
}

async function editMemory(m) {
  const content = await ask('Edit this memory', 'The new text becomes a new version; the old one is kept as superseded.', m.content, 'Save');
  if (!content || content === m.content) return;
  await act((r) => `Revised: the new version is ${r.status}${r.note ? ` (${r.note})` : ''}`, () => api('POST', '/v1/revise', { id: m.id, content, wait: true }), () => loadMemories(true));
}

async function supersedeMemory(m) {
  const content = await ask('Supersede this memory', 'Write the memory that replaces it. The old one stays in history and is no longer recalled.', '', 'Supersede');
  if (!content) return;
  await act((r) => `Superseded by a memory that is ${r.status}${r.note ? ` (${r.note})` : ''}`, () => api('POST', '/v1/remember', { subject: m.subject, content, kind: m.kind, supersedes: m.id, wait: true }), () => loadMemories(true));
}

async function deleteMemory(m) {
  if (!(await ask('Delete this memory', 'It is deleted permanently, with what was derived from it. This cannot be undone.', null, 'Delete'))) return;
  await act((r) => `Deleted ${r.deleted} record${r.deleted === 1 ? '' : 's'}`, () => api('POST', '/v1/forget', { id: m.id }), () => loadSubjects());
}

// ---- review (GOV-11: approve, reject, rephrase and approve) ----

async function loadQueue(reset) {
  if (reset) state.queueCursor = null;
  const params = new URLSearchParams({ limit: '50' });
  if ($('queue-status').value) params.set('status', $('queue-status').value);
  if ($('queue-subject').value.trim()) params.set('subject', $('queue-subject').value.trim());
  if (state.queueCursor) params.set('cursor', state.queueCursor);
  const page = await api('GET', `/v1/review/queue?${params}`);
  const cards = page.items.map((m) =>
    memoryCard(m, chip(m.subject, 'mono'), [
      m.status === 'candidate' ? h('button', { type: 'button', class: 'small', onclick: () => review(m, 'commit') }, 'Approve') : null,
      h('button', { type: 'button', class: 'small', onclick: () => rephrase(m) }, 'Rephrase and approve'),
      h('button', { type: 'button', class: 'small danger', onclick: () => review(m, 'reject') }, 'Reject'),
    ]),
  );
  if (reset) fill('queue', cards);
  else $('queue').append(...cards);
  state.queueCursor = page.next_cursor || null;
  $('queue-more').hidden = !state.queueCursor;
  $('queue-summary').textContent = reset && !page.items.length ? 'Nothing waits for review.' : 'Waiting for review, newest first. A quarantined record is never approved as it stands: reject it, or approve another wording.';
}

async function review(m, action) {
  let reason;
  if (action === 'reject') {
    reason = await ask('Reject this record', 'Why (kept in the audit log):', '', 'Reject');
    if (reason === null) return;
  }
  await act((r) => `Now ${r.status}`, () => api('POST', '/v1/review', { id: m.id, action, reason: reason || undefined }), () => loadQueue(true));
}

async function rephrase(m) {
  const content = await ask('Rephrase and approve', 'The new wording is written as yours and passes the write gate like any write. The record under review is then rejected.', m.content, 'Approve this wording');
  if (!content) return;
  await act((r) => `Approved as ${r.id} (${r.status}); the reviewed record is rejected`, () => api('POST', '/v1/review', { id: m.id, action: 'commit', content }), () => loadQueue(true));
}

// ---- principals and keys ----

async function loadPrincipals() {
  const [principals, keys] = await Promise.all([api('GET', '/v1/principals'), api('GET', '/v1/keys')]);
  fill(
    'principals',
    table(
      ['Id', 'Kind', 'Subjects', 'Kinds', 'Denied labels', 'Grants', 'State', ''],
      principals.map((p) => [
        h('span', { class: 'mono' }, p.id),
        p.kind,
        p.subjects.join(', '),
        p.kinds.length ? p.kinds.join(', ') : 'all',
        p.denied_labels.join(', '),
        [p.can_commit ? 'commits' : null, p.act_as ? 'acts for users' : null].filter(Boolean).join(', '),
        p.disabled_at ? h('span', { class: 'bad' }, 'disabled') : h('span', { class: 'ok' }, 'active'),
        h('span', { class: 'row' }, h('button', { type: 'button', class: 'small', onclick: () => editPrincipal(p) }, 'Edit'), h('button', { type: 'button', class: `small ${p.disabled_at ? '' : 'danger'}`, onclick: () => setDisabled(p) }, p.disabled_at ? 'Enable' : 'Disable')),
      ]),
    ),
  );
  fill(
    'keys',
    table(
      ['Key id', 'Principal', 'Permissions', 'State', 'Created', ''],
      keys.map((k) => [
        h('span', { class: 'mono' }, k.id),
        h('span', { class: 'mono' }, k.principal),
        k.scopes.join(', '),
        h('span', { class: k.state === 'active' ? 'ok' : 'bad' }, k.state === 'active' && k.expires_at ? `active until ${stamp(k.expires_at)}` : k.state),
        `${day(k.created_at)} by ${k.created_by}`,
        k.state === 'active' ? h('span', { class: 'row' }, h('button', { type: 'button', class: 'small', onclick: () => rotateKey(k) }, 'Rotate'), h('button', { type: 'button', class: 'small danger', onclick: () => revokeKey(k) }, 'Revoke')) : '',
      ]),
    ),
  );
}

function editPrincipal(p) {
  $('p-id').value = p.id;
  $('p-name').value = p.name || '';
  $('p-subjects').value = p.subjects.join(', ');
  $('p-kinds').value = p.kinds.join(', ');
  $('p-labels').value = p.denied_labels.join(', ');
  $('p-org').value = p.org || '';
  $('p-team').value = p.team || '';
  $('p-commit').checked = p.can_commit;
  $('p-actas').checked = p.act_as;
  $('k-principal').value = p.id;
  $('p-id').focus();
}

async function savePrincipal(ev) {
  ev.preventDefault();
  const id = $('p-id').value.trim();
  const body = {
    name: $('p-name').value.trim() || null,
    subjects: list($('p-subjects').value),
    kinds: list($('p-kinds').value),
    denied_labels: list($('p-labels').value),
    org: $('p-org').value.trim() || null,
    team: $('p-team').value.trim() || null,
    can_commit: $('p-commit').checked,
    act_as: $('p-actas').checked,
  };
  await act(`Saved ${id}`, () => api('PUT', `/v1/principals/${encodeURIComponent(id)}`, body), loadPrincipals);
}

async function setDisabled(p) {
  const verb = p.disabled_at ? 'enable' : 'disable';
  if (!(await ask(`${p.disabled_at ? 'Enable' : 'Disable'} ${p.id}`, p.disabled_at ? 'Its keys work again.' : 'Its keys, tokens and sessions stop working.', null, p.disabled_at ? 'Enable' : 'Disable'))) return;
  await act(`${p.id}: ${verb}d`, () => api('POST', `/v1/principals/${encodeURIComponent(p.id)}/${verb}`), loadPrincipals);
}

function showKey(created) {
  $('new-key-value').textContent = created.key;
  $('new-key').hidden = false;
}

async function createKey(ev) {
  ev.preventDefault();
  const scopes = list($('k-scopes').value);
  const days = Number($('k-days').value);
  const body = { principal: $('k-principal').value.trim(), scopes: scopes.length ? scopes : null, expires_in_secs: days > 0 ? Math.round(days * 86400) : null };
  await act((r) => `Key ${r.info.id} created for ${r.info.principal}`, () => api('POST', '/v1/keys', body), (r) => {
    showKey(r);
    return loadPrincipals();
  });
}

async function rotateKey(k) {
  if (!(await ask(`Rotate key ${k.id}`, 'A new key with the same permissions is made; this one keeps working for a day.', null, 'Rotate'))) return;
  await act((r) => `Key ${r.info.id} replaces ${k.id}, which works until ${stamp(r.old_expires_at)} UTC`, () => api('POST', `/v1/keys/${encodeURIComponent(k.id)}/rotate`, {}), (r) => {
    showKey(r);
    return loadPrincipals();
  });
}

async function revokeKey(k) {
  if (!(await ask(`Revoke key ${k.id}`, 'It, its tokens and its sessions stop working now.', null, 'Revoke'))) return;
  await act(`Key ${k.id} revoked`, () => api('POST', `/v1/keys/${encodeURIComponent(k.id)}/revoke`), loadPrincipals);
}

// ---- policies ----

async function loadPolicies() {
  const p = await api('GET', '/v1/policies');
  $('policy-running').textContent = `Running: ${p.running.version}${p.active ? ` (spec version ${p.active})` : ' (the default policy)'}`;
  $('policy-warning').textContent = p.warning || '';
  fill(
    'policy-specs',
    table(
      ['#Version', 'Name', 'State', 'Proposed', 'Approved', 'Note', ''],
      p.specs.map((s) => [
        s.version,
        s.name,
        s.version === p.active ? h('span', { class: 'ok' }, `${s.status}, active`) : s.status,
        `${stamp(s.proposed_at)} by ${s.proposed_by}`,
        s.approved_by ? `${stamp(s.approved_at)} by ${s.approved_by}` : '',
        s.note || '',
        h(
          'span',
          { class: 'row' },
          h('button', { type: 'button', class: 'small', onclick: () => ($('policy-spec').value = JSON.stringify(s.spec, null, 2)) }, 'Copy to editor'),
          s.status === 'proposed' ? h('button', { type: 'button', class: 'small', onclick: () => approvePolicy(s.version) }, 'Approve') : null,
          s.status === 'approved' && s.version !== p.active ? h('button', { type: 'button', class: 'small', onclick: () => rollbackPolicy(String(s.version)) }, 'Activate') : null,
        ),
      ]),
    ),
  );
  fill('policy-history', table(['When', 'Action', 'Version', 'Compiled', 'By'], p.history.map((a) => [stamp(a.at), a.action, a.version ?? 'default', h('span', { class: 'mono' }, a.compiled), a.by])));
}

function policyBody() {
  const spec = JSON.parse($('policy-spec').value);
  const note = $('policy-note').value.trim();
  return note ? { spec, note } : { spec };
}

async function policyCall(path, body, done) {
  try {
    const r = await api('POST', path, body());
    $('policy-output').textContent = JSON.stringify(r, null, 2);
    if (done) await done(r);
  } catch (e) {
    if (e instanceof Stale) return;
    $('policy-output').textContent = e.status === 403 ? `Refused by the server: ${e.message}` : e.message;
  }
}

async function approvePolicy(version) {
  if (!(await ask(`Approve policy version ${version}`, 'It becomes the running policy. A tenant with evaluation suites has them replayed first; a version that degrades them is refused.', null, 'Approve'))) return;
  await act((r) => `Running ${r.version}`, () => api('POST', `/v1/policies/${version}/approve`), loadPolicies);
}

async function rollbackPolicy(to) {
  if (!(await ask(to ? `Activate policy version ${to}` : 'Roll back', to ? 'This approved version becomes the running policy.' : 'The policy that ran before the current one becomes the running policy.', null, 'Activate'))) return;
  await act((r) => `Running ${r.version}`, () => api('POST', '/v1/policies/rollback', to ? { to } : {}), loadPolicies);
}

// ---- evaluation (QUAL-11: metrics per tenant with their trend by policy version) ----

const METRICS = [
  ['storage_f1', 'Storage F1', 1],
  ['retrieval_f1', 'Retrieval F1', 1],
  ['stale_rate', 'Stale facts', -1],
  ['contamination_rate', 'Contamination', -1],
];

function metric(m, key) {
  const v = m[key];
  return v === undefined ? null : v;
}

function delta(now, before, better) {
  if (now === null || before === null) return '';
  const d = (now - before) * 100;
  if (Math.abs(d) < 0.05) return h('span', { class: 'muted' }, ' =');
  return h('span', { class: d * better > 0 ? 'ok' : 'bad' }, ` ${d > 0 ? '+' : ''}${d.toFixed(1)}`);
}

async function loadEvaluation() {
  const [trend, suites, runs] = await Promise.all([api('GET', '/v1/eval/trend'), api('GET', '/v1/eval/suites'), api('GET', '/v1/eval/runs?limit=50')]);
  fill(
    'eval-trend',
    trend.suites.length
      ? trend.suites.map((s) =>
          h(
            'div',
            { class: 'card' },
            h('h3', {}, s.suite),
            table(
              ['Policy version', '#Replays', 'Last replay', ...METRICS.map((m) => `#${m[1]}`)],
              s.points.map((p, i) => [
                h('span', { class: 'mono' }, p.policy_version),
                p.runs,
                stamp(p.last_at),
                ...METRICS.map(([key, , better]) => {
                  const now = metric(p.metrics, key);
                  const before = i > 0 ? metric(s.points[i - 1].metrics, key) : null;
                  return h('span', {}, pct(now), delta(now, before, better));
                }),
              ]),
            ),
          ),
        )
      : h('p', { class: 'muted' }, 'No replay is stored yet. Add a suite with `memhouse eval add <file>` and replay it with `memhouse eval run`.'),
  );
  fill('eval-suites', table(['Suite', '#Conversations', '#Turns', 'Hash', 'Added'], suites.map((s) => [s.name, s.conversations, s.turns, h('span', { class: 'mono' }, s.hash.slice(0, 12)), `${day(s.created_at)} by ${s.created_by}`])));
  fill(
    'eval-runs',
    table(
      ['When', 'Suite', 'Policy version', 'Trigger', ...METRICS.map((m) => `#${m[1]}`), 'Gate'],
      runs.map((r) => [stamp(r.created_at), r.suite, h('span', { class: 'mono' }, r.policy_version), r.trigger, ...METRICS.map(([key]) => pct(metric(r.metrics, key))), r.gate_passed === undefined || r.gate_passed === null ? '' : r.gate_passed ? h('span', { class: 'ok' }, 'passed') : h('span', { class: 'bad' }, 'failed')]),
    ),
  );
}

// ---- status and the profile advisor (PROF-11) ----

async function loadStatus() {
  const s = state.session;
  fill('session', table(['Principal', 'Kind', 'Tenant', 'Permissions', 'Ends', 'Idle limit'], [[s.principal, s.kind, s.tenant, s.scopes.join(', '), `${stamp(s.expires_at)} UTC`, s.idle_secs ? `${Math.round(s.idle_secs / 60)} min` : 'none']]));
  const a = await api('GET', '/v1/advisor');
  const cls = a.status === 'ok' ? 'ok' : a.status === 'near_limit' ? 'warn-text' : 'bad';
  fill(
    'advisor',
    h('p', {}, 'Profile: ', h('strong', {}, a.profile), ' · ', h('strong', { class: cls }, a.status.replace('_', ' ')), a.profile === 'lite' ? ` · warns from ${Math.round(a.warn_at * 100)}% of a limit` : ' · no limit is judged on this profile'),
    table(
      ['Measure', '#Value', '#Limit', 'Use', 'What it counts'],
      a.measures.map((m) => [
        m.name,
        m.value,
        m.limit ?? '–',
        m.limit ? h('span', { class: m.status === 'ok' ? '' : m.status === 'near_limit' ? 'warn-text' : 'bad' }, h('meter', { min: 0, max: 1, low: a.warn_at, high: 0.999, optimum: 0, value: Math.min(m.ratio, 1) }), ` ${Math.round(m.ratio * 100)}%`) : '',
        m.detail,
      ]),
    ),
    a.recommendation ? h('div', { class: 'card warn' }, h('p', {}, a.recommendation), h('code', {}, a.command)) : null,
  );
  const st = await api('GET', '/v1/stats');
  fill('stats', table(['#Records', '#Committed', '#Quarantined', '#Superseded', '#Subjects', '#Audit events', 'By kind'], [[st.memories, st.committed, st.quarantined, st.superseded, st.subjects, st.audit_events, st.by_kind.map(([k, n]) => `${k} ${n}`).join(', ')]]));
}

// ---- audit ----

async function loadAudit() {
  const events = await api('GET', '/v1/audit?limit=200');
  fill('audit', table(['When', 'Actor', 'Action', 'Subject', 'Memory', 'Detail'], events.map((e) => [stamp(e.at), e.actor, e.action, e.subject || '', e.memory_id ? h('span', { class: 'mono' }, e.memory_id) : '', h('span', { class: 'mono' }, JSON.stringify(e.detail))])));
}

// ---- wiring ----

function wire() {
  for (const k of KINDS) $('search-kind').append(h('option', {}, k));
  $('login-form').addEventListener('submit', login);
  $('logout').addEventListener('click', logout);
  $('tabs').addEventListener('click', (ev) => {
    const tab = ev.target instanceof HTMLElement && ev.target.dataset.tab;
    if (tab) openTab(tab);
  });
  $('subject-form').addEventListener('submit', (ev) => {
    ev.preventDefault();
    const s = $('subject-input').value.trim();
    if (s) pickSubject(s);
  });
  $('search-form').addEventListener('submit', search);
  $('search-clear').addEventListener('click', () => {
    $('search-q').value = '';
    fill('explanation');
    act('', () => loadMemories(true));
  });
  $('show-inactive').addEventListener('change', () => act('', () => loadMemories(true)));
  $('search-kind').addEventListener('change', () => act('', () => loadMemories(true)));
  $('memories-more').addEventListener('click', () => act('', () => loadMemories(false)));
  $('add-form').addEventListener('submit', addMemory);
  $('queue-form').addEventListener('submit', (ev) => {
    ev.preventDefault();
    act('', () => loadQueue(true));
  });
  $('queue-more').addEventListener('click', () => act('', () => loadQueue(false)));
  $('principal-form').addEventListener('submit', savePrincipal);
  $('key-form').addEventListener('submit', createKey);
  $('new-key-dismiss').addEventListener('click', () => {
    $('new-key-value').textContent = '';
    $('new-key').hidden = true;
  });
  $('policy-form').addEventListener('submit', (ev) => {
    ev.preventDefault();
    policyCall('/v1/policies', policyBody, loadPolicies);
  });
  $('policy-validate').addEventListener('click', () => policyCall('/v1/policies/validate', policyBody));
  $('policy-diff').addEventListener('click', () => policyCall('/v1/policies/diff', () => ({ spec: JSON.parse($('policy-spec').value) })));
  $('policy-rollback').addEventListener('click', () => rollbackPolicy(''));
  start();
}

wire();
