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
  // 守护进程在线状态机：unknown（还没测过/正在测）/ up / down
  daemon: {
    status: 'unknown',
    failCount: 0,
    failSince: 0,
    lastProbeAt: 0,
    lastOkAt: 0,
    lastError: '',
    lastPid: null,
    lastRestarts: null,
    lastVersion: '',
    lastStartedAt: null,
    lastCrashKey: '',
    lastExitClean: null,
    offlineNoticeShown: false,
    pollTimer: null,
    probing: false,
    streamStartPid: null,
    streamStartRestarts: null
  },
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
 * 健康检查（守护进程存活检测）
 *
 * 参数约定（与守护进程 /api/health 契约一致）：
 *   pid / startedAt / restarts / lastCrash{at,signal,detail} / lastExitClean
 *
 * 轮询策略：
 *   · 页面可见时每 5 秒探一次；页面隐藏时降到每 15 秒（省电，WKWebView 后台本来也会被限流）。
 *   · 单次失败不翻脸（守护进程重启的瞬间必然失败一次），连续失败 2 次才判定掉线。
 *   · 页面从隐藏恢复可见时立刻补测一次。
 *   · 所有定时器都挂在 state.daemon.pollTimer / visibilityTimer 上，可被 stopHealthPolling 清理。
 *
 * 注意：本文件是 ES5 风格，不要用 let/const/箭头函数/模板字符串。
 * ========================================================================== */

var HEALTH_INTERVAL_VISIBLE = 5000;     // 可见时的轮询间隔
var HEALTH_INTERVAL_HIDDEN = 15000;     // 隐藏时的轮询间隔
var HEALTH_FAIL_THRESHOLD = 2;          // 连续失败几次判定掉线
var HEALTH_DETAIL_LIMIT = 1400;         // 崩溃日志详情截断长度

var CRASH_LOG_PATH = '/var/mobile/Library/iAgent/logs/iagentd-crash.log';

function pad2(n) { return n < 10 ? '0' + n : '' + n; }

/* 时:分:秒，用于「最后检测 12:34:56」 */
function clockTime(ts) {
  if (!ts) return '—';
  var d = new Date(ts);
  return pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds());
}

/* 「3 秒前 / 2 分钟前」 */
function relTime(fromMs, toMs) {
  if (!fromMs) return '';
  var seconds = Math.round(((toMs || Date.now()) - fromMs) / 1000);
  if (seconds < 0) seconds = 0;
  if (seconds < 60) return seconds + ' 秒前';
  if (seconds < 3600) return Math.round(seconds / 60) + ' 分钟前';
  if (seconds < 86400) return Math.round(seconds / 3600) + ' 小时前';
  return Math.round(seconds / 86400) + ' 天前';
}

/* 截断长日志，保留尾部（崩溃原因一般在最后几行） */
function truncateDetail(text, limit) {
  var value = String(text == null ? '' : text);
  var max = limit || HEALTH_DETAIL_LIMIT;
  if (value.length <= max) return value;
  return '…（已截断，仅保留最后 ' + max + ' 字符）\n' + value.slice(value.length - max);
}

/* 供测试注入替身（测试里不能真发网络请求）。 */
var probeHealthForClose = null;
/* 测试可覆写成 function (suffix) {} 来断言补进卡片的文案。 */
var announceDaemonClose = function (summary) { finalizeCloseReport(summary); };

/* 状态：检测中（灰点）。注意不要在这里动 .daemon-offline：
   掉线期间每 5 秒都会重测一次，如果重测时把降级状态清掉，输入框会一闪一闪。 */
function setConnChecking() {
  var dot = $('conn-dot');
  var text = $('conn-label');
  if (dot) dot.className = 'conn-dot';
  if (text) text.textContent = state.daemon.status === 'down'
    ? '掉线（重试中…）' : '检测中…';
  var labelNode = $('conn-label-box');
  if (labelNode) labelNode.title = '正在检测守护进程…（点这里立刻重测）';
}

/* 一次探测结束后把徽标同步回真实状态。
   没有这一步的话，探测开始时的「检测中」会一直挂着到下一次轮询。 */
function syncConnBadge() {
  if (state.daemon.status === 'down') setConn(false, '掉线');
  else if (state.daemon.status === 'up') setConn(true, '在线');
  else setConnChecking();
}

/* 状态：在线（绿点）/ 掉线（红点），标题里带最后检测时间与版本 */
function setConn(ok, label) {
  var daemon = state.daemon;
  var dot = $('conn-dot');
  var text = $('conn-label');
  var version = (state.health && state.health.version) || daemon.lastVersion || '';
  var when = daemon.lastProbeAt ? clockTime(daemon.lastProbeAt) : '—';
  var title = (ok ? '守护进程在线' : '守护进程无响应') +
    '\n最后检测：' + when + '（' + relTime(daemon.lastProbeAt) + '）' +
    '\n版本：' + (version ? 'v' + version : '未知') +
    (daemon.lastPid ? '\npid：' + daemon.lastPid : '') +
    (daemon.lastRestarts != null ? '\n累计重启：' + daemon.lastRestarts + ' 次' : '') +
    (ok ? '' : '\n最近错误：' + (daemon.lastError || '连接失败')) +
    '\n点这里立刻重测';
  var labelNode = $('conn-label-box');
  if (dot) dot.className = 'conn-dot ' + (ok ? 'ok' : 'bad');
  // conn-label-box 是包住「圆点 + 文字」的容器：绝不能给它赋 textContent，
  // 那会把圆点一起清掉（它就消失了）。文字写 conn-label，标题写容器。
  if (text) text.textContent = label;
  if (labelNode) labelNode.title = title;
  else if (text) text.title = title;
  // 掉线时整页降级（CSS 用来灰掉输入区），不依赖具体元素
  var app = $('app');
  if (app) {
    if (ok) app.classList.remove('daemon-offline');
    else app.classList.add('daemon-offline');
  }
}

/* 从健康快照里摘出我们关心的字段（兼容旧版 daemon：字段缺失一律当未知） */
function healthSnapshot(health) {
  health = health || {};
  var crash = health.lastCrash || null;
  return {
    pid: (typeof health.pid === 'number') ? health.pid : null,
    restarts: (typeof health.restarts === 'number') ? health.restarts : null,
    version: health.version || '',
    startedAt: (typeof health.startedAt === 'number') ? health.startedAt : null,
    crash: crash,
    crashKey: crash ? String(crash.at || '') + '|' + String(crash.signal || '') : '',
    exitClean: (health.lastExitClean === true || health.lastExitClean === false) ? health.lastExitClean : null
  };
}

/* 「守护进程已重启」信息卡片 —— 用户最想知道的就是它为什么没了 */
function appendRestartNotice(snapshot) {
  var text = '守护进程已重启（第 ' + (snapshot.restarts != null ? snapshot.restarts : '?') + ' 次）。' +
    '上次可能是崩溃或被系统杀掉。' +
    (snapshot.pid != null ? '（新 pid ' + snapshot.pid + '）' : '');
  var card = el('div', 'notice info daemon-notice');
  card.appendChild(el('div', 'notice-title', text));

  if (snapshot.crash) {
    card.appendChild(el('div', 'notice-line',
      '崩溃信号：' + (snapshot.crash.signal || '未知') +
      (snapshot.crash.at ? '（' + clockTime(snapshot.crash.at * 1000) + '）' : '')));
    var detail = snapshot.crash.detail;
    if (detail) {
      var details = el('details', 'notice-details');
      details.appendChild(el('summary', 'notice-summary', '查看崩溃日志最后几行'));
      details.appendChild(el('pre', 'notice-pre', truncateDetail(detail)));
      card.appendChild(details);
    }
    card.appendChild(el('div', 'notice-path', '完整日志：' + CRASH_LOG_PATH));
  } else if (snapshot.exitClean === false) {
    card.appendChild(el('div', 'notice-line',
      '上一次没有干净退出（可能是被系统杀掉，例如内存不足），没有留下崩溃信号。'));
  } else {
    card.appendChild(el('div', 'notice-line',
      '上一次没有留下崩溃记录（可能是正常退出后又被拉起，例如重启 SpringBoard 或重装插件）。'));
  }

  appendToChat(card);
  return card;
}

/* 掉线横幅：常驻在聊天页顶部（不是 toast，不会被几秒后吃掉） */
function daemonOfflineBannerText() {
  var seconds = state.daemon.failSince
    ? Math.max(0, Math.round((Date.now() - state.daemon.failSince) / 1000)) : 0;
  return '守护进程未运行（未响应 /api/health）' +
    (seconds > 0 ? '，已经 ' + seconds + ' 秒' : '') +
    '。正在自动重试…如果一直这样，去 Sileo 里确认插件已安装，或重启一次 SpringBoard。' +
    '（也可以下拉刷新 / 点右上角状态重测）';
}

function updateChatBanner() {
  var banner = $('chat-banner');
  if (!banner) return;
  var daemon = state.daemon;
  var health = state.health;
  clear(banner);
  banner.onclick = null;
  banner.style.cursor = '';

  if (daemon.status === 'down') {
    banner.appendChild(el('span', 'banner-text', daemonOfflineBannerText()));
    hide(banner);
    show(banner);
    return;
  }

  var needKey = daemon.status === 'up' && health && health.model && health.model.hasKey === false;
  if (needKey) {
    banner.appendChild(el('span', 'banner-text', '尚未配置模型 API Key，点击前往设置'));
    banner.onclick = function () { switchPage('settings'); };
    banner.style.cursor = 'pointer';
    show(banner);
    return;
  }

  hide(banner);
}

function updateModelCheckAvailability() {
  var showList = $('model-list-btn');
  var test = $('model-check-btn');
  if (showList && !showList.getAttribute('data-busy')) showList.disabled = false;
  if (test && !test.getAttribute('data-busy')) test.disabled = false;
}

function daemonOffline() { return state.daemon.status === 'down'; }

/* 掉线期间禁止发消息：发送按钮禁用 + 输入框提示，免得又攒出一条「连接被提前关闭」。 */
function setSendDisabled(offline) {
  var send = $('chat-send');
  var input = $('chat-input');
  if (send) send.disabled = !!(offline || state.streaming);
  if (input) {
    input.disabled = !!offline;
    input.placeholder = offline ? '守护进程未运行，暂时无法发送消息' : '输入消息…';
  }
}

function applyDaemonStatus(status) {
  if (status === 'down') {
    setConn(false, '掉线');
    setSendDisabled(true);
    updateChatBanner();
    // 掉线期间正在流式输出的消息必须终止，否则会一直空转到看门狗超时
    if (state.streaming) {
      var aborted = abortStream();
      if (!aborted) toast('守护进程已掉线，本次回复已中断', 'err');
    }
  } else if (status === 'up') {
    setConn(true, '在线');
    setSendDisabled(false);
    updateChatBanner();
  } else {
    setConnChecking();
  }
}

function daemonDown() {
  var daemon = state.daemon;
  if (!daemon.failSince) daemon.failSince = Date.now();
  if (!daemon.offlineNoticeShown) {
    daemon.offlineNoticeShown = true;
    // 掉线提示用常驻横幅表达，不用 toast；只在「由在线转掉线」时播报一次。
    toast('守护进程未响应', 'err');
  }
}

function healthUp(health) {
  var daemon = state.daemon;
  daemon.failCount = 0;
  daemon.failSince = 0;
  daemon.lastOkAt = Date.now();
  daemon.lastError = '';
  daemon.offlineNoticeShown = false;
  state.health = health;

  var snapshot = healthSnapshot(health);
  var previousPid = daemon.lastPid;
  var previousRestarts = daemon.lastRestarts;
  // 重启判定：pid 变了（pid 缺失时退化为看 restarts 是否增加）
  var pidChanged = (previousPid != null && snapshot.pid != null && previousPid !== snapshot.pid);
  var restartsGrew = (previousRestarts != null && snapshot.restarts != null && snapshot.restarts > previousRestarts);
  var isRestart = pidChanged || (previousPid == null && restartsGrew);

  daemon.lastPid = snapshot.pid;
  daemon.lastRestarts = snapshot.restarts;
  daemon.lastVersion = snapshot.version;
  daemon.lastStartedAt = snapshot.startedAt;
  daemon.lastExitClean = snapshot.exitClean;
  if (snapshot.crashKey) daemon.lastCrashKey = snapshot.crashKey;

  // 先把状态机翻到「在线」，这样随后 appendToChat 触发的滚动/回调里
  // 不会再看到「掉线」的旧状态。
  var wasDown = (daemon.status === 'down');
  daemon.status = 'up';
  applyDaemonStatus('up');

  if (isRestart) appendRestartNotice(snapshot);

  // 掉线 → 在线：给一张轻量卡片，让用户确认「回来了」
  if (wasDown) {
    var back = el('div', 'notice ok daemon-notice');
    back.appendChild(el('div', 'notice-title',
      '守护进程已恢复响应' + (snapshot.pid != null ? '（pid ' + snapshot.pid + '）' : '') +
      '，可以继续发送消息了。'));
    appendToChat(back);
  }

  var ver = $('appbar-ver');
  if (ver) ver.textContent = 'v' + (snapshot.version || '');
  renderDiag();
}

function healthDown(error) {
  var daemon = state.daemon;
  daemon.failCount += 1;
  daemon.lastError = (error && error.message) ? error.message : '无法连接';
  if (daemon.failCount >= HEALTH_FAIL_THRESHOLD && daemon.status !== 'down') {
    daemon.status = 'down';
    daemonDown();
    applyDaemonStatus('down');
  } else if (daemon.status === 'down') {
    // 已经判定掉线：只刷新横幅里的「已经 N 秒」，不重复提示
    updateChatBanner();
  } else {
    // 单次抖动不翻脸，但状态徽标要如实显示「正在重试」
    setConnChecking();
  }
}

function probeHealthNow(silent) {
  var daemon = state.daemon;
  daemon.probing = true;
  // 已经判定掉线时保持红点 + 横幅，不要在每次重试时闪回「检测中」
  if (daemon.status !== 'down') setConnChecking();
  return api('/api/health').then(function (health) {
    daemon.probing = false;
    daemon.lastProbeAt = Date.now();
    healthUp(health);
    syncConnBadge();
    return health;
  }).catch(function (error) {
    daemon.probing = false;
    daemon.lastProbeAt = Date.now();
    healthDown(error);
    syncConnBadge();
    if (!silent) toast('守护进程无响应：' + (error && error.message ? error.message : ''), 'err');
    return null;
  });
}

/* 交互式重测：设置页「刷新状态」、诊断按钮、点状态徽标走这里 */
function checkHealth(silent) { return probeHealthNow(silent === true); }

/* 单次轮询：走状态机（失败计数 / 重启检测），供定时器和测试调用 */
function pollHealthOnce() { return probeHealthNow(true); }

function healthPollInterval() {
  return document.hidden ? HEALTH_INTERVAL_HIDDEN : HEALTH_INTERVAL_VISIBLE;
}

function startHealthPolling() {
  var daemon = state.daemon;
  stopHealthPolling();
  daemon.pollTimer = setInterval(function () { pollHealthOnce(); }, healthPollInterval());
}

function stopHealthPolling() {
  var daemon = state.daemon;
  if (daemon.pollTimer) { clearInterval(daemon.pollTimer); daemon.pollTimer = null; }
}

/* 页面隐藏时放慢、恢复可见时立即补测一次并恢复频率 */
function handleVisibilityChange() {
  if (document.hidden) {
    if (state.daemon.pollTimer) startHealthPolling();
    return;
  }
  startHealthPolling();
  pollHealthOnce();
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
  setSendDisabled(daemonOffline());
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
  // 守护进程掉线时直接挡住：再发一条只会再收到一次「连接被提前关闭」
  if (daemonOffline()) {
    toast('守护进程未运行，暂时发不了消息', 'err');
    updateChatBanner();
    return;
  }
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

/* 流在没有 done/error 的情况下结束时的补充说明。
   同步拼一段写进错误卡片，同时异步拉一次 /api/health：
   如果守护进程真的重启过，就把 pid/restarts/lastCrash 如实带出来；
   如果它根本没重启，就不能冤枉它 —— 问题在模型连接或本次会话被主动关闭。 */
function daemonCloseHint() {
  // 必须用「本次流开始之前」记下的 pid/restarts 做对比：
  // 定时轮询会在流进行期间更新 state.daemon，如果等到流结束再读就永远比不出重启。
  var previousPid = state.daemon.streamStartPid;
  var previousRestarts = state.daemon.streamStartRestarts;
  var closedAt = Date.now();
  if (typeof probeHealthForClose === 'function') {
    // 替身可能返回 Promise（测试注入）；失败不能变成 unhandled rejection
    settleQuietly(probeHealthForClose(previousPid, previousRestarts, closedAt));
  } else {
    fallbackHealthProbe(previousPid, previousRestarts, closedAt);
  }
  return ' 正在确认守护进程状态…';
}

/* 吞掉一个可选 Promise 的失败，避免 unhandled rejection 打断真正的提示 */
function settleQuietly(result) {
  if (result && typeof result.catch === 'function') {
    result.catch(function () { reportCloseFailed(); });
  }
}

/* 异步补充失败也不能影响已经呈现的提示卡片 */
function reportCloseFailed() {
  try { announceDaemonClose(null); } catch (e) { /* 兜底：文案都拼不出来就只能算了 */ }
}

/* 异步体检结束：判断是不是「刚重启」，返回给调用方补进错误卡片。
   fresh：本次探到的健康快照；previous*：流开始之前记住的值。 */
function finishCloseReport(fresh, previousPid, previousRestarts, closedAt) {
  if (!fresh) return null;
  var snapshot = healthSnapshot(fresh);
  var pidChanged = (previousPid != null && snapshot.pid != null && previousPid !== snapshot.pid);
  var restartsGrew = (previousRestarts != null && snapshot.restarts != null &&
    snapshot.restarts > previousRestarts);
  // 流的生命周期很短：进程启动时间在本次流开始之后，就一定是在流期间重启的
  var startedDuringStream = false;
  if (snapshot.startedAt && closedAt) {
    startedDuringStream = (snapshot.startedAt * 1000) >= (closedAt - 120000);
  }
  return {
    pid: snapshot.pid,
    restarts: snapshot.restarts,
    lastPid: previousPid,
    lastCrash: snapshot.crash,
    lastExitClean: snapshot.exitClean,
    recentMs: snapshot.startedAt ? snapshot.startedAt * 1000 : null,
    justRestarted: pidChanged || restartsGrew || startedDuringStream
  };
}

/* 生产环境兜底：直接拉一次 /api/health（带超时） */
function fallbackHealthProbe(previousPid, previousRestarts, closedAt) {
  var announce = makeCloseAnnouncer();
  var controller = (typeof AbortController !== 'undefined') ? new AbortController() : null;
  var timeout = setTimeout(function () {
    if (controller) { try { controller.abort(); } catch (e) {} }
    announce(null);
  }, 4000);
  apiFetch('/api/health', { signal: controller ? controller.signal : undefined })
    .then(function (response) {
      if (!response.ok) throw new Error('HTTP ' + response.status);
      return response.text();
    })
    .then(function (text) {
      clearTimeout(timeout);
      var health = null;
      try { health = JSON.parse(text); } catch (e) { health = null; }
      announce(finishCloseReport(health, previousPid, previousRestarts, closedAt));
    })
    .catch(function () {
      clearTimeout(timeout);
      announce(null);
    });
}

/* 把「连接提前关闭」的原因补进最后一张错误卡片（尽量不打断用户阅读）。 */
function finalizeCloseReport(summary) {
  var cards = document.querySelectorAll('#chat-list .notice.err');
  var card = cards && cards.length ? cards[cards.length - 1] : null;
  var prefix = ' 正在确认守护进程状态…';
  var text = daemonCloseSuffix(summary);
  if (!card) { appendToChat(el('div', 'notice err', text.replace(/^\s+/, ''))); return; }
  var span = card.firstChild;
  if (span && span.textContent && span.textContent.indexOf(prefix) >= 0) {
    span.textContent = span.textContent.replace(prefix, text);
  } else {
    card.appendChild(el('div', 'notice-line', text.replace(/^\s+/, '')));
  }
  scrollChatToBottom();
}

/* 一次「确认守护进程状态」只允许补一次说明：无论超时先到还是响应先到 */
function makeCloseAnnouncer() {
  var announced = false;
  return function (summary) {
    if (announced) return;
    announced = true;
    announceDaemonClose(summary);
  };
}

/* summary 为 null 表示健康检查也没连上（守护进程大概真的没了） */
function daemonCloseSuffix(summary) {
  if (!summary) {
    return ' 守护进程现在也没有响应 /api/health，基本可以确定它挂掉或被系统杀掉了。' +
      '恢复后会显示「守护进程已重启」，上面会带上崩溃信号与日志路径。';
  }

  var now = Date.now();
  var pidText = summary.pid != null ? ('pid ' + summary.pid) : 'pid 未知';

  if (summary.justRestarted) {
    var text = ' 守护进程刚刚重启过（第 ' + (summary.restarts != null ? summary.restarts : '?') + ' 次）';
    if (summary.lastPid != null && summary.pid != null && summary.lastPid !== summary.pid) {
      text += '，pid 从 ' + summary.lastPid + ' 变成了 ' + summary.pid;
    }
    if (summary.recentMs != null) text += '，就在 ' + relTime(now - summary.recentMs, now);
    if (summary.lastCrash) {
      text += '，崩溃信号 ' + (summary.lastCrash.signal || '未知') +
        (summary.lastCrash.at ? '（' + clockTime(summary.lastCrash.at * 1000) + '）' : '');
      text += ' — 详见 ' + CRASH_LOG_PATH + '（设置 → 诊断 → 查看日志也能看）';
      if (summary.lastCrash.detail) {
        text += '。日志最后几行：' + truncateDetail(summary.lastCrash.detail, 240);
      }
    } else if (summary.lastExitClean === false) {
      text += '，上一次没有干净退出（可能是被系统杀掉，例如内存不足）';
    }
    return text + '。本次回复已中断。';
  }

  return ' 守护进程仍在运行（' + pidText +
    (summary.restarts != null ? '，累计重启 ' + summary.restarts + ' 次' : '') +
    '）：是模型连接中断，或守护进程主动关闭了本次会话。' +
    '可以点「重试」再发一次，或先到设置里点「测试模型」确认模型端点是否可用。';
}

function streamChat(sessionId, message, assistantText, assistantNode, waiting) {
  var controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
  state.streamAbort = controller;
  // 记下本次流开始时的守护进程身份，流结束时用来判断「它是不是中途重启过」
  state.daemon.streamStartPid = state.daemon.lastPid;
  state.daemon.streamStartRestarts = state.daemon.lastRestarts;

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
    var sawDone = false;             // 收到 done 事件 = 正常收尾
    var sawError = false;            // 收到 error 事件 = 守护进程正常返回了错误，也算正常收尾
    var sawAnyEvent = false;         // 收到过任何业务事件（含 0.5 字节的 delta）

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
        sawError = true;   // 守护进程正常返回了错误并收尾，不要再报「连接被提前关闭」
        appendRetryCard(message, (payload.message || '模型返回错误') + '');
        stopStreaming();
      }
    }

    function markOutput() {
      lastActivity = Date.now();
      sawAnyEvent = true;
      if (!firstOutput) { firstOutput = true; clearWaiting(); }
    }

    function pump() {
      return reader.read().then(function (chunk) {
        lastActivity = Date.now();
        if (chunk.done) {
          if (pendingRender) { clearTimeout(pendingRender); pendingRender = null; }
          assistantText.textContent = content;
          stopStreaming();
          // 流结束了却没有 done / error 事件 = daemon 半路没了，或者模型连接被中断。
          // ⚠️ 如果收到过 error 事件（例如守护进程正常返回「HTTP 401 API Key 无效」），
          // 流的结束就是正常收尾，绝不能再叠加一条「守护进程可能崩溃」的吓人提示。
          if (!sawDone && !sawError && !sawAnyEvent && !finished) {
            finished = true;
            appendRetryCard(message, '连接被提前关闭：守护进程没有返回结束标记，也没有返回任何内容' +
              '（可能刚启动就被杀掉，或模型接口不可用）。内容可能不完整。' + daemonCloseHint());
          } else if (!sawDone && !sawError && !finished) {
            finished = true;
            appendRetryCard(message, '连接被提前关闭：没有收到结束标记，内容可能不完整。' +
              daemonCloseHint());
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

/* 返回 true 表示本次确实中断了一条正在输出的流（调用方据此决定要不要提示用户） */
function abortStream() {
  if (state.streamAbort && !state.abortRequested) {
    state.abortRequested = true;
    if (state.sessionId) {
      api('/api/abort', { method: 'POST', body: { sessionId: state.sessionId } }).catch(function () {});
    }
    try { state.streamAbort.abort(); } catch (e) { /* ignore */ }
    return true;
  }
  return false;
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

/* ==========================================================================
 * 模型检测（设置页「测试模型」/「拉取模型列表」）
 *
 * 契约：
 *   POST /api/model/check  body: {baseUrl?, apiKey?, model?}（缺省用 daemon 当前配置）
 *                          永远 HTTP 200，返回 {ok, verdict, hint, models, steps[]}
 *   GET  /api/models       返回 {ok, models[], error}
 * 两个接口都请求「表单里当前填写的值」，用户不必先保存就能验证。
 * ========================================================================== */

function setButtonBusy(button, busy, busyText, idleText) {
  if (!button) return;
  button.disabled = !!busy;
  button.textContent = busy ? busyText : idleText;
  if (busy) button.setAttribute('data-busy', '1');
  else button.removeAttribute('data-busy');
}

/* 收集要发给 /api/model/check 的覆盖值。
   API Key 留空 = 不发送该字段（表示「沿用 daemon 已保存的 Key」）。 */
function collectModelProbe() {
  var body = {};
  var baseUrl = $('set-baseUrl');
  var model = $('set-model');
  var apiKey = $('set-apiKey');
  if (baseUrl && baseUrl.value.trim() !== '') body.baseUrl = baseUrl.value.trim();
  if (model && model.value.trim() !== '') body.model = model.value.trim();
  if (apiKey && apiKey.value.trim() !== '') body.apiKey = apiKey.value.trim();
  return body;
}

/* 「名称 (信号)」里出现的步骤名——unknown(step) 是约定俗成的提示键，不需要特殊处理。 */
function renderModelCheck(report) {
  var host = $('model-check-result');
  if (!host) return;
  clear(host);
  report = report || {};

  var verdictText = report.verdict || (report.ok ? '模型可用' : '模型不可用');
  var head = el('div', 'model-check-head');
  head.appendChild(el('div', 'model-verdict ' + (report.ok ? 'ok' : 'bad'), verdictText));
  if (report.hint) head.appendChild(el('div', 'model-hint', report.hint));
  host.appendChild(head);

  var steps = report.steps || [];
  var list = el('div', 'model-steps');
  steps.forEach(function (step) {
    step = step || {};
    var ok = step.ok === true;
    var executed = (step.detail && String(step.detail).indexOf('未执行') === 0) ? false : true;
    var row = el('div', 'model-step ' + (ok ? 'ok' : (executed ? 'fail' : 'skip')));
    row.appendChild(el('span', 'model-step-mark', ok ? '✓' : (executed ? '✗' : '○')));
    var body = el('div', 'model-step-body');
    var title = el('div', 'model-step-name', step.name || '（未命名步骤）');
    if (step.ms != null) title.appendChild(el('span', 'model-step-ms', fmtDuration(step.ms)));
    body.appendChild(title);
    if (step.detail) body.appendChild(el('div', 'model-step-detail', String(step.detail)));
    row.appendChild(body);
    list.appendChild(row);
  });
  host.appendChild(list);

  // 用户自定义中转端点最常见的问题：返回 200 但没有 SSE 数据。
  // 只在确实相关时才提示，避免刷屏。
  var haystack = verdictText + ' ' + (report.hint || '') + ' ';
  for (var i = 0; i < steps.length; i++) {
    if (steps[i] && steps[i].detail) haystack += steps[i].detail + ' ';
  }
  if (/SSE|流式/.test(haystack) && !report.ok) {
    var warn = el('div', 'notice-warn model-sse-warn');
    warn.appendChild(el('div', 'notice-line',
      '端点返回了 HTTP 200，但流式对话没有收到 SSE 数据（可能不支持 stream:true）。' +
      '常见的自建中转/反代（nginx、Cloudflare、部分一体机面板）会缓冲或吃掉 text/event-stream，' +
      '可以在反向代理里关掉缓冲（proxy_buffering off），或换用支持流式的端点。'));
    host.appendChild(warn);
  }

  if (report.models && report.models.length) {
    host.appendChild(el('div', 'model-models-title', '端点报告的可用模型（' + report.models.length + ' 个）'));
    host.appendChild(renderModelIdList(report.models));
  }
}

/* 模型 id 列表：点一下填进模型名输入框，省得手打 */
function renderModelIdList(models, fromServer) {
  var wrap = el('div', 'model-ids');
  var current = $('set-model');
  var currentValue = current ? current.value.trim() : '';
  models.forEach(function (id) {
    if (typeof id !== 'string' || !id) return;
    var chip = el('button', 'model-id' + (id === currentValue ? ' current' : ''), id);
    chip.type = 'button';
    chip.onclick = function () {
      var input = $('set-model');
      if (!input) return;
      input.value = id;
      var siblings = wrap.children;
      for (var i = 0; i < siblings.length; i++) siblings[i].classList.remove('current');
      chip.classList.add('current');
      toast('已填入模型名：' + id, 'ok');
    };
    wrap.appendChild(chip);
  });
  if (!wrap.children.length) wrap.appendChild(el('div', 'empty', '（没有可用的模型 id）'));
  if (fromServer) {
    var hint = el('div', 'model-ids-hint',
      '点某个 id 会填入上面的「模型名」输入框，记得再点一次「保存设置」。');
    var box = el('div');
    box.appendChild(wrap);
    box.appendChild(hint);
    return box;
  }
  return wrap;
}

function runModelCheck() {
  var button = $('model-check-btn');
  var host = $('model-check-result');
  if (button && button.getAttribute('data-busy')) return Promise.resolve(null);

  setButtonBusy(button, true, '检测中…', '测试模型');
  if (host) {
    clear(host);
    host.appendChild(el('div', 'empty', '正在检测：配置 → 网络 → 鉴权 → 模型列表 → 流式对话…'));
  }

  return api('/api/model/check', { method: 'POST', body: collectModelProbe() })
    .then(function (report) {
      renderModelCheck(report);
      if (report && report.ok) toast('模型可用', 'ok');
      else if (report && report.verdict) toast(report.verdict, 'err');
      return report;
    })
    .catch(function (error) {
      renderModelCheck({
        ok: false,
        verdict: '检测失败：' + ((error && error.message) || '未知错误'),
        hint: '守护进程可能没在运行，或该版本的 daemon 还没有实现 /api/model/check。' +
          '可以先点右上角状态徽标确认守护进程是否在线。',
        steps: [{ name: '请求 /api/model/check', ok: false, detail: (error && error.message) || '', ms: 0 }]
      });
      return null;
    })
    .then(function (result) {
      setButtonBusy(button, false, '检测中…', '测试模型');
      updateModelCheckAvailability();
      return result;
    });
}

function loadModelList() {
  var button = $('model-list-btn');
  var host = $('model-list');
  if (button && button.getAttribute('data-busy')) return Promise.resolve(null);

  setButtonBusy(button, true, '拉取中…', '拉取模型列表');
  if (host) {
    clear(host);
    host.appendChild(el('div', 'empty', '正在请求 /api/models…'));
  }

  return api('/api/models')
    .then(function (payload) {
      var models = (payload && payload.models) || [];
      if (host) {
        clear(host);
        if (payload && payload.error && !models.length) {
          host.appendChild(el('div', 'empty', '端点没有返回模型列表：' + payload.error));
        } else if (!models.length) {
          host.appendChild(el('div', 'empty', '端点没有返回任何模型 id。'));
        } else {
          host.appendChild(renderModelIdList(models, true));
        }
      }
      return models;
    })
    .catch(function (error) {
      var message = (error && error.message) || '未知错误';
      // 注意：404 时 apiErrorFrom 给的是「未知接口 GET /api/models」这种文案，
      // 里面并不含 "HTTP 404"，所以必须同时看 error.status，否则友好提示永远不触发。
      var status = (error && error.status) || 0;
      var notImplemented = status === 404 || status === 501 || status === 405 ||
        /HTTP (404|501|405)/.test(message);
      var friendly = notImplemented
        ? '守护进程还没实现 /api/models' + (status ? '（HTTP ' + status + '）' : '') + '。' +
          '可以直接手填模型名；或改用「测试模型」，它会顺便列出端点报告的模型。'
        : '拉取模型列表失败：' + message;
      if (host) {
        clear(host);
        host.appendChild(el('div', 'empty', friendly));
      }
      toast(friendly, 'err');
      return null;
    })
    .then(function (result) {
      setButtonBusy(button, false, '拉取中…', '拉取模型列表');
      updateModelCheckAvailability();
      return result;
    });
}

/* 拉取结果要一直留在页面上（用户可能边看边改输入框），
   所以这里不主动清空，只保证按钮状态和可用性同步。 */

function renderDiag() {
  var host = $('diag-grid');
  if (!host) return;
  var health = state.health;
  clear(host);
  if (!health) { host.appendChild(el('div', 'empty', '无法获取状态')); return; }

  var device = health.device || {};
  var model = health.model || {};
  var bridge = health.bridge || {};
  var daemon = state.daemon;
  var crash = health.lastCrash || null;
  var daemonLabel = daemon.status === 'up' ? '在线' : (daemon.status === 'down' ? '掉线' : '检测中');
  var pairs = [
    ['守护进程', daemonLabel + (daemon.status === 'down' && daemon.failSince
      ? '（已掉线 ' + Math.max(0, Math.round((Date.now() - daemon.failSince) / 1000)) + ' 秒）' : '')],
    ['Process ID', health.pid != null ? String(health.pid) : '—'],
    ['累计重启', health.restarts != null ? String(health.restarts) + ' 次' : '（旧版 daemon 未上报）'],
    ['启动时间', health.startedAt ? fmtTime(health.startedAt) : '—'],
    ['上次退出', health.lastExitClean === true ? '干净退出'
      : (health.lastExitClean === false ? '非正常退出（可能被系统杀掉）' : '—')],
    ['上次崩溃', crash ? (String(crash.signal || '未知信号') + (crash.at ? ' · ' + fmtTime(crash.at) : ''))
      : '无记录'],
    ['最后检测', daemon.lastProbeAt ? (clockTime(daemon.lastProbeAt) + '（' + relTime(daemon.lastProbeAt) + '）') : '—'],
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

  // 崩溃详情单独一块：可折叠，不占满整个诊断网格
  if (crash && crash.detail) {
    var details = el('details', 'notice-details diag-crash');
    details.appendChild(el('summary', 'notice-summary', '上次崩溃日志（最后几行）'));
    details.appendChild(el('pre', 'notice-pre', truncateDetail(crash.detail)));
    host.appendChild(details);
    host.appendChild(el('div', 'diag-key', '崩溃日志路径'));
    host.appendChild(el('div', 'diag-val', CRASH_LOG_PATH));
  }
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
    // 守护进程存活检测：隐藏时降频，恢复可见时立刻补测一次
    handleVisibilityChange();
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

  // 模型检测
  if ($('model-check-btn')) $('model-check-btn').onclick = function () { runModelCheck(); };
  if ($('model-list-btn')) $('model-list-btn').onclick = function () { loadModelList(); };

  // 顶部状态徽标：点一下立刻重测守护进程
  var connBox = $('conn-label-box');
  if (connBox) {
    connBox.onclick = function () {
      probeHealthNow(true);
      toast('正在重新检测守护进程…');
    };
    connBox.style.cursor = 'pointer';
  }

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

  // 守护进程存活检测：立即测一次，然后按 5s/15s 轮询（见 startHealthPolling）
  probeHealthNow(true);
  startHealthPolling();

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
