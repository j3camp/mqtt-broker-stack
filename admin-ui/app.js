const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const state = { operator: null, clients: [], roles: [], groups: [] };

function cookie(name) {
  return document.cookie.split('; ').find((row) => row.startsWith(`${name}=`))?.split('=').slice(1).join('=') || '';
}

async function api(path, options = {}) {
  const method = options.method || 'GET';
  const headers = { Accept: 'application/json', ...(options.headers || {}) };
  if (options.body && !(options.body instanceof FormData)) headers['Content-Type'] = 'application/json';
  if (!['GET', 'HEAD'].includes(method)) headers['X-CSRF-Token'] = decodeURIComponent(cookie('mqtt_admin_csrf'));
  const response = await fetch(path, { credentials: 'same-origin', ...options, method, headers });
  if (response.status === 204) return null;
  const type = response.headers.get('content-type') || '';
  const data = type.includes('json') ? await response.json() : await response.text();
  if (!response.ok) {
    const error = new Error(data.detail || data || `HTTP ${response.status}`);
    error.status = response.status;
    throw error;
  }
  return data;
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>'"]/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[char]));
}

function showError(error) {
  const target = $('#global-error');
  target.textContent = error.message || String(error);
  target.classList.remove('hidden');
  window.setTimeout(() => target.classList.add('hidden'), 7000);
}

function toast(message) {
  const target = $('#toast');
  target.textContent = message;
  target.classList.remove('hidden');
  window.setTimeout(() => target.classList.add('hidden'), 2800);
}

function roleLabel(role) {
  return ({ viewer: 'Viewer', operator: 'Operator', security_admin: 'Security Admin', super_admin: 'Super Admin' })[role] || role;
}

const titles = {
  overview: ['BROKER STATUS', '系統總覽'], clients: ['IDENTITY LIFECYCLE', 'MQTT Clients'],
  policies: ['ACCESS CONTROL', 'Roles、Groups 與 ACL'], connections: ['CONNECTION INTELLIGENCE', '連線狀態'],
  audit: ['SECURITY HISTORY', '稽核歷程'],
};

async function switchView(name) {
  $$('.nav-item').forEach((item) => item.classList.toggle('active', item.dataset.view === name));
  $$('.view').forEach((view) => view.classList.toggle('active', view.id === `view-${name}`));
  [$('#view-kicker').textContent, $('#view-title').textContent] = titles[name];
  try {
    if (name === 'overview') await loadOverview();
    if (name === 'clients') await loadClients();
    if (name === 'policies') await loadPolicies();
    if (name === 'connections') await loadConnections();
    if (name === 'audit') await loadAudit();
  } catch (error) { showError(error); }
}

function showApp(operator) {
  state.operator = operator;
  $('#login-view').classList.add('hidden');
  $('#app-shell').classList.remove('hidden');
  $('#operator-name').textContent = operator.display_name;
  $('#operator-role').textContent = roleLabel(operator.role);
  $('#audit-export-actions').classList.toggle('hidden', operator.role === 'viewer');
  switchView('overview');
}

async function init() {
  const capabilities = await api('/api/v1/capabilities').catch(() => ({ local_auth: true, oidc: false }));
  $('#login-form').classList.toggle('hidden', !capabilities.local_auth);
  $('#oidc-wrap').classList.toggle('hidden', !capabilities.oidc);
  try { showApp(await api('/api/v1/auth/me')); }
  catch { $('#login-view').classList.remove('hidden'); }
}

$('#login-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const values = Object.fromEntries(new FormData(event.currentTarget));
  const error = $('#login-error');
  error.classList.add('hidden');
  try {
    const result = await api('/api/v1/auth/login', { method: 'POST', body: JSON.stringify(values) });
    event.currentTarget.reset(); showApp(result.operator);
  } catch (problem) { error.textContent = problem.message; error.classList.remove('hidden'); }
});

$('#logout').addEventListener('click', async () => {
  try { await api('/api/v1/auth/logout', { method: 'POST' }); } finally { location.reload(); }
});
$$('.nav-item').forEach((item) => item.addEventListener('click', () => switchView(item.dataset.view)));

async function loadOverview() {
  const data = await api('/api/v1/overview');
  const cards = [
    ['Broker', data.broker.state, data.broker.version || 'Unavailable', data.broker.uptime || 'No fresh metrics'],
    ['Connected clients', data.broker.state, data.broker.connected_clients ?? '—', `Observed ${new Date(data.broker.observed_at).toLocaleTimeString()}`],
    ['TLS certificate', data.certificate.state, data.certificate.remaining_days == null ? 'Unavailable' : `${data.certificate.remaining_days} days`, `Warn at ${data.certificate.warning_threshold_days || '—'} days`],
    ['Last backup', data.persistence.backup.state, data.persistence.backup.age_hours == null ? 'Unknown' : `${data.persistence.backup.age_hours} hr`, `Maximum age ${data.persistence.backup.max_age_hours} hr`],
  ];
  $('#overview-cards').innerHTML = cards.map(([label, status, value, note]) => `<article class="metric ${escapeHtml(status)}"><span class="metric-label">${escapeHtml(label)}</span><div class="metric-value">${escapeHtml(value)}</div><span class="status ${escapeHtml(status)}">${escapeHtml(status)}</span><p class="muted">${escapeHtml(note)}</p></article>`).join('');
  $('#listeners').innerHTML = data.listeners.map((listener) => `<div class="listener"><strong>${listener.port}</strong><span>${escapeHtml(listener.protocol)}</span><span>${escapeHtml(listener.exposure)}</span><span>${escapeHtml(listener.authentication)}</span></div>`).join('');
  const cert = data.certificate;
  $('#certificate-detail').innerHTML = `<div class="cert-grid"><span class="status ${escapeHtml(cert.state)}">${escapeHtml(cert.state)}</span><div class="cert-field"><span>Subject</span><strong>${escapeHtml(cert.subject || cert.error || 'Unknown')}</strong></div><div class="cert-field"><span>Issuer</span><strong>${escapeHtml(cert.issuer || 'Unknown')}</strong></div><div class="cert-field"><span>Subject Alternative Names</span><strong>${escapeHtml((cert.sans || []).join(', ') || 'None')}</strong></div><div class="cert-field"><span>Expires</span><strong>${cert.not_after ? new Date(cert.not_after).toLocaleString() : 'Unknown'}</strong></div></div>`;
}

async function loadClients() {
  const q = encodeURIComponent($('#client-search').value.trim());
  state.clients = await api(`/api/v1/clients${q ? `?q=${q}` : ''}`);
  $('#client-count').textContent = `${state.clients.length} identities`;
  $('#clients-body').innerHTML = state.clients.length ? state.clients.map((client) => {
    const online = (client.connections || []).length;
    const disabled = Boolean(client.disabled);
    return `<tr><td><strong>${escapeHtml(client.username)}</strong><span class="muted">${escapeHtml(client.textname || '')}</span></td><td>${escapeHtml(client.clientid || 'Any')}</td><td><span class="pill ${disabled ? 'failure' : 'healthy'}">${disabled ? 'Disabled' : 'Enabled'}</span></td><td>${(client.roles || []).length} roles / ${(client.groups || []).length} groups</td><td>${online ? `<span class="status healthy">${online} online</span>` : '<span class="status offline">offline</span>'}</td><td><div class="row-actions"><button data-client-action="access" data-name="${escapeHtml(client.username)}">存取權</button><button data-client-action="rotate" data-name="${escapeHtml(client.username)}">換密碼</button><button data-client-action="${disabled ? 'enable' : 'disable'}" data-name="${escapeHtml(client.username)}">${disabled ? '啟用' : '停用'}</button><button class="danger-text" data-client-action="delete" data-name="${escapeHtml(client.username)}">刪除</button></div></td></tr>`;
  }).join('') : '<tr><td colspan="6" class="muted">沒有符合條件的 client。</td></tr>';
  $$('[data-client-action]').forEach((button) => button.addEventListener('click', () => clientAction(button.dataset.clientAction, button.dataset.name)));
}
$('#search-clients').addEventListener('click', loadClients);
$('#client-search').addEventListener('keydown', (event) => { if (event.key === 'Enter') loadClients(); });

function modal({ title, kicker = 'ADMIN ACTION', fields = [], submit = '確認', danger = false }) {
  $('#modal-title').textContent = title; $('#modal-kicker').textContent = kicker;
  $('#modal-submit').textContent = submit; $('#modal-submit').className = `button ${danger ? 'danger' : 'primary'}`;
  $('#modal-error').classList.add('hidden');
  $('#modal-fields').innerHTML = fields.map((field) => {
    const required = field.required === false ? '' : 'required';
    if (field.type === 'select') return `<label>${escapeHtml(field.label)}<select name="${escapeHtml(field.name)}" ${required}>${field.options.map((option) => `<option value="${escapeHtml(option.value ?? option)}">${escapeHtml(option.label ?? option)}</option>`).join('')}</select></label>`;
    if (field.type === 'checkbox') return `<label class="check"><input type="checkbox" name="${escapeHtml(field.name)}"> ${escapeHtml(field.label)}</label>`;
    return `<label>${escapeHtml(field.label)}<input name="${escapeHtml(field.name)}" type="${field.type || 'text'}" value="${escapeHtml(field.value || '')}" placeholder="${escapeHtml(field.placeholder || '')}" ${required}></label>`;
  }).join('');
  const dialog = $('#modal'); dialog.showModal();
  return new Promise((resolve) => {
    const form = $('#modal-form');
    const cleanup = () => { form.removeEventListener('submit', handler); dialog.removeEventListener('cancel', cancelHandler); };
    const cancelHandler = () => { cleanup(); resolve(null); };
    const handler = (event) => {
      event.preventDefault();
      if (event.submitter?.value === 'cancel') { cleanup(); dialog.close(); resolve(null); return; }
      if (!event.currentTarget.reportValidity()) return;
      const raw = Object.fromEntries(new FormData(event.currentTarget));
      fields.filter((field) => field.type === 'number').forEach((field) => raw[field.name] = Number(raw[field.name]));
      fields.filter((field) => field.type === 'checkbox').forEach((field) => raw[field.name] = Boolean(raw[field.name]));
      cleanup(); dialog.close(); resolve(raw);
    };
    form.addEventListener('submit', handler);
    dialog.addEventListener('cancel', cancelHandler, { once: true });
  });
}

$('#create-client').addEventListener('click', async () => {
  const values = await modal({ title: '新增 MQTT Client', kicker: 'IDENTITY LIFECYCLE', submit: '建立 Client', fields: [
    { name: 'username', label: 'Username' }, { name: 'password', label: '初始密碼（至少 12 字元）', type: 'password' },
    { name: 'clientid', label: '綁定 Client ID（可留空）', required: false }, { name: 'textname', label: '顯示名稱（可留空）', required: false },
  ] });
  if (!values) return;
  try { await api('/api/v1/clients', { method: 'POST', body: JSON.stringify(values) }); toast('Client 已建立，密碼不會再次顯示'); await loadClients(); } catch (error) { showError(error); }
});

async function clientAction(action, username) {
  try {
    if (action === 'rotate') {
      const values = await modal({ title: `輪替 ${username} 的密碼`, submit: '輪替密碼', fields: [{ name: 'password', label: '新密碼（至少 12 字元）', type: 'password' }] });
      if (!values) return; await api(`/api/v1/clients/${encodeURIComponent(username)}/password`, { method: 'POST', body: JSON.stringify(values) }); toast('密碼已輪替，內容未被記錄');
    } else if (action === 'delete') {
      const expected = `delete client ${username}`;
      const values = await modal({ title: `刪除 ${username}`, kicker: 'DESTRUCTIVE ACTION', submit: '永久刪除', danger: true, fields: [{ name: 'confirmation', label: `輸入「${expected}」以確認` }] });
      if (!values || values.confirmation !== expected) { if (values) showError(new Error('確認文字不符')); return; }
      await api(`/api/v1/clients/${encodeURIComponent(username)}`, { method: 'DELETE', headers: { 'X-Confirm-Action': expected } }); toast('Client 已刪除');
    } else if (action === 'access') {
      await loadPoliciesData();
      const current = state.clients.find((client) => client.username === username) || { roles: [], groups: [] };
      const options = [
        ...state.roles.map((item) => ({ value: `roles|${item.rolename}`, label: `Role: ${item.rolename}${(current.roles || []).some((role) => role.rolename === item.rolename) ? '（已指派）' : ''}` })),
        ...state.groups.map((item) => ({ value: `groups|${item.groupname}`, label: `Group: ${item.groupname}${(current.groups || []).some((group) => group.groupname === item.groupname) ? '（已指派）' : ''}` })),
      ];
      const values = await modal({ title: `指派 ${username} 的存取權`, fields: [
        { name: 'operation', label: '操作', type: 'select', options: [{ value: 'assign', label: '指派／更新 priority' }, { value: 'remove', label: '移除' }] },
        { name: 'assignment', label: 'Role 或 Group', type: 'select', options },
        { name: 'priority', label: 'Priority（-1 到 100000）', type: 'number', value: '-1' },
      ] });
      if (!values) return;
      const [kind, name] = values.assignment.split('|');
      if (values.operation === 'remove') {
        await api(`/api/v1/clients/${encodeURIComponent(username)}/${kind}/${encodeURIComponent(name)}`, { method: 'DELETE' });
        toast('存取權已移除');
      } else {
        await api(`/api/v1/clients/${encodeURIComponent(username)}/${kind}`, { method: 'PUT', body: JSON.stringify({ name, priority: values.priority }) });
        toast('存取權已指派');
      }
    } else {
      await api(`/api/v1/clients/${encodeURIComponent(username)}/${action}`, { method: 'POST' }); toast(action === 'enable' ? 'Client 已啟用' : 'Client 已停用');
    }
    await loadClients();
  } catch (error) { showError(error); }
}

async function loadPoliciesData() {
  [state.roles, state.groups] = await Promise.all([api('/api/v1/roles'), api('/api/v1/groups')]);
}

async function loadPolicies() {
  await loadPoliciesData();
  $('#role-list').innerHTML = state.roles.map((role) => `<div class="object"><div class="object-top"><div><h3>${escapeHtml(role.rolename)}</h3><p>${escapeHtml(role.textdescription || role.textname || 'No description')}</p></div><div class="object-actions"><button data-role-action="acl" data-name="${escapeHtml(role.rolename)}">新增 ACL</button><button data-role-action="edit" data-name="${escapeHtml(role.rolename)}">編輯</button><button data-role-action="delete" data-name="${escapeHtml(role.rolename)}">刪除</button></div></div><div class="acl-list">${(role.acls || []).map((acl) => `<div class="acl"><span>${escapeHtml(acl.acltype)}</span><span>${escapeHtml(acl.topic)}</span><strong>${acl.allow ? 'ALLOW' : 'DENY'}</strong><span>P${acl.priority ?? -1}</span><button data-acl-remove="${escapeHtml(role.rolename)}" data-acltype="${escapeHtml(acl.acltype)}" data-topic="${escapeHtml(acl.topic)}">移除</button></div>`).join('') || '<span class="muted">沒有 ACL；將套用 broker default。</span>'}</div></div>`).join('') || '<p class="muted">尚無 role。</p>';
  $('#group-list').innerHTML = state.groups.map((group) => `<div class="object"><div class="object-top"><div><h3>${escapeHtml(group.groupname)}</h3><p>${(group.roles || []).length} roles · ${(group.clients || []).length} clients</p></div><div class="object-actions"><button data-group-action="role" data-name="${escapeHtml(group.groupname)}">指派 Role</button><button data-group-action="edit" data-name="${escapeHtml(group.groupname)}">編輯</button><button data-group-action="delete" data-name="${escapeHtml(group.groupname)}">刪除</button></div></div></div>`).join('') || '<p class="muted">尚無 group。</p>';
  $$('[data-role-action]').forEach((button) => button.addEventListener('click', () => roleAction(button.dataset.roleAction, button.dataset.name)));
  $$('[data-group-action]').forEach((button) => button.addEventListener('click', () => groupAction(button.dataset.groupAction, button.dataset.name)));
  $$('[data-acl-remove]').forEach((button) => button.addEventListener('click', () => removeAcl(button.dataset.aclRemove, button.dataset.acltype, button.dataset.topic)));
}

async function removeAcl(role, acltype, topic) {
  const expected = `remove ACL ${role} ${acltype} ${topic}`;
  const values = await modal({ title: `移除 ${role} ACL`, kicker: 'ACCESS CHANGE', submit: '移除 ACL', danger: true, fields: [{ name: 'confirmation', label: `輸入「${expected}」以確認` }] });
  if (!values || values.confirmation !== expected) return;
  try {
    await api(`/api/v1/roles/${encodeURIComponent(role)}/acls?acltype=${encodeURIComponent(acltype)}&topic=${encodeURIComponent(topic)}`, { method: 'DELETE', headers: { 'X-Confirm-Action': expected } });
    toast('ACL 已移除'); await loadPolicies();
  } catch (error) { showError(error); }
}

async function createNamed(kind) {
  const values = await modal({ title: `新增 ${kind === 'roles' ? 'Role' : 'Group'}`, fields: [{ name: 'name', label: '識別名稱' }, { name: 'textname', label: '顯示名稱', required: false }, { name: 'textdescription', label: '說明', required: false }] });
  if (!values) return; await api(`/api/v1/${kind}`, { method: 'POST', body: JSON.stringify(values) }); toast('物件已建立'); await loadPolicies();
}
$('#create-role').addEventListener('click', () => createNamed('roles').catch(showError));
$('#create-group').addEventListener('click', () => createNamed('groups').catch(showError));

async function roleAction(action, name) {
  try {
    if (action === 'acl') {
      const values = await modal({ title: `新增 ${name} ACL`, fields: [
        { name: 'acltype', label: 'ACL type', type: 'select', options: ['publishClientSend', 'publishClientReceive', 'subscribeLiteral', 'subscribePattern', 'unsubscribeLiteral', 'unsubscribePattern'] },
        { name: 'topic', label: 'Topic filter' }, { name: 'allow', label: 'Decision', type: 'select', options: [{ value: 'true', label: 'Allow' }, { value: 'false', label: 'Deny' }] },
        { name: 'priority', label: 'Priority', type: 'number', value: '-1' }, { name: 'elevated_confirmation', label: '我確認這是必要的廣泛授權', type: 'checkbox', required: false },
      ] });
      if (!values) return; values.allow = values.allow === 'true'; await api(`/api/v1/roles/${encodeURIComponent(name)}/acls`, { method: 'POST', body: JSON.stringify(values) });
    } else if (action === 'edit') {
      const current = state.roles.find((role) => role.rolename === name) || {};
      const values = await modal({ title: `編輯 ${name}`, fields: [{ name: 'textname', label: '顯示名稱', value: current.textname, required: false }, { name: 'textdescription', label: '說明', value: current.textdescription, required: false }] });
      if (!values) return; await api(`/api/v1/roles/${encodeURIComponent(name)}`, { method: 'PATCH', body: JSON.stringify({ name, ...values }) });
    } else {
      const expected = `delete role ${name}`; const values = await modal({ title: `刪除 ${name}`, danger: true, fields: [{ name: 'confirmation', label: `輸入「${expected}」以確認` }] });
      if (!values || values.confirmation !== expected) return; await api(`/api/v1/roles/${encodeURIComponent(name)}`, { method: 'DELETE', headers: { 'X-Confirm-Action': expected } });
    }
    toast('Role 已更新'); await loadPolicies();
  } catch (error) { showError(error); }
}

async function groupAction(action, name) {
  try {
    if (action === 'role') {
      const current = state.groups.find((group) => group.groupname === name) || { roles: [] };
      const values = await modal({ title: `管理 ${name} 的 Role`, fields: [{ name: 'operation', label: '操作', type: 'select', options: [{ value: 'assign', label: '指派／更新 priority' }, { value: 'remove', label: '移除' }] }, { name: 'name', label: 'Role', type: 'select', options: state.roles.map((role) => ({ value: role.rolename, label: `${role.rolename}${(current.roles || []).some((item) => item.rolename === role.rolename) ? '（已指派）' : ''}` })) }, { name: 'priority', label: 'Priority', type: 'number', value: '-1' }] });
      if (!values) return;
      if (values.operation === 'remove') await api(`/api/v1/groups/${encodeURIComponent(name)}/roles/${encodeURIComponent(values.name)}`, { method: 'DELETE' });
      else await api(`/api/v1/groups/${encodeURIComponent(name)}/roles`, { method: 'PUT', body: JSON.stringify({ name: values.name, priority: values.priority }) });
    } else if (action === 'edit') {
      const current = state.groups.find((group) => group.groupname === name) || {};
      const values = await modal({ title: `編輯 ${name}`, fields: [{ name: 'textname', label: '顯示名稱', value: current.textname, required: false }, { name: 'textdescription', label: '說明', value: current.textdescription, required: false }] });
      if (!values) return; await api(`/api/v1/groups/${encodeURIComponent(name)}`, { method: 'PATCH', body: JSON.stringify({ name, ...values }) });
    } else {
      const expected = `delete group ${name}`; const values = await modal({ title: `刪除 ${name}`, danger: true, fields: [{ name: 'confirmation', label: `輸入「${expected}」以確認` }] });
      if (!values || values.confirmation !== expected) return; await api(`/api/v1/groups/${encodeURIComponent(name)}`, { method: 'DELETE', headers: { 'X-Confirm-Action': expected } });
    }
    toast('Group 已更新'); await loadPolicies();
  } catch (error) { showError(error); }
}

$('#permission-form').addEventListener('submit', async (event) => {
  event.preventDefault(); const values = Object.fromEntries(new FormData(event.currentTarget));
  try {
    const result = await api('/api/v1/permissions/evaluate', { method: 'POST', body: JSON.stringify(values) });
    const target = $('#permission-result'); target.className = `decision ${result.decision}`;
    target.innerHTML = `<strong>${result.decision.toUpperCase()}</strong><p>${result.matched ? `Matched ${escapeHtml(result.source.role)} via ${escapeHtml(result.source.type)} ${escapeHtml(result.source.name)}.` : `No matching ACL. Broker default ${escapeHtml(result.source.name)} applies.`}</p>${result.rule ? `<code>${escapeHtml(result.rule.acltype)} ${escapeHtml(result.rule.topic)} · priority ${result.rule.priority}</code>` : ''}`;
  } catch (error) { showError(error); }
});

async function loadConnections() {
  const data = await api('/api/v1/connections');
  $('#connection-source').textContent = `${data.source} · ${new Date(data.observed_at).toLocaleString()}`;
  $('#connections-body').innerHTML = data.connections.map((item) => `<tr><td><strong>${escapeHtml(item.username)}</strong></td><td>${escapeHtml(item.clientid || '—')}</td><td><span class="status ${item.state === 'online' ? 'healthy' : 'offline'}">${escapeHtml(item.state)}</span></td><td>${escapeHtml(item.listener || item.address || '—')}</td><td>${escapeHtml(item.last_seen || item.connectedAt || '—')}</td></tr>`).join('') || '<tr><td colspan="5" class="muted">沒有連線資料。</td></tr>';
}
$('#refresh-connections').addEventListener('click', () => loadConnections().catch(showError));

async function loadAudit() {
  const q = encodeURIComponent($('#audit-search').value.trim()); const data = await api(`/api/v1/audit${q ? `?q=${q}` : ''}`);
  $('#chain-status').textContent = data.chain.valid ? `Verified · ${data.chain.count} events` : `Broken at #${data.chain.failed_sequence}`;
  $('#chain-status').className = `tag ${data.chain.valid ? 'healthy' : 'failure'}`;
  $('#audit-body').innerHTML = data.events.map((event) => `<tr><td><strong>#${event.sequence}</strong><span class="muted">${new Date(event.occurred_at).toLocaleString()}</span></td><td>${escapeHtml(event.actor_id || 'anonymous')}<span class="muted">${escapeHtml(event.actor_role || '')}</span></td><td>${escapeHtml(event.action)}</td><td>${escapeHtml(event.target)}</td><td><span class="pill ${event.result === 'success' ? 'healthy' : 'failure'}">${escapeHtml(event.result)}</span></td><td><code>${escapeHtml(event.correlation_id)}</code></td></tr>`).join('') || '<tr><td colspan="6" class="muted">沒有稽核事件。</td></tr>';
}
$('#search-audit').addEventListener('click', () => loadAudit().catch(showError));

init().catch((error) => { $('#login-view').classList.remove('hidden'); $('#login-error').textContent = error.message; $('#login-error').classList.remove('hidden'); });
