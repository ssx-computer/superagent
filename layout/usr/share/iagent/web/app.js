/*
 * iAgent — 前端逻辑（零依赖，iOS 15 WKWebView / Safari 可直接运行）
 *
 * 页面：聊天 / 终端 / 工具 / 会话 / 设置
 * 后端：daemon 提供的 http://127.0.0.1:<port>/api/*
 */
'use strict';
(function () {

/* ==========================================================================
 * 通用工具
 * ========================================================================== */

function $(id) { return document.getElementById(id); }

function esc(value) {
  return String(value == null ? '' : value)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function el(tag, className, text) {
  var node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = String(text);
  return node;
}

function clear(node) { while (node && node.firstChild) node.removeChild(node.firstChild); }

function show(node) { if (node) node.classList.remove('hidden'); }
function hide(node) { if (node) node.classList.add('hidden'); }

function fmtTime(seconds) {
  if (!seconds) return '—';
  var d = new Date(seconds * 1000);
  var now = new Date();
  var sameDay = d.toDateString() === now.toDateString();
  function pad(n) { return n < 10 ? '0' + n : '' + n; }
  if (sameDay) return pad(d.getHours()) + ':' + pad(d.getMinutes());
  return (d.getMonth() + 1) + '/' + d.getDate() + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
}

function fmtDuration(ms) {
  if (ms == null) return '';
  if (ms < 1000) return ms + 'ms';
  return (ms / 1000).toFixed(2) + 's';
}

function fmtBytes(n) {
  if (n == null || n < 0) return '—';
  if (n < 1024) return n + ' B';
  if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
  if (n < 1073741824) return (n / 1048576).toFixed(2) + ' MB';
  return (n / 1073741824).toFixed(2) + ' GB';
}

var toastTimers = [];
function toast(message, type) {
  var host = $('toast-host');
  if (!host) return;
  var node = el('div', 'toast ' + (type === 'err' ? 'err' : type === 'ok' ? 'ok' : ''), message);
  host.appendChild(node);
  var timer = setTimeout(function () {
    if (node.parentNode) node.parentNode.removeChild(node);
  }, 2600);
  toastTimers.push(timer);
  while (host.childNodes.length > 4) host.removeChild(host.firstChild);
  if (toastTimers.length > 40) toastTimers = toastTimers.slice(-20);
}

/* ==========================================================================
 * 应用状态
 * ========================================================================== */

var state = {
  token: localStorage.getItem('iag_token') || '',
  health: null,
  config: null,
  configOriginal: null,
  sessions: [],
  sessionId: localStorage.getItem('iag_last_session') || '',
  messages: [],
  streaming: false,
  streamAbort: null,
  abortRequested: false,
  approvals: {},
  tools: [],
  selectedTool: null,
  cron: [],
  chatAutoScroll: true,
  activePage: 'chat',
  term: {
    sessions: [],
    current: null,
    cursor: 0,
    timer: null,
    emulator: null,
    measuring: null
  }
};

/* ==========================================================================
 * API 层
 * ========================================================================== */

function apiURL(path) { return path; }

function apiFetch(path, options) {
  options = options || {};
  var headers = options.headers || {};
  headers['Accept'] = headers['Accept'] || 'application/json';
  if (state.token) headers['X-IAG-Token'] = state.token;
  if (options.body && !headers['Content-Type']) headers['Content-Type'] = 'application/json';
  var init = {
    method: options.method || 'GET',
    headers: headers,
    cache: 'no-store'
  };
  if (options.body) init.body = typeof options.body === 'string' ? options.body : JSON.stringify(options.body);
  if (options.signal) init.signal = options.signal;
  return fetch(apiURL(path), init);
}

function apiErrorFrom(status, text) {
  var message = text || '';
  try {
    var parsed = JSON.parse(text);
    if (parsed && parsed.error) message = parsed.error;
  } catch (e) { /* 不是 JSON，直接用原文 */ }
  var error = new Error(message || ('HTTP ' + status));
  error.status = status;
  return error;
}

function api(path, options) {
  return apiFetch(path, options).then(function (response) {
    return response.text().then(function (text) {
      if (!response.ok) throw apiErrorFrom(response.status, text);
      if (!text) return null;
      try { return JSON.parse(text); } catch (e) { return { raw: text }; }
    });
  });
}

function apiToast(path, options) {
  return api(path, options).catch(function (error) {
    toast(error.message || '请求失败', 'err');
    throw error;
  });
}

/* ==========================================================================
 * 标签页
 * ========================================================================== */

var PAGE_STARTED = {};

function switchPage(name) {
  state.activePage = name;
  var sections = document.querySelectorAll('#pages .page');
  for (var i = 0; i < sections.length; i++) {
    var section = sections[i];
    if (section.getAttribute('data-page') === name) { section.classList.add('active'); show(section); }
    else { section.classList.remove('active'); hide(section); }
  }
  var tabs = document.querySelectorAll('#tabbar .tab');
  for (var j = 0; j < tabs.length; j++) {
    var tab = tabs[j];
    if (tab.getAttribute('data-tab') === name) tab.classList.add('active');
    else tab.classList.remove('active');
  }
  document.body.setAttribute('data-active-page', name);

  if (name === 'term') { startTerminalPolling(); }
  else { stopTerminalPolling(); }

  if (name === 'tools' && !PAGE_STARTED.tools) { PAGE_STARTED.tools = true; loadTools(); loadCron(); }
  if (name === 'sessions') loadSessions();
  if (name === 'settings' && !PAGE_STARTED.settings) { PAGE_STARTED.settings = true; loadConfig(); }
}

/* ==========================================================================
 * 健康检查
 * ========================================================================== */

function setConn(ok, label) {
  var dot = $('conn-dot');
  var text = $('conn-label');
  if (dot) dot.className = 'conn-dot ' + (ok ? 'ok' : 'bad');
  if (text) text.textContent = label;
}

function checkHealth(silent) {
  return api('/api/health').then(function (health) {
    state.health = health;
    setConn(true, '已连接 · v' + (health.version || '?'));
    var ver = $('appbar-ver');
    if (ver) ver.textContent = 'v' + (health.version || '');
    updateChatBanner();
    renderDiag();
    return health;
  }).catch(function (error) {
    setConn(false, '未连接');
    if (!silent) toast('无法连接 daemon：' + (error.message || ''), 'err');
    updateChatBanner();
    return null;
  });
}

function updateChatBanner() {
  var banner = $('chat-banner');
  if (!banner) return;
  var health = state.health;
  var needKey = health && health.model && health.model.hasKey === false;
  if (needKey) {
    clear(banner);
    banner.appendChild(el('span', 'banner-text', '尚未配置模型 API Key，点击前往设置'));
    banner.onclick = function () { switchPage('settings'); };
    banner.style.cursor = 'pointer';
    show(banner);
  } else {
    hide(banner);
  }
}

/* ==========================================================================
 * 聊天
 * ========================================================================== */

function currentSession() {
  for (var i = 0; i < state.sessions.length; i++) {
    if (state.sessions[i].id === state.sessionId) return state.sessions[i];
  }
  return null;
}

function updateChatHeader() {
  var title = $('chat-title');
  var sub = $('chat-sub');
  var session = currentSession();
  if (session) {
    title.textContent = session.title || '未命名会话';
    sub.textContent = (session.messageCount || 0) + ' 条消息 · ' + fmtTime(session.updatedAt);
  } else if (state.sessionId) {
    title.textContent = state.sessionId;
    sub.textContent = '会话';
  } else {
    title.textContent = '未选择会话';
    sub.textContent = '先发送一条消息即可开始';
  }
}

function scrollChatToBottom(force) {
  var scroller = $('chat-scroll');
  if (!scroller) return;
  if (force || state.chatAutoScroll) scroller.scrollTop = scroller.scrollHeight;
}

function bindChatScroll() {
  var scroller = $('chat-scroll');
  if (!scroller) return;
  scroller.addEventListener('scroll', function () {
    var distance = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight;
    state.chatAutoScroll = distance < 80;
  });
}

/* ==========================================================================
 * 页内弹窗
 *
 * WKWebView（SpringBoard 内置面板、部分 App 内嵌浏览器）不实现原生的
 * confirm()/prompt()：调用会直接返回 undefined/null 并且不显示任何界面。
 * 所以删除、重命名、清空 Key 这类需要确认的操作必须自己画弹窗。
 * ========================================================================== */

function modalHost() {
  var host = $('modal-host');
  if (!host) {
    host = el('div');
    host.id = 'modal-host';
    document.body.appendChild(host);
  }
  return host;
}

function showModal(build) {
  var host = modalHost();
  clear(host);

  var overlay = el('div', 'modal');
  var backdrop = el('div', 'modal-backdrop');
  var panel = el('div', 'modal-panel');

  function close() { clear(host); }

  backdrop.onclick = close;
  overlay.appendChild(backdrop);
  overlay.appendChild(panel);
  host.appendChild(overlay);
  build(panel, close);
  return close;
}

function confirmModal(title, message, confirmLabel, danger, onConfirm) {
  showModal(function (panel, close) {
    var head = el('div', 'modal-head');
    head.appendChild(el('div', 'modal-title', title));
    panel.appendChild(head);

    var body = el('div', 'modal-body');
    body.appendChild(el('div', null, message));
    panel.appendChild(body);

    var footer = el('div', 'modal-footer');
    var cancel = el('button', 'btn', '取消');
    cancel.type = 'button';
    cancel.onclick = close;
    var confirm = el('button', 'btn ' + (danger ? 'btn-danger' : 'btn-primary'), confirmLabel || '确定');
    confirm.type = 'button';
    confirm.onclick = function () { close(); onConfirm(); };
    footer.appendChild(cancel);
    footer.appendChild(confirm);
    panel.appendChild(footer);
  });
}

function promptModal(title, value, placeholder, onSubmit) {
  showModal(function (panel, close) {
    var head = el('div', 'modal-head');
    head.appendChild(el('div', 'modal-title', title));
    panel.appendChild(head);

    var body = el('div', 'modal-body');
    var input = document.createElement('input');
    input.type = 'text';
    input.className = 'input modal-input';
    input.value = value == null ? '' : String(value);
    input.placeholder = placeholder || '';
    body.appendChild(input);
    panel.appendChild(body);

    var footer = el('div', 'modal-footer');
    var cancel = el('button', 'btn', '取消');
    cancel.type = 'button';
    cancel.onclick = close;
    var confirm = el('button', 'btn btn-primary', '确定');
    confirm.type = 'button';
    confirm.onclick = function () { var text = input.value; close(); onSubmit(text); };
    input.onkeydown = function (event) {
      if (event.key === 'Enter') { event.preventDefault(); confirm.onclick(); }
    };
    footer.appendChild(cancel);
    footer.appendChild(confirm);
    panel.appendChild(footer);

    setTimeout(function () { try { input.focus(); input.select(); } catch (e) {} }, 60);
  });
}

function normalizeToolCall(toolCall) {
  if (!toolCall) return { id: '', name: 'tool', arguments: null };
  if (toolCall.function) {
    var raw = toolCall.function.arguments;
    var parsed = raw;
    if (typeof raw === 'string') {
      try { parsed = JSON.parse(raw); } catch (e) { parsed = raw; }
    }
    return { id: toolCall.id || '', name: toolCall.function.name || 'tool', arguments: parsed };
  }
  return { id: toolCall.id || '', name: toolCall.name || 'tool', arguments: toolCall.arguments };
}

function toolResultFromMessage(message) {
  var content = message.content || '';
  if (content.indexOf('工具执行失败') === 0) {
    return { ok: false, error: content.replace(/^工具执行失败[:：]\s*/, '') };
  }
  return { ok: true, output: content };
}

// Maps tool_call_id -> the stored tool message, so a reloaded session renders
// results inside the matching card.
function buildResultIndex() {
  var index = {};
  for (var i = 0; i < state.messages.length; i++) {
    var message = state.messages[i];
    if (message.role === 'tool' && message.toolCallId) index[message.toolCallId] = message;
  }
  return index;
}

function renderMessages() {
  var list = $('chat-list');
  clear(list);
  var results = buildResultIndex();
  for (var i = 0; i < state.messages.length; i++) {
    var message = state.messages[i];
    if (message.role === 'tool') continue;   // shown inside its tool card
    list.appendChild(renderMessage(message, results));
  }
  scrollChatToBottom(true);
}

function renderMessage(message, results) {
  results = results || {};
  var role = message.role === 'user' ? 'user' : (message.role === 'system' ? 'system' : 'assistant');
  var fragment = document.createDocumentFragment();

  var wrapper = el('div', 'msg ' + role);
  var bubble = el('div', 'bubble');

  if (message.reasoning) {
    var reason = el('div', 'reason-box');
    reason.appendChild(el('div', 'reason-title', '推理过程'));
    reason.appendChild(el('div', 'reason-text', message.reasoning));
    reason.onclick = function () { reason.classList.toggle('open'); };
    bubble.appendChild(reason);
  }
  if (message.content) {
    var text = el('div', 'msg-text');
    text.textContent = message.content;
    bubble.appendChild(text);
  }
  if (!message.content && !message.toolCalls && !message.reasoning) {
    bubble.appendChild(el('div', 'muted', '…'));
  }
  wrapper.appendChild(bubble);
  fragment.appendChild(wrapper);

  // Tool cards are siblings of the bubble — that is how the stylesheet lays out
  // .toolcard / .approval / .notice (they carry their own horizontal margins).
  var toolCalls = message.toolCalls || [];
  for (var i = 0; i < toolCalls.length; i++) {
    var call = normalizeToolCall(toolCalls[i]);
    var stored = call.id ? results[call.id] : null;
    fragment.appendChild(renderToolCard(call, stored ? toolResultFromMessage(stored) : null));
  }
  return fragment;
}

function renderToolCard(toolCall, result) {
  var card = el('div', 'toolcard');
  if (toolCall.id) card.setAttribute('data-call', toolCall.id);

  var head = el('div', 'toolcard-head');
  head.appendChild(el('span', 'toolcard-name', toolCall.name || 'tool'));

  var argsText = '';
  if (toolCall.arguments != null) {
    argsText = typeof toolCall.arguments === 'string'
      ? toolCall.arguments
      : JSON.stringify(toolCall.arguments);
  }
  head.appendChild(el('span', 'toolcard-args', argsText));

  var pillClass = 'pill wait';
  var pillText = '运行中…';
  if (result) {
    if (result.ok) { pillClass = 'pill ok'; pillText = '成功'; }
    else { pillClass = 'pill fail'; pillText = '失败'; }
  }
  head.appendChild(el('span', pillClass, pillText));
  head.appendChild(el('span', 'chev', '▸'));
  card.appendChild(head);

  if (result) {
    var body = el('div', 'toolcard-body');
    var meta = [];
    if (result.durationMs != null) meta.push(fmtDuration(result.durationMs));
    if (result.exitCode != null) meta.push('exit ' + result.exitCode);
    if (meta.length) body.appendChild(el('div', 'kv', meta.join(' · ')));

    var output = result.ok ? (result.output || '(无输出)') : (result.error || '执行失败');
    var clamp = String(output).length > 600;
    var pre = el('pre', 'output-pre' + (clamp ? ' clamped' : ''), output);
    body.appendChild(pre);
    if (clamp) {
      var toggle = el('button', 'output-toggle', '展开全部输出');
      toggle.type = 'button';
      toggle.onclick = function (event) {
        event.stopPropagation();
        var nowClamped = pre.classList.toggle('clamped');
        toggle.textContent = nowClamped ? '展开全部输出' : '收起输出';
      };
      body.appendChild(toggle);
    }
    card.appendChild(body);
  }

  // An in-flight call stays open so the command is visible while it runs.
  if (!result) card.classList.add('open');
  head.onclick = function () { card.classList.toggle('open'); };
  return card;
}

function renderApprovalCard(payload) {
  var card = el('div', 'approval');
  card.setAttribute('data-approval', payload.id);
  card.appendChild(el('div', 'approval-title', '需要确认：' + (payload.name || '工具')));
  var body = el('div', 'approval-body');
  body.appendChild(el('div', 'muted', payload.reason || '该操作被判定为需要确认'));
  var argsText = typeof payload.arguments === 'string' ? payload.arguments : JSON.stringify(payload.arguments || {}, null, 2);
  body.appendChild(el('code', 'inline-code', argsText));
  card.appendChild(body);

  var actions = el('div', 'approval-actions');
  var allow = el('button', 'btn btn-sm btn-primary', '允许');
  var deny = el('button', 'btn btn-sm btn-danger-ghost', '拒绝');
  allow.type = 'button'; deny.type = 'button';

  function decide(granted) {
    allow.disabled = true; deny.disabled = true;
    api('/api/approve', { method: 'POST', body: { id: payload.id, allow: granted } })
      .then(function () {
        card.classList.add('decided');
        clear(actions);
        actions.appendChild(el('span', 'pill ' + (granted ? 'ok' : 'fail'), granted ? '已允许' : '已拒绝'));
        if (!granted) { /* 流会收到 tool_result */ }
      })
      .catch(function (error) {
        allow.disabled = false; deny.disabled = false;
        toast('审批失败：' + error.message, 'err');
      });
  }
  allow.onclick = function () { decide(true); };
  deny.onclick = function () { decide(false); };
  actions.appendChild(allow);
  actions.appendChild(deny);
  card.appendChild(actions);
  return card;
}

function appendToChat(node) {
  var list = $('chat-list');
  list.appendChild(node);
  scrollChatToBottom();
  return node;
}

function setStreaming(active) {
  state.streaming = active;
  if (active) show($('chat-stop')); else hide($('chat-stop'));
  var send = $('chat-send');
  if (send) send.disabled = active;
}

function ensureSession() {
  if (state.sessionId) return Promise.resolve(state.sessionId);
  return api('/api/sessions', { method: 'POST', body: {} }).then(function (session) {
    state.sessionId = session.id;
    localStorage.setItem('iag_last_session', session.id);
    state.sessions.unshift(session);
    updateChatHeader();
    return session.id;
  });
}

function sendMessage(textOverride) {
  if (state.streaming) return;
  var input = $('chat-input');
  var text = (typeof textOverride === 'string' ? textOverride : input.value).trim();
  if (!text) return;

  if (typeof textOverride !== 'string') {
    input.value = '';
    input.style.height = 'auto';
  }
  state.chatAutoScroll = true;

  ensureSession().then(function (sessionId) {
    var userMessage = { role: 'user', content: text, createdAt: Date.now() / 1000 };
    state.messages.push(userMessage);
    appendToChat(renderMessage(userMessage, {}));

    var assistantNode = el('div', 'msg assistant');
    var assistantBubble = el('div', 'bubble streaming');
    var assistantText = el('div', 'msg-text', '');
    // 等待提示：模型慢或连不上时，界面上必须一直有东西在动，不能是一片空白。
    var waiting = el('div', 'muted waiting-status', '已发送，正在连接模型…');
    assistantBubble.appendChild(assistantText);
    assistantBubble.appendChild(waiting);
    assistantNode.appendChild(assistantBubble);
    appendToChat(assistantNode);

    setStreaming(true);
    state.abortRequested = false;
    return streamChat(sessionId, text, assistantText, assistantNode, waiting);
  }).catch(function (error) {
    setStreaming(false);
    toast(error.message || '发送失败', 'err');
    appendChatCard(el('div', 'notice err', '发送失败：' + (error.message || '未知错误')));
  });
}

/* 出错时给一个重试入口：把原文再发一次，而不是让用户重新手打。 */
function appendRetryCard(text, reason) {
  var card = el('div', 'notice err');
  card.appendChild(el('span', '', reason + ' '));
  var button = el('button', 'btn btn-small', '重试');
  button.type = 'button';
  button.onclick = function () {
    if (card.parentNode) card.parentNode.removeChild(card);
    sendMessage(text);
  };
  card.appendChild(button);
  // 这里必须用模块级的 appendToChat：appendChatCard 是 streamChat 的局部函数，
  // 在外面调用会抛 "appendChatCard is not defined"，把真正的错误信息顶掉。
  appendToChat(card);
}

function streamChat(sessionId, message, assistantText, assistantNode, waiting) {
  var controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
  state.streamAbort = controller;

  // ⚠️ 这些必须在 .then/.catch 之外定义：下面的错误分支也要用它们。
  // 之前它们写在 .then 回调内部，于是任何错误都会先抛
  // "Can not find variable: stopStreaming"，把真正的错误提示吞掉。
  var assistantBubble = assistantNode ? assistantNode.querySelector('.bubble') : null;
  var watchdog = null;
  var finished = false;

  function clearWaiting() {
    if (waiting && waiting.parentNode) waiting.parentNode.removeChild(waiting);
    waiting = null;
  }

  function stopStreaming() {
    if (watchdog) { clearInterval(watchdog); watchdog = null; }
    if (assistantBubble) assistantBubble.classList.remove('streaming');
    clearWaiting();
  }

  // Tool cards / approvals / errors are siblings of the message bubble — the
  // stylesheet gives them their own margins inside .chat-list.
  function appendChatCard(node) {
    if (assistantNode && assistantNode.parentNode) assistantNode.parentNode.insertBefore(node, assistantNode);
    else appendToChat(node);
  }

  return apiFetch('/api/chat', {
    method: 'POST',
    headers: { 'Accept': 'text/event-stream' },
    body: { sessionId: sessionId, message: message, stream: true },
    signal: controller ? controller.signal : undefined
  }).then(function (response) {
    if (!response.ok) {
      return response.text().then(function (text) {
        throw apiErrorFrom(response.status, text);
      });
    }
    if (!response.body || !response.body.getReader) {
      // 极端兜底：没有流式能力时退回整段读取
      return response.text().then(function (text) {
        assistantText.textContent = text;
      });
    }

    var reader = response.body.getReader();
    var decoder = new TextDecoder('utf-8');
    var buffer = '';
    var pendingRender = null;
    var content = '';
    var pendingText = '';
    var lastActivity = Date.now();   // 任何字节到达都算活跃（含心跳注释）
    var firstOutput = false;
    var sawDone = false;

    // 守护进程每 10 秒发一次心跳，所以"45 秒一个字节都没有"只可能是连接死了
    // （iagentd 崩溃/被杀/被挂起）。这种情况以前会默默停住什么都不显示，现在必须报错。
    watchdog = setInterval(function () {
      var idle = Math.round((Date.now() - lastActivity) / 1000);
      if (!firstOutput && waiting) waiting.textContent = '已发送，等待模型响应… ' + idle + 's';
      if (idle >= 45 && !finished) {
        finished = true;
        stopStreaming();
        try { if (controller) controller.abort(); } catch (e) {}
        appendRetryCard(message, '连接中断：' + idle + ' 秒没有收到任何数据。iagentd 可能崩溃或被挂起' +
          '（看 /var/mobile/Library/iAgent/logs/iagentd.err.log 与 iagent.log）。');
        toast('连接中断', 'err');
      }
    }, 1000);

    function flushText() {
      if (pendingRender) return;
      pendingRender = setTimeout(function () {
        pendingRender = null;
        assistantText.textContent = content;
        scrollChatToBottom();
      }, 60);
    }

    function handleEvent(eventName, dataText) {
      var payload = {};
      if (dataText) { try { payload = JSON.parse(dataText); } catch (e) { payload = { text: dataText }; } }

      if (eventName === 'delta') {
        pendingText += payload.text || '';
        content = pendingText;
        flushText();
      } else if (eventName === 'reason') {
        var reasonBox = assistantNode.querySelector('.reason-box');
        if (!reasonBox) {
          reasonBox = el('div', 'reason-box');
          reasonBox.appendChild(el('div', 'reason-title', '推理过程'));
          reasonBox.appendChild(el('div', 'reason-text', ''));
          assistantNode.querySelector('.bubble').insertBefore(reasonBox, assistantNode.querySelector('.bubble').firstChild);
        }
        reasonBox.querySelector('.reason-text').textContent += payload.text || '';
        scrollChatToBottom();
      } else if (eventName === 'tool_call') {
        appendChatCard(renderToolCard({ id: payload.id, name: payload.name, arguments: payload.arguments }, null));
        scrollChatToBottom();
      } else if (eventName === 'tool_result') {
        var existing = document.querySelector('.toolcard[data-call="' + payload.id + '"]');
        // tool_result 事件只带状态和输出，参数要从已渲染的卡片里沿用，否则
        // 重新渲染后命令就消失了。
        var args = payload.arguments;
        var name = payload.name;
        if (existing) {
          if (args == null) {
            var argsNode = existing.querySelector('.toolcard-args');
            if (argsNode) args = argsNode.textContent;
          }
          if (!name) {
            var nameNode = existing.querySelector('.toolcard-name');
            if (nameNode) name = nameNode.textContent;
          }
        }
        var replacement = renderToolCard({ id: payload.id, name: name, arguments: args }, payload);
        if (existing && existing.parentNode) existing.parentNode.replaceChild(replacement, existing);
        else appendChatCard(replacement);
        scrollChatToBottom();
      } else if (eventName === 'approval_required') {
        appendChatCard(renderApprovalCard(payload));
        scrollChatToBottom();
      } else if (eventName === 'done') {
        sawDone = true;
        if (pendingRender) { clearTimeout(pendingRender); pendingRender = null; }
        assistantText.textContent = content;
        stopStreaming();
        // 空回复也算"有响应"，但要说清楚，不能让人以为是卡住了
        if (!content.length) {
          appendChatCard(el('div', 'notice', '模型返回了空内容（没有文本也没有工具调用）。' +
            '通常是模型名不对、接口返回了非流式格式，或该模型不支持当前请求参数。'));
        }
        state.messages.push({ role: 'assistant', content: content, createdAt: Date.now() / 1000 });
        loadSessions(true);
      } else if (eventName === 'error') {
        firstOutput = true;
        appendRetryCard(message, (payload.message || '模型返回错误') + '');
        stopStreaming();
      }
    }

    function markOutput() {
      lastActivity = Date.now();
      if (!firstOutput) { firstOutput = true; clearWaiting(); }
    }

    function pump() {
      return reader.read().then(function (chunk) {
        lastActivity = Date.now();
        if (chunk.done) {
          if (pendingRender) { clearTimeout(pendingRender); pendingRender = null; }
          assistantText.textContent = content;
          stopStreaming();
          // 流结束了却没有 done 事件 = daemon 半路没了。以前这里什么都不显示。
          if (!sawDone && !finished) {
            finished = true;
            appendRetryCard(message, '连接被提前关闭：没有收到结束标记（daemon 可能崩溃/被杀，' +
              '或模型连接中断）。内容可能不完整。');
          }
          return;
        }
        buffer += decoder.decode(chunk.value, { stream: true });
        var separator = buffer.indexOf('\n\n');
        while (separator >= 0) {
          var raw = buffer.slice(0, separator);
          buffer = buffer.slice(separator + 2);
          var eventName = 'message';
          var dataLines = [];
          var lines = raw.split('\n');
          for (var i = 0; i < lines.length; i++) {
            var line = lines[i].replace(/\r$/, '');
            if (line.indexOf(':') === 0) continue;              // 注释/心跳
            if (line.indexOf('event:') === 0) eventName = line.slice(6).trim();
            else if (line.indexOf('data:') === 0) dataLines.push(line.slice(5).trim());
          }
          if (dataLines.length) {
            if (eventName !== 'done' && eventName !== 'error') markOutput();
            handleEvent(eventName, dataLines.join('\n'));
          }
          separator = buffer.indexOf('\n\n');
        }
        return pump();
      });
    }

    return pump();
  }).catch(function (error) {
    if (error && error.name === 'AbortError') {
      stopStreaming();
      // 看门狗已经报过错了就别再说"已停止生成"，否则像用户自己点的停止
      if (!finished && assistantBubble) assistantBubble.appendChild(el('div', 'muted', '已停止生成'));
      return;
    }
    stopStreaming();
    if (assistantBubble) assistantBubble.appendChild(el('div', 'muted', '连接中断'));
    appendChatCard(el('div', 'notice err', '连接中断：' + (error.message || '未知错误')));
    toast('连接中断', 'err');
  }).then(function () {
    setStreaming(false);
    state.streamAbort = null;
  });
}

function abortStream() {
  if (state.streamAbort && !state.abortRequested) {
    state.abortRequested = true;
    if (state.sessionId) {
      api('/api/abort', { method: 'POST', body: { sessionId: state.sessionId } }).catch(function () {});
    }
    try { state.streamAbort.abort(); } catch (e) { /* ignore */ }
  }
}

function loadSessionMessages(sessionId) {
  return api('/api/sessions/' + encodeURIComponent(sessionId)).then(function (session) {
    state.sessionId = session.id;
    localStorage.setItem('iag_last_session', session.id);
    state.messages = session.messages || [];
    renderMessages();
    updateChatHeader();
  }).catch(function (error) {
    toast('加载会话失败：' + error.message, 'err');
    state.sessionId = '';
    localStorage.removeItem('iag_last_session');
    state.messages = [];
    renderMessages();
    updateChatHeader();
  });
}

function newSession() {
  return api('/api/sessions', { method: 'POST', body: {} }).then(function (session) {
    state.sessions.unshift(session);
    state.sessionId = session.id;
    localStorage.setItem('iag_last_session', session.id);
    state.messages = [];
    renderMessages();
    updateChatHeader();
    switchPage('chat');
    var input = $('chat-input');
    if (input) input.focus();
  }).catch(function (error) {
    toast('新建会话失败：' + error.message, 'err');
  });
}

/* ==========================================================================
 * 终端
 * ========================================================================== */

/* --- 最小 ANSI 终端模拟器 ------------------------------------------------- */

function TerminalEmulator() {
  this.lines = [[]];        // 每行是 [{t: 文本, c: 类名}] 的片段数组
  this.row = 0;
  this.col = 0;             // 以字符计
  this.currentClass = '';
  this.maxChars = 20000;
  this.totalChars = 0;
  this._pending = '';       // 跨轮询被截断的转义序列
}

TerminalEmulator.prototype._line = function () {
  if (!this.lines[this.row]) this.lines[this.row] = [];
  return this.lines[this.row];
};

TerminalEmulator.prototype._lineLength = function (row) {
  var line = this.lines[row] || [];
  var length = 0;
  for (var i = 0; i < line.length; i++) length += line[i].t.length;
  return length;
};

TerminalEmulator.prototype._put = function (ch) {
  var line = this._line();
  var index = 0, consumed = 0;
  while (index < line.length && consumed + line[index].t.length <= this.col) {
    consumed += line[index].t.length;
    index++;
  }
  if (consumed < this.col && index < line.length) {
    // 插入到片段中间
    var offset = this.col - consumed;
    var piece = line[index];
    line.splice(index, 1,
      { t: piece.t.slice(0, offset), c: piece.c },
      { t: ch, c: this.currentClass },
      { t: piece.t.slice(offset), c: piece.c });
    // 合并同色片段
    for (var k = line.length - 1; k > 0; k--) {
      if (line[k].c === line[k - 1].c && line[k].t.length && line[k - 1].t.length) {
        line[k - 1] = { t: line[k - 1].t + line[k].t, c: line[k].c };
        line.splice(k, 1);
      }
    }
  } else if (line.length && line[line.length - 1].c === this.currentClass) {
    line[line.length - 1].t += ch;
  } else {
    line.push({ t: ch, c: this.currentClass });
  }
  this.col++;
  this.totalChars++;
  if (this.totalChars > this.maxChars) this._trim();
};

TerminalEmulator.prototype._trim = function () {
  while (this.totalChars > this.maxChars && this.lines.length > 1) {
    var removed = this.lines.shift();
    for (var i = 0; i < removed.length; i++) this.totalChars -= removed[i].t.length;
    if (this.row > 0) this.row--;
  }
};

TerminalEmulator.prototype._newline = function () {
  this.row++;
  if (!this.lines[this.row]) this.lines[this.row] = [];
  this.col = 0;
  if (this.lines.length > 3000) {
    var removed = this.lines.shift();
    for (var i = 0; i < removed.length; i++) this.totalChars -= removed[i].t.length;
    this.row--;
  }
};

TerminalEmulator.prototype._clearLineFromCursor = function () {
  var line = this._line();
  var index = 0, consumed = 0;
  while (index < line.length && consumed + line[index].t.length <= this.col) {
    consumed += line[index].t.length;
    index++;
  }
  // offset = 光标落在 line[index] 内部的偏移；这一截必须保留。
  var offset = this.col - consumed;
  var removed = 0;
  if (offset > 0 && index < line.length) {
    removed += line[index].t.length - offset;
    line[index] = { t: line[index].t.slice(0, offset), c: line[index].c };
    index++;
  }
  for (var k = index; k < line.length; k++) removed += line[k].t.length;
  line.splice(index, line.length - index);
  this.totalChars -= removed;
  if (this.totalChars < 0) this.totalChars = 0;
};

TerminalEmulator.prototype._clearScreenFromCursor = function () {
  // \x1b[0J：从光标清到屏幕末尾（当前行尾部 + 下方所有行）。
  this._clearLineFromCursor();
  for (var r = this.row + 1; r < this.lines.length; r++) {
    var line = this.lines[r] || [];
    for (var i = 0; i < line.length; i++) this.totalChars -= line[i].t.length;
  }
  this.lines.length = this.row + 1;
  if (this.totalChars < 0) this.totalChars = 0;
};

TerminalEmulator.prototype._clearScreen = function () {
  this.lines = [[]];
  this.row = 0;
  this.col = 0;
  this.totalChars = 0;
};

TerminalEmulator.prototype._sgr = function (params) {
  var classes = [];
  if (this.currentClass) classes = this.currentClass.split(' ').filter(Boolean);
  var fgColors = {
    30: 'black', 31: 'red', 32: 'green', 33: 'yellow', 34: 'blue',
    35: 'magenta', 36: 'cyan', 37: 'white',
    90: 'bright-black', 91: 'bright-red', 92: 'bright-green', 93: 'bright-yellow',
    94: 'bright-blue', 95: 'bright-magenta', 96: 'bright-cyan', 97: 'bright-white'
  };

  for (var i = 0; i < params.length; i++) {
    var code = params[i];
    if (code === 0 || code === '') { classes = []; }
    else if (code === 1) { if (classes.indexOf('ansi-bold') < 0) classes.push('ansi-bold'); }
    else if (code === 2) { if (classes.indexOf('ansi-dim') < 0) classes.push('ansi-dim'); }
    else if (code === 3) { if (classes.indexOf('ansi-italic') < 0) classes.push('ansi-italic'); }
    else if (code === 4) { if (classes.indexOf('ansi-underline') < 0) classes.push('ansi-underline'); }
    else if (code === 7) { if (classes.indexOf('ansi-inverse') < 0) classes.push('ansi-inverse'); }
    else if (code === 22) { classes = classes.filter(function (c) { return c !== 'ansi-bold' && c !== 'ansi-dim'; }); }
    else if (code === 23) { classes = classes.filter(function (c) { return c !== 'ansi-italic'; }); }
    else if (code === 24) { classes = classes.filter(function (c) { return c !== 'ansi-underline'; }); }
    else if (code === 27) { classes = classes.filter(function (c) { return c !== 'ansi-inverse'; }); }
    else if (code === 39) { classes = classes.filter(function (c) { return c.indexOf('ansi-fg-') !== 0; }); }
    else if (code === 49) { classes = classes.filter(function (c) { return c.indexOf('ansi-bg-') !== 0; }); }
    else if (fgColors[code]) {
      classes = classes.filter(function (c) { return c.indexOf('ansi-fg-') !== 0; });
      classes.push('ansi-fg-' + fgColors[code]);
    } else if (code >= 40 && code <= 47) {
      var bg = ['black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white'][code - 40];
      classes = classes.filter(function (c) { return c.indexOf('ansi-bg-') !== 0; });
      classes.push('ansi-bg-' + bg);
    } else if (code >= 100 && code <= 107) {
      var bg2 = ['black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white'][code - 100];
      classes = classes.filter(function (c) { return c.indexOf('ansi-bg-') !== 0; });
      classes.push('ansi-bg-bright-' + bg2);
    }
  }
  this.currentClass = classes.join(' ');
};

TerminalEmulator.prototype.write = function (text) {
  if (!text && !this._pending) return;
  // 转义序列经常被轮询切成两半，先把上一轮的残片接回来。
  if (this._pending) { text = this._pending + (text || ''); this._pending = ''; }
  var i = 0;
  while (i < text.length) {
    var ch = text.charAt(i);

    if (ch === '\u001b') {
      var rest = text.slice(i);
      var match = /^\u001b\[([0-9;?]*)([A-Za-z])/.exec(rest) || /^\u001b\]([^\u0007]*)\u0007/.exec(rest);
      if (match) {
        if (match[2]) {
          var params = match[1] ? match[1].split(';').map(function (p) { return p === '' ? 0 : parseInt(p, 10); }) : [0];
          var command = match[2];
          if (command === 'm') this._sgr(params);
          else if (command === 'J') {
            if (params[0] === 2 || params[0] === 3) this._clearScreen();
            else if (params[0] === 1) this._clearLineFromCursor();
            else this._clearScreenFromCursor();
          } else if (command === 'K') this._clearLineFromCursor();
          else if (command === 'H' || command === 'f') {
            this.row = Math.max(0, (params[0] || 1) - 1);
            this.col = Math.max(0, (params[1] || 1) - 1);
            while (this.lines.length <= this.row) this.lines.push([]);
          } else if (command === 'A') this.row = Math.max(0, this.row - (params[0] || 1));
          else if (command === 'B') this.row = Math.min(this.lines.length, this.row + (params[0] || 1));
          else if (command === 'C') this.col += (params[0] || 1);
          else if (command === 'D') this.col = Math.max(0, this.col - (params[0] || 1));
          else if (command === 'G') this.col = Math.max(0, (params[0] || 1) - 1);
          // 其它序列安全丢弃
          i += match[0].length;
          continue;
        }
        i += match[0].length;
        continue;
      }
      // ESC ( ) # % 开头的是三字节序列（字符集/字体选择），必须整体吃掉，
      // 否则 vim / less 的 \x1b(B 会在终端里留下 "(B" 这样的脏字符。
      var second = rest.charAt(1);
      if (second === '(' || second === ')' || second === '#' || second === '%') {
        if (rest.length < 3) { this._pending = rest; break; }
        i += 3;
        continue;
      }
      // 不完整的转义序列（数据被截断）→ 缓存到下一轮，绝不能当普通文本打出来
      if (rest === '\u001b' || /^\u001b\[[0-9;?]*$/.test(rest) || /^\u001b\][^\u0007]*$/.test(rest)) {
        this._pending = rest.length > 64 ? '' : rest;
        break;
      }
      // 未知转义：丢弃 ESC 与其后的 '['/''
      i += (rest.charAt(1) === '[' || rest.charAt(1) === ']') ? 2 : 1;
      continue;
    }

    if (ch === '\n') { this._newline(); i++; continue; }
    if (ch === '\r') { this.col = 0; i++; continue; }
    if (ch === '\b') { this.col = Math.max(0, this.col - 1); i++; continue; }
    if (ch === '\t') {
      var spaces = 8 - (this.col % 8);
      for (var s = 0; s < spaces; s++) this._put(' ');
      i++;
      continue;
    }
    if (ch === '\u0007') { i++; continue; }   // 响铃，忽略
    if (ch < ' ') { i++; continue; }           // 其它控制字符丢弃

    this._put(ch);
    i++;
  }
};

TerminalEmulator.prototype.toHTML = function () {
  // .term-out .tl is display:inline, so one <div class="tl"> per line joined
  // with "\n" reproduces the terminal grid.
  var out = [];
  for (var r = 0; r < this.lines.length; r++) {
    var line = this.lines[r] || [];
    var html = '';
    for (var i = 0; i < line.length; i++) {
      var piece = line[i];
      html += piece.c ? '<span class="' + piece.c + '">' + esc(piece.t) + '</span>' : esc(piece.t);
    }
    out.push('<div class="tl">' + (html || '&nbsp;') + '</div>');
  }
  return out.join('\n');
};

TerminalEmulator.prototype.clear = function () { this._clearScreen(); };

/* --- 终端交互 ------------------------------------------------------------ */

function termMeasure() {
  var out = $('term-out');
  if (!out) return { cols: 80, rows: 24 };
  var probe = el('span', 'mono');
  probe.style.cssText = 'position:absolute;visibility:hidden;white-space:pre;';
  probe.textContent = 'MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM';
  document.body.appendChild(probe);
  var charWidth = probe.getBoundingClientRect().width / 40 || 8.4;
  var charHeight = probe.getBoundingClientRect().height || 17;
  document.body.removeChild(probe);
  var scroller = $('term-scroll');
  var cols = Math.max(20, Math.floor((scroller.clientWidth - 12) / charWidth));
  var rows = Math.max(6, Math.floor((scroller.clientHeight - 8) / charHeight));
  return { cols: cols, rows: rows };
}

function renderTerminal() {
  var out = $('term-out');
  if (!out || !state.term.emulator) return;
  var scroller = $('term-scroll');
  var atBottom = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 60;
  out.innerHTML = state.term.emulator.toHTML();
  if (atBottom) scroller.scrollTop = scroller.scrollHeight;
}

var renderTerminalTimer = null;
function renderTerminalThrottled() {
  if (renderTerminalTimer) return;
  renderTerminalTimer = setTimeout(function () {
    renderTerminalTimer = null;
    renderTerminal();
  }, 80);
}

function startTerminalPolling() {
  if (state.term.timer) return;
  state.term.timer = setInterval(function () {
    if (document.hidden) return;
    var session = state.term.current;
    if (!session) return;
    api('/api/term/read?sessionId=' + encodeURIComponent(session) + '&since=' + state.term.cursor)
      .then(function (data) {
        if (data.cursor != null) state.term.cursor = data.cursor;
        if (data.data) {
          state.term.emulator.write(data.data);
          renderTerminalThrottled();
        }
        if (data.alive === false) {
          // 终端已退出：立刻停止轮询，否则会 300ms 一次永远问下去。
          stopTerminalPolling();
          if (!state.term.exited) {
            state.term.exited = true;
            state.term.emulator.write('\n[终端已退出' + (data.exitCode != null ? '（exit ' + data.exitCode + '）' : '') + ']\n');
            renderTerminal();
          }
          updateTermChips();
        }
      })
      .catch(function () { /* 轮询失败静默 */ });
  }, 300);
}

function stopTerminalPolling() {
  if (state.term.timer) {
    clearInterval(state.term.timer);
    state.term.timer = null;
  }
}

function openTerminal() {
  var shell = $('term-shell') ? $('term-shell').value : '';
  var size = termMeasure();
  return api('/api/term/open', { method: 'POST', body: { cols: size.cols, rows: size.rows, shell: shell } })
    .then(function (session) {
      state.term.current = session.sessionId;
      state.term.cursor = 0;
      state.term.exited = false;
      state.term.emulator = new TerminalEmulator();
      renderTerminal();
      startTerminalPolling();
      updateTermChips();
      toast('已创建终端 ' + session.sessionId + ' (pid ' + session.pid + ')', 'ok');
      var hidden = $('term-hidden');
      if (hidden) hidden.focus();
    })
    .catch(function (error) {
      toast('创建终端失败：' + error.message, 'err');
    });
}

function switchTerminal(sessionId) {
  state.term.current = sessionId;
  state.term.cursor = 0;
  state.term.exited = false;
  state.term.emulator = new TerminalEmulator();
  renderTerminal();
  updateTermChips();
  // 上一个会话可能已退出（轮询被停掉），切回来必须重新开始拉取。
  if (state.activePage === 'term') startTerminalPolling();
}

function closeTerminal() {
  var session = state.term.current;
  if (!session) return;
  api('/api/term/close', { method: 'POST', body: { sessionId: session } }).catch(function () {});
  state.term.current = null;
  state.term.cursor = 0;
  state.term.emulator = new TerminalEmulator();
  renderTerminal();
  updateTermChips();
}

function updateTermChips() {
  var host = $('term-sessions');
  if (!host) return;
  api('/api/term/list').then(function (list) {
    state.term.sessions = list || [];
    clear(host);
    if (!state.term.sessions.length) { hide(host); return; }
    show(host);
    for (var i = 0; i < state.term.sessions.length; i++) {
      (function (session) {
        var chip = el('button', 'term-chip' + (session.sessionId === state.term.current ? ' active' : '') + (session.alive ? '' : ' dead'),
          session.sessionId + (session.alive ? '' : ' ✕'));
        chip.type = 'button';
        chip.onclick = function () { switchTerminal(session.sessionId); };
        host.appendChild(chip);
      })(state.term.sessions[i]);
    }
  }).catch(function () {});
}

function sendTermInput(data) {
  var session = state.term.current;
  if (!session || !data) return;
  api('/api/term/input', { method: 'POST', body: { sessionId: session, data: data } }).catch(function () {});
}

function handleTermKey(key) {
  var map = {
    'ctrl-c': '\u0003', 'ctrl-d': '\u0004', 'tab': '\t',
    'up': '\u001b[A', 'down': '\u001b[B', 'esc': '\u001b'
  };
  if (key === 'clear') {
    if (state.term.emulator) { state.term.emulator.clear(); renderTerminal(); }
    return;
  }
  if (map[key]) sendTermInput(map[key]);
}

function runQuickCommand() {
  var input = $('term-quick');
  var output = $('term-quick-out');
  var command = input.value.trim();
  if (!command) return;
  output.textContent = '执行中…';
  show(output);
  api('/api/exec', { method: 'POST', body: { command: command } }).then(function (result) {
    var text = '$ ' + command + '\n' + 'exit=' + result.exitCode + ' (' + fmtDuration(result.durationMs) + ')\n';
    if (result.stdout) text += result.stdout;
    if (result.stderr) text += '\n[stderr]\n' + result.stderr;
    output.textContent = text;
  }).catch(function (error) {
    output.textContent = '执行失败：' + error.message;
  });
}

/* ==========================================================================
 * 工具与定时任务
 * ========================================================================== */

function loadTools() {
  return api('/api/tools').then(function (payload) {
    state.tools = (payload && payload.tools) || [];
    renderToolsList();
  }).catch(function (error) {
    toast('加载工具失败：' + error.message, 'err');
  });
}

function renderToolsList() {
  var host = $('tools-list');
  if (!host) return;
  clear(host);
  if (!state.tools.length) { host.appendChild(el('div', 'empty', '没有可用工具')); return; }
  for (var i = 0; i < state.tools.length; i++) {
    (function (tool) {
      var item = el('button', 'tool-chip' + (state.selectedTool === tool.name ? ' active' : ''));
      item.type = 'button';
      item.appendChild(el('span', 'tool-chip-label', tool.name));
      if (tool.dangerous) item.appendChild(el('span', 'danger-dot'));
      if (tool.enabled === false) item.appendChild(el('span', 'muted', '已关闭'));
      item.title = tool.description || '';
      item.onclick = function () { selectTool(tool); };
      host.appendChild(item);
    })(state.tools[i]);
  }
}

function selectTool(tool) {
  state.selectedTool = tool.name;
  renderToolsList();
  var host = $('tools-detail');
  clear(host);

  host.appendChild(el('div', 'tool-name', tool.name));
  host.appendChild(el('div', 'tool-desc', tool.description || ''));
  if (tool.dangerous) host.appendChild(el('div', 'tag-danger', '该工具会修改设备状态，调用前请确认'));

  var schema = tool.parameters || {};
  var properties = schema.properties || {};
  var required = schema.required || [];
  var inputs = {};

  Object.keys(properties).forEach(function (key) {
    var spec = properties[key] || {};
    var field = el('label', 'field');
    var label = el('span', 'label', key);
    if (required.indexOf(key) >= 0) label.appendChild(el('span', 'tag-required', ' *'));
    field.appendChild(label);

    var input;
    if (spec.enum) {
      input = document.createElement('select');
      input.className = 'input mono';
      var emptyOption = document.createElement('option');
      emptyOption.value = '';
      emptyOption.textContent = '（未设置）';
      input.appendChild(emptyOption);
      spec.enum.forEach(function (value) {
        var option = document.createElement('option');
        option.value = String(value);
        option.textContent = String(value);
        input.appendChild(option);
      });
    } else if (spec.type === 'boolean') {
      // .switch 本身是 opacity:0 的隐藏控件，必须紧跟一个 .switch-ui 才看得见。
      input = document.createElement('input');
      input.type = 'checkbox';
      input.className = 'switch';
      var switchUI = document.createElement('i');
      switchUI.className = 'switch-ui';
      input.__iagSwitchUI = switchUI;
    } else if (spec.type === 'integer' || spec.type === 'number') {
      input = document.createElement('input');
      input.type = 'number';
      input.className = 'input mono';
    } else if (spec.type === 'object' || spec.type === 'array') {
      input = document.createElement('textarea');
      input.className = 'mono';
      input.rows = 3;
      input.placeholder = 'JSON';
    } else {
      input = document.createElement('input');
      input.type = 'text';
      input.className = 'input mono';
    }
    input.setAttribute('autocapitalize', 'off');
    input.setAttribute('autocorrect', 'off');
    input.setAttribute('spellcheck', 'false');
    field.appendChild(input);
    if (input.__iagSwitchUI) field.appendChild(input.__iagSwitchUI);
    if (spec.description) field.appendChild(el('span', 'hint', spec.description));
    host.appendChild(field);
    inputs[key] = { node: input, spec: spec };
  });

  var runButton = el('button', 'btn btn-primary btn-block', '调用工具');
  runButton.type = 'button';
  host.appendChild(runButton);

  var resultBox = el('div', 'result-box');
  hide(resultBox);
  host.appendChild(resultBox);

  runButton.onclick = function () {
    var args = {};
    var jsonError = false;
    Object.keys(inputs).forEach(function (key) {
      var entry = inputs[key];
      var node = entry.node;
      var spec = entry.spec;
      if (spec.type === 'boolean') { args[key] = !!node.checked; return; }
      var raw = node.value;
      if (raw === '' || raw == null) return;
      if (spec.type === 'integer') args[key] = parseInt(raw, 10);
      else if (spec.type === 'number') args[key] = parseFloat(raw);
      else if (spec.type === 'object' || spec.type === 'array') {
        try { args[key] = JSON.parse(raw); } catch (e) {
          toast(key + ' 不是合法 JSON', 'err');
          jsonError = true;
        }
      } else args[key] = raw;
    });
    if (jsonError) { runButton.disabled = false; return; }

    runButton.disabled = true;
    resultBox.textContent = '调用中…';
    show(resultBox);
    var started = Date.now();
    api('/api/tools/call', { method: 'POST', body: { name: tool.name, arguments: args } })
      .then(function (result) {
        var duration = result.durationMs != null ? result.durationMs : (Date.now() - started);
        clear(resultBox);
        var head = el('div', 'result-head ' + (result.ok ? 'ok' : 'fail'));
        head.appendChild(el('span', 'pill ' + (result.ok ? 'ok' : 'fail'), result.ok ? '成功' : '失败'));
        head.appendChild(el('span', 'muted', fmtDuration(duration)));
        resultBox.appendChild(head);
        resultBox.appendChild(el('pre', 'output-pre', result.ok ? (result.output || '(无输出)') : (result.error || '失败')));
      })
      .catch(function (error) {
        clear(resultBox);
        resultBox.appendChild(el('div', 'notice err', error.message));
      })
      .then(function () { runButton.disabled = false; });
  };
}

function loadCron() {
  return api('/api/cron').then(function (list) {
    state.cron = list || [];
    renderCron();
  }).catch(function (error) {
    toast('加载定时任务失败：' + error.message, 'err');
  });
}

function renderCron() {
  var host = $('cron-list');
  if (!host) return;
  clear(host);
  if (!state.cron.length) { host.appendChild(el('div', 'empty', '暂无定时任务')); return; }
  for (var i = 0; i < state.cron.length; i++) {
    (function (task) {
      var item = el('div', 'cron-item');
      var top = el('div', 'cron-top');
      top.appendChild(el('span', 'cron-sched mono', task.schedule));
      top.appendChild(el('span', 'pill ' + (task.enabled ? 'ok' : ''), task.enabled ? '启用' : '暂停'));
      var removeButton = el('button', 'btn btn-sm btn-danger-ghost', '删除');
      removeButton.type = 'button';
      removeButton.onclick = function () {
        confirmModal('删除定时任务', '确定删除 ' + task.id + '？删除后无法恢复。', '删除', true, function () {
          api('/api/cron/' + encodeURIComponent(task.id), { method: 'DELETE' })
            .then(function () { loadCron(); toast('已删除', 'ok'); })
            .catch(function (error) { toast(error.message, 'err'); });
        });
      };
      top.appendChild(removeButton);
      item.appendChild(top);
      item.appendChild(el('pre', 'cron-cmd code-block', task.command));
      var meta = 'id ' + task.id +
        ' · 上次 ' + (task.lastRun ? fmtTime(task.lastRun) : '未运行') +
        ' · 下次 ' + (task.nextRun ? fmtTime(task.nextRun) : '—');
      item.appendChild(el('div', 'cron-meta', meta));
      if (task.lastResult) item.appendChild(el('div', 'cron-meta muted', task.lastResult));
      host.appendChild(item);
    })(state.cron[i]);
  }
}

function addCron() {
  var schedule = $('cron-schedule').value.trim();
  var command = $('cron-command').value.trim();
  var enabled = $('cron-enabled').checked;
  if (!schedule || !command) { toast('请填写调度表达式与命令', 'err'); return; }
  api('/api/cron', { method: 'POST', body: { schedule: schedule, command: command, enabled: enabled } })
    .then(function () {
      toast('已添加定时任务', 'ok');
      $('cron-command').value = '';
      loadCron();
    })
    .catch(function (error) { toast('添加失败：' + error.message, 'err'); });
}

/* ==========================================================================
 * 会话
 * ========================================================================== */

function loadSessions(silent) {
  return api('/api/sessions').then(function (list) {
    state.sessions = list || [];
    renderSessions();
    updateChatHeader();
  }).catch(function (error) {
    if (!silent) toast('加载会话列表失败：' + error.message, 'err');
  });
}

function renderSessions() {
  var host = $('sessions-list');
  if (!host) return;
  clear(host);
  if (!state.sessions.length) { host.appendChild(el('div', 'empty', '还没有会话')); return; }
  for (var i = 0; i < state.sessions.length; i++) {
    (function (session) {
      var item = el('div', 'session-item' + (session.id === state.sessionId ? ' current' : ''));
      var main = el('div', 'session-main');
      main.appendChild(el('div', 'session-title', session.title || '未命名会话'));
      main.appendChild(el('div', 'session-meta',
        (session.messageCount || 0) + ' 条消息 · ' + fmtTime(session.updatedAt)));
      item.appendChild(main);

      var actions = el('div', 'session-actions');
      var openButton = el('button', 'btn btn-sm', '打开');
      openButton.type = 'button';
      openButton.onclick = function () {
        loadSessionMessages(session.id).then(function () { switchPage('chat'); });
      };
      var renameButton = el('button', 'btn btn-sm', '重命名');
      renameButton.type = 'button';
      renameButton.onclick = function () {
        promptModal('会话标题', session.title || '', '输入新的标题', function (title) {
          if (title == null) return;
          api('/api/sessions/' + encodeURIComponent(session.id), { method: 'PATCH', body: { title: title } })
            .then(function () { loadSessions(true); })
            .catch(function (error) { toast(error.message, 'err'); });
        });
      };
      var deleteButton = el('button', 'btn btn-sm btn-danger-ghost', '删除');
      deleteButton.type = 'button';
      deleteButton.onclick = function () {
        confirmModal('删除会话', '删除「' + (session.title || session.id) + '」？该会话的全部对话记录会被移除。', '删除', true, function () {
          api('/api/sessions/' + encodeURIComponent(session.id), { method: 'DELETE' })
          .then(function () {
            if (state.sessionId === session.id) {
              state.sessionId = '';
              localStorage.removeItem('iag_last_session');
              state.messages = [];
              renderMessages();
              updateChatHeader();
            }
            loadSessions(true);
            toast('已删除', 'ok');
          })
          .catch(function (error) { toast(error.message, 'err'); });
        });
      };
      actions.appendChild(openButton);
      actions.appendChild(renameButton);
      actions.appendChild(deleteButton);
      item.appendChild(actions);
      host.appendChild(item);
    })(state.sessions[i]);
  }
}

/* ==========================================================================
 * 设置
 * ========================================================================== */

var SETTINGS_FIELDS = [
  { id: 'set-baseUrl', key: 'baseUrl', type: 'string' },
  { id: 'set-model', key: 'model', type: 'string' },
  { id: 'set-maxTokens', key: 'maxTokens', type: 'number' },
  { id: 'set-temperature', key: 'temperature', type: 'number' },
  { id: 'set-systemPrompt', key: 'systemPrompt', type: 'string' },
  { id: 'set-port', key: 'port', type: 'number' },
  { id: 'set-shellTimeout', key: 'shellTimeout', type: 'number' },
  { id: 'set-workDir', key: 'workDir', type: 'string' },
  { id: 'set-maxSteps', key: 'maxSteps', type: 'number' }
];

var TOOL_SWITCHES = ['shell', 'file', 'app', 'notify', 'cron', 'ui', 'http'];

function loadConfig() {
  return api('/api/config').then(function (config) {
    state.config = config;
    state.configOriginal = JSON.parse(JSON.stringify(config));
    fillConfig(config);
    hide($('set-loading'));
    show($('set-model-card'));
    show($('set-run-card'));
    show($('set-tools-card'));
    show($('set-security-card'));
    show($('set-diag-card'));
    show($('set-savebar'));
    checkHealth(true);
  }).catch(function (error) {
    toast('加载配置失败：' + error.message, 'err');
  });
}

function fillConfig(config) {
  SETTINGS_FIELDS.forEach(function (field) {
    var node = $(field.id);
    if (!node) return;
    node.value = config[field.key] == null ? '' : config[field.key];
  });
  var tempValue = $('set-temperature-val');
  if (tempValue) tempValue.textContent = Number(config.temperature == null ? 0.3 : config.temperature).toFixed(1);

  var keyInput = $('set-apiKey');
  if (keyInput) {
    keyInput.value = '';
    keyInput.placeholder = config.hasApiKey
      ? ('已配置：' + (config.apiKeyMasked || '****') + '（留空表示不修改）')
      : '未设置（留空表示不修改）';
  }
  var keyHint = $('set-apiKey-hint');
  if (keyHint) keyHint.textContent = config.hasApiKey ? ('当前：' + (config.apiKeyMasked || '')) : '当前未配置 API Key';

  var tokenInput = $('set-authToken');
  if (tokenInput) tokenInput.value = '';

  var reading = config.requestLogging === true;
  if ($('set-requestLogging')) $('set-requestLogging').checked = reading;

  var tools = config.toolsEnabled || {};
  TOOL_SWITCHES.forEach(function (name) {
    var node = $('set-tool-' + name);
    if (node) node.checked = tools[name] !== false;
  });

  var radios = document.querySelectorAll('input[name=set-approval]');
  for (var i = 0; i < radios.length; i++) {
    radios[i].checked = radios[i].value === (config.approvalMode || 'dangerous');
  }
}

function collectConfigPatch() {
  var patch = {};
  var original = state.configOriginal || {};

  SETTINGS_FIELDS.forEach(function (field) {
    var node = $(field.id);
    if (!node) return;
    var current = field.type === 'number' ? Number(node.value) : node.value;
    var previous = field.type === 'number' ? Number(original[field.key]) : original[field.key];
    if (field.type === 'number' && (node.value === '' || isNaN(current))) return;
    if (current !== previous) patch[field.key] = current;
  });

  var tools = {};
  var toolsChanged = false;
  var originalTools = original.toolsEnabled || {};
  TOOL_SWITCHES.forEach(function (name) {
    var node = $('set-tool-' + name);
    if (!node) return;
    if (!!node.checked !== (originalTools[name] !== false)) toolsChanged = true;
  });
  if (toolsChanged) {
    TOOL_SWITCHES.forEach(function (name) {
      var node = $('set-tool-' + name);
      if (node) tools[name] = !!node.checked;
    });
    patch.toolsEnabled = tools;
  }

  if ($('set-requestLogging') && $('set-requestLogging').checked !== (original.requestLogging === true)) {
    patch.requestLogging = $('set-requestLogging').checked;
  }

  var radios = document.querySelectorAll('input[name=set-approval]');
  for (var i = 0; i < radios.length; i++) {
    if (radios[i].checked && radios[i].value !== (original.approvalMode || 'dangerous')) {
      patch.approvalMode = radios[i].value;
    }
  }

  var keyInput = $('set-apiKey');
  if (keyInput && keyInput.value.trim() !== '') patch.apiKey = keyInput.value.trim();

  var tokenInput = $('set-authToken');
  if (tokenInput) {
    var tokenValue = tokenInput.value.trim();
    var storedToken = original.authToken || '';
    if (tokenValue !== '') {
      if (tokenValue !== storedToken) patch.authToken = tokenValue;
    } else if (storedToken !== '') {
      // 空 = 不修改，所以清空必须显式提交 __CLEAR__。
      patch.authToken = '__CLEAR__';
    }
  }

  return patch;
}

function saveConfig() {
  var patch = collectConfigPatch();
  if (!Object.keys(patch).length) { toast('没有需要保存的改动'); return; }

  var button = $('set-save');
  if (button) button.disabled = true;

  api('/api/config', { method: 'POST', body: patch }).then(function (config) {
    if (patch.authToken != null) {
      if (patch.authToken === '__CLEAR__') {
        state.token = '';
        localStorage.removeItem('iag_token');
      } else {
        state.token = patch.authToken;
        localStorage.setItem('iag_token', patch.authToken);
      }
    }
    state.config = config;
    state.configOriginal = JSON.parse(JSON.stringify(config));
    fillConfig(config);
    toast('已保存', 'ok');
    if (patch.port != null) toast('端口改动需要重启 daemon 后生效', 'err');
    checkHealth(true);
  }).catch(function (error) {
    toast('保存失败：' + error.message, 'err');
  }).then(function () {
    if (button) button.disabled = false;
  });
}

function clearApiKey() {
  confirmModal('清除 API Key', '清除后需要重新填写才能调用模型，确定继续？', '清除', true, function () {
    api('/api/config', { method: 'POST', body: { apiKey: '__CLEAR__' } }).then(function (config) {
      state.config = config;
      state.configOriginal = JSON.parse(JSON.stringify(config));
      fillConfig(config);
      toast('已清除 API Key', 'ok');
      checkHealth(true);
    }).catch(function (error) {
      toast('清除失败：' + error.message, 'err');
    });
  });
}

function renderDiag() {
  var host = $('diag-grid');
  if (!host) return;
  var health = state.health;
  clear(host);
  if (!health) { host.appendChild(el('div', 'empty', '无法获取状态')); return; }

  var device = health.device || {};
  var model = health.model || {};
  var bridge = health.bridge || {};
  var pairs = [
    ['版本', health.version || '—'],
    ['运行时长', (health.uptimeSec != null ? Math.round(health.uptimeSec) + ' 秒' : '—')],
    ['设备', (device.model || '—') + ' · iOS ' + (device.systemVersion || '?')],
    ['越狱根目录', health.jbRoot || '—'],
    ['运行身份', health.runningAsRoot ? 'root' : 'mobile'],
    ['模型', (model.model || '—') + (model.hasKey ? '' : '（无 Key）')],
    ['Base URL', model.baseUrl || '—'],
    ['会话数', String(health.sessions != null ? health.sessions : '—')],
    ['终端数', String(health.terminalSessions != null ? health.terminalSessions : '—')],
    ['SpringBoard 桥接', bridge.connected ? '已连接' : '未连接'],
    ['HTTP 端口', health.http && health.http.port ? String(health.http.port) : '—'],
    ['累计请求', health.http && health.http.totalRequests != null ? String(health.http.totalRequests) : '—']
  ];

  pairs.forEach(function (pair) {
    host.appendChild(el('div', 'diag-key', pair[0]));
    host.appendChild(el('div', 'diag-val', pair[1]));
  });
}

function openLogs() {
  var modal = $('logs-modal');
  show(modal);
  loadLogs();
}

function loadLogs() {
  var host = $('logs-content');
  if (host) host.textContent = '加载中…';
  api('/api/logs?lines=250').then(function (payload) {
    var lines = (payload && payload.lines) || [];
    if (host) host.textContent = lines.length ? lines.join('\n') : '(日志为空)';
    if (host) host.scrollTop = host.scrollHeight;
  }).catch(function (error) {
    if (host) host.textContent = '加载日志失败：' + error.message;
  });
}

/* ==========================================================================
 * 事件绑定与启动
 * ========================================================================== */

function bindEvents() {
  var tabs = document.querySelectorAll('#tabbar .tab');
  for (var i = 0; i < tabs.length; i++) {
    (function (tab) {
      tab.onclick = function () { switchPage(tab.getAttribute('data-tab')); };
    })(tabs[i]);
  }

  // 聊天
  $('chat-send').onclick = sendMessage;
  $('chat-new').onclick = newSession;
  $('chat-stop').onclick = abortStream;
  bindChatScroll();

  var input = $('chat-input');
  input.addEventListener('input', function () {
    input.style.height = 'auto';
    input.style.height = Math.min(input.scrollHeight, 6 * 24 + 16) + 'px';
  });
  input.addEventListener('keydown', function (event) {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      sendMessage();
    }
  });

  // 终端
  $('term-new').onclick = openTerminal;
  $('term-close').onclick = closeTerminal;
  $('term-quick-run').onclick = runQuickCommand;
  $('term-quick').addEventListener('keydown', function (event) {
    if (event.key === 'Enter') { event.preventDefault(); runQuickCommand(); }
  });

  var keybar = $('term-keybar');
  if (keybar) {
    keybar.addEventListener('click', function (event) {
      var target = event.target;
      if (target && target.getAttribute && target.getAttribute('data-key')) {
        handleTermKey(target.getAttribute('data-key'));
      }
    });
  }

  var hidden = $('term-hidden');
  if (hidden) {
    hidden.addEventListener('input', function () {
      var value = hidden.value;
      hidden.value = '';
      if (value) sendTermInput(value);
    });
    hidden.addEventListener('keydown', function (event) {
      var special = {
        Enter: '\r', Backspace: '\u007f', Tab: '\t', Escape: '\u001b',
        ArrowUp: '\u001b[A', ArrowDown: '\u001b[B', ArrowRight: '\u001b[C', ArrowLeft: '\u001b[D'
      };
      if (event.ctrlKey && event.key && event.key.length === 1) {
        var code = event.key.toUpperCase().charCodeAt(0) - 64;
        if (code > 0 && code < 32) { event.preventDefault(); sendTermInput(String.fromCharCode(code)); return; }
      }
      if (special[event.key]) {
        event.preventDefault();
        hidden.value = '';
        sendTermInput(special[event.key]);
      }
    });
  }

  var scroller = $('term-scroll');
  if (scroller) {
    scroller.addEventListener('click', function () {
      if (state.term.current && hidden) hidden.focus();
    });
  }

  // 软键盘弹出与旋转会连着触发几十次 resize，必须防抖。
  var resizeTimer = null;
  function resizeTerminalDebounced() {
    if (resizeTimer) clearTimeout(resizeTimer);
    resizeTimer = setTimeout(function () { resizeTimer = null; resizeTerminal(); }, 300);
  }
  window.addEventListener('orientationchange', resizeTerminalDebounced);
  window.addEventListener('resize', resizeTerminalDebounced);
  document.addEventListener('visibilitychange', function () {
    if (document.hidden) stopTerminalPolling();
    else if (state.activePage === 'term') startTerminalPolling();
  });

  // 工具
  $('tools-refresh').onclick = loadTools;
  $('cron-refresh').onclick = loadCron;
  $('cron-add').onclick = addCron;

  // 会话
  $('sessions-new').onclick = newSession;
  $('sessions-refresh').onclick = function () { loadSessions(); };

  // 设置
  $('set-reload').onclick = loadConfig;
  $('set-save').onclick = saveConfig;
  $('set-apiKey-clear').onclick = clearApiKey;
  $('set-temperature').addEventListener('input', function () {
    $('set-temperature-val').textContent = Number($('set-temperature').value).toFixed(1);
  });
  $('diag-refresh').onclick = function () { checkHealth(); };
  $('diag-logs').onclick = openLogs;
  $('logs-refresh').onclick = loadLogs;

  var closers = document.querySelectorAll('[data-close]');
  for (var c = 0; c < closers.length; c++) {
    (function (node) {
      node.onclick = function () { hide($('logs-modal')); };
    })(closers[c]);
  }
}

function resizeTerminal() {
  var session = state.term.current;
  if (!session) return;
  var size = termMeasure();
  api('/api/term/resize', { method: 'POST', body: { sessionId: session, cols: size.cols, rows: size.rows } })
    .catch(function () {});
}

function boot() {
  // The SpringBoard tweak opens the panel with ?token=… so the page can adopt an
  // access token without the user typing it.
  try {
    var params = new URLSearchParams(location.search);
    var queryToken = params.get('token');
    if (queryToken) {
      state.token = queryToken;
      localStorage.setItem('iag_token', queryToken);
      params.delete('token');
      var rest = params.toString();
      history.replaceState(null, '', location.pathname + (rest ? '?' + rest : '') + location.hash);
    }
  } catch (e) { /* 老浏览器不支持 URLSearchParams 时忽略 */ }

  bindEvents();
  state.term.emulator = new TerminalEmulator();
  switchPage('chat');

  checkHealth(true);
  setInterval(function () { checkHealth(true); }, 15000);

  loadSessions(true).then(function () {
    if (state.sessionId) return loadSessionMessages(state.sessionId);
    // 没有历史会话时保持空白页
    renderMessages();
    updateChatHeader();
  });

  loadTools();
  loadCron();
  updateTermChips();
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
else boot();

})();
