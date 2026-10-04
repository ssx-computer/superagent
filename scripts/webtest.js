/*
 * iAgent 前端「错误路径」回归测试（Node，无依赖）
 *
 * 目的：把 layout/.../web/app.js 跑在最小 DOM 桩里，故意让 /api/chat 以各种方式失败，
 * 断言 (1) 不抛异常（尤其是作用域错误，例如曾经真实发生过的
 * "Can not find variable: stopStreaming"），(2) 界面上真的出现一条错误提示。
 *
 * 用法：node scripts/webtest.js
 */
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const SRC = path.join(__dirname, '..', 'layout', 'usr', 'share', 'iagent', 'web', 'app.js');
const failures = [];
let checks = 0;

function check(name, ok, detail) {
  checks++;
  console.log((ok ? '  ✓ ' : '  ✗ ') + name + (ok ? '' : '  — ' + (detail || '')));
  if (!ok) failures.push(name);
}

/* ------------------------------- 最小 DOM ------------------------------- */
function makeNode(tag) {
  const attrs = new Map();
  const node = {
    tagName: String(tag || 'div').toUpperCase(),
    children: [],
    parentNode: null,
    className: '',
    textContent: '',
    innerHTML: '',
    value: '',
    style: {},
    dataset: {},
    scrollTop: 0,
    scrollHeight: 0,
    // classList 必须真的读写 className：app.js 里两种写法都有
    // （dot.className = 'conn-dot bad' 与 app.classList.add('daemon-offline')），
    // 空壳 classList 会让"掉线降级"这类断言永远失败。
    classList: {
      add(name) {
        const parts = String(node.className || '').split(/\s+/).filter(Boolean);
        if (name && parts.indexOf(name) < 0) parts.push(name);
        node.className = parts.join(' ');
      },
      remove(name) {
        const parts = String(node.className || '').split(/\s+/).filter(Boolean)
          .filter((p) => p !== name);
        node.className = parts.join(' ');
      },
      toggle(name, force) {
        const has = node.classList.contains(name);
        if (force === true || (force === undefined && !has)) node.classList.add(name);
        else node.classList.remove(name);
        return !has;
      },
      contains(name) {
        return String(node.className || '').split(/\s+/).indexOf(name) >= 0;
      },
    },
    appendChild(c) { c.parentNode = node; node.children.push(c); return c; },
    append(node) { return node.appendChild ? node.appendChild(node) : node; },
    insertBefore(c) { c.parentNode = node; node.children.unshift(c); return c; },
    removeChild(c) {
      const i = node.children.indexOf(c);
      if (i >= 0) node.children.splice(i, 1);
      c.parentNode = null;
      return c;
    },
    replaceChild(n, o) {
      const i = node.children.indexOf(o);
      if (i >= 0) node.children[i] = n;
      n.parentNode = node;
      return o;
    },
    querySelector() { return makeNode('div'); },
    querySelectorAll() { return []; },
    // 真属性要存下来：setButtonBusy() 用 data-busy 防重复点击
    setAttribute(k, v) { attrs.set(String(k), String(v)); },
    getAttribute(k) { return attrs.has(String(k)) ? attrs.get(String(k)) : null; },
    removeAttribute(k) { attrs.delete(String(k)); },
    addEventListener() {}, removeEventListener() {},
    focus() {}, blur() {}, click() {}, scrollIntoView() {},
    getBoundingClientRect() { return { top: 0, left: 0, width: 0, height: 0 }; },
  };
  // toast() 用的是 childNodes/firstChild，补上别名
  Object.defineProperty(node, 'childNodes', { get: () => node.children });
  Object.defineProperty(node, 'firstChild', { get: () => node.children[0] || null });
  Object.defineProperty(node, 'lastChild', { get: () => node.children[node.children.length - 1] || null });
  return node;
}

function textOf(node, out) {
  out = out || [];
  if (!node) return out;
  if (node.textContent) out.push(String(node.textContent));
  (node.children || []).forEach((c) => textOf(c, out));
  return out;
}

/* --------------------------- 每个用例一套环境 --------------------------- */
function loadApp(fetchImpl, opts) {
  opts = opts || {};
  let src = fs.readFileSync(SRC, 'utf8');
  // 暴露内部函数给测试（只在测试里注入，产品文件不动）
  const tail = src.lastIndexOf('})();');
  if (tail < 0) throw new Error('app.js 结构变了：找不到 IIFE 结尾');
  src = src.slice(0, tail) +
    '  globalThis.__iag = { streamChat: streamChat, state: state, appendToChat: appendToChat,\n' +
    '    pollHealthOnce: pollHealthOnce, renderModelCheck: renderModelCheck, runModelCheck: runModelCheck,\n' +
    '    loadModelList: loadModelList, handleVisibilityChange: handleVisibilityChange,\n' +
    '    startHealthPolling: startHealthPolling, stopHealthPolling: stopHealthPolling,\n' +
    '    announceDaemonClose: announceDaemonClose, closeSuffix: daemonCloseSuffix,\n' +
    '    offsets: { HEALTH_INTERVAL_VISIBLE: HEALTH_INTERVAL_VISIBLE, HEALTH_INTERVAL_HIDDEN: HEALTH_INTERVAL_HIDDEN,\n' +
    '               HEALTH_FAIL_THRESHOLD: HEALTH_FAIL_THRESHOLD } };\n' +
    // announceDaemonClose 在 app.js 里是可被测试替换的模块级变量，
    // 所以导出必须写穿（普通属性赋值只会改到 __iag 对象上，替换不生效）。
    '  Object.defineProperty(globalThis.__iag, "announceDaemonClose", {\n' +
    '    get: function () { return announceDaemonClose; },\n' +
    '    set: function (value) { announceDaemonClose = value; },\n' +
    '    configurable: true\n' +
    '  });\n' +
    src.slice(tail);

  const chatList = makeNode('div');
  const ids = new Map();
  const created = [];                 // createElement 出来的节点，便于断言按钮状态
  const document = {
    readyState: opts.boot ? 'complete' : 'loading',   // boot 用例才会真的执行 boot()
    hidden: false,
    addEventListener() {},
    removeEventListener() {},
    createElement: (t) => {
      const node = makeNode(t);
      created.push(node);
      return node;
    },
    createTextNode: (t) => ({ textContent: t }),
    getElementById(id) {
      if (id === 'chat-list') return chatList;      // appendToChat 走的是 $('chat-list')
      if (!ids.has(id)) ids.set(id, makeNode('div'));
      return ids.get(id);
    },
    querySelector(sel) {
      if (sel === '.chat-list') return chatList;
      return makeNode('div');
    },
    querySelectorAll() { return []; },
    body: makeNode('body'),
    documentElement: makeNode('html'),
  };
  const sandbox = {
    console,
    document,
    window: {},
    navigator: { userAgent: 'node-test' },
    location: { href: 'http://127.0.0.1:8080/', search: '', hash: '', pathname: '/' },
    history: { replaceState() {}, pushState() {} },
    URLSearchParams,
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    fetch: fetchImpl,
    setTimeout: opts.setTimeout || setTimeout,
    clearTimeout: opts.clearTimeout || clearTimeout,
    setInterval: opts.setInterval || setInterval,
    clearInterval: opts.clearInterval || clearInterval,
    TextDecoder, TextEncoder, AbortController, Promise, Error, JSON, Math,
    Date: opts.Date || Date,
    addEventListener() {}, removeEventListener() {},
    innerWidth: 390, innerHeight: 844, devicePixelRatio: 2, scrollX: 0, scrollY: 0,
    matchMedia: () => ({ matches: false, media: '', addEventListener() {}, removeEventListener() {} }),
    requestAnimationFrame: (cb) => (opts.setTimeout || setTimeout)(() => cb((opts.Date || Date).now()), 0),
    cancelAnimationFrame: (id) => (opts.clearTimeout || clearTimeout)(id),
    scrollTo() {}, alert() {}, confirm: () => true,
    __chatList: chatList,
  };
  sandbox.window = sandbox;
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox, { filename: 'app.js' });
  sandbox.__iag.__chatList = chatList;
  sandbox.__iag.__created = created;
  sandbox.__iag.document = document;
  return sandbox;
}

/* 在 createElement 出来的节点里按 className 找一个（el(tag,'model-check') 之类） */
function findByClass(env, className) {
  const nodes = env.__iag.__created || [];
  for (let i = 0; i < nodes.length; i++) {
    if (String(nodes[i].className || '').split(/\s+/).indexOf(className) >= 0) return nodes[i];
  }
  return null;
}

/* 取当前注册的轮询间隔（毫秒）；没有 interval 时返回 -1 */
function firstIntervalDelay(timers) {
  let delay = -1;
  timers.pending.forEach((t) => { if (t.repeat && delay < 0) delay = t.ms; });
  return delay;
}

/* 可控定时器 + 虚拟时钟：让健康轮询 5s/15s 的间隔在测试里可以瞬间推进。
   要点：Date.now() 也必须一起推进，否则「下一个到期时刻」永远追不上真实时间，
   间隔定时器只会触发一次。假 Date 必须是真正的构造函数（app.js 里 new Date() 用得很多）。 */
function makeTimers() {
  let seq = 1;
  let now = 1700000000000;
  const realDate = Date;
  const pending = new Map();
  function add(fn, ms, repeat) {
    const id = seq++;
    pending.set(id, { fn, ms, repeat, at: now + Math.max(0, Number(ms) || 0) });
    return id;
  }
  class FakeDate extends realDate {
    constructor(...args) {
      if (args.length) super(...args);
      else super(now);
    }
    static now() { return now; }
  }
  const timers = {
    Date: FakeDate,
    pending,
    setTimeout: (fn, ms) => add(fn, ms, false),
    clearTimeout: (id) => { pending.delete(id); },
    setInterval: (fn, ms) => add(fn, ms, true),
    clearInterval: (id) => { pending.delete(id); },
    // 推进虚拟时间：每步只触发最早到期的那一个
    tick(ms) {
      const deadline = now + (ms || 0);
      for (let guard = 0; guard < 2000; guard++) {
        let nextId = null;
        let next = null;
        pending.forEach((t, id) => {
          if (t.at <= deadline && (!next || t.at < next.at)) { next = t; nextId = id; }
        });
        if (!next) break;
        now = next.at;
        if (next.repeat) next.at = next.at + next.ms;
        else pending.delete(nextId);
        try { next.fn(); } catch (e) { /* 定时器里的异常由用例自己断言 */ }
      }
      now = deadline;
    },
    liveIntervals() {
      let n = 0;
      pending.forEach((t) => { if (t.repeat) n++; });
      return n;
    },
  };
  return timers;
}

/* 让挂起的 Promise 链跑完（不用真的等时间）。
   先跑若干个微任务，再让出一次事件循环 —— 只跑微任务的话，
   有些「fetch 桩 → text() → 解析」的多级链会停在半路。 */
function tick(n) {
  let chain = Promise.resolve();
  for (let i = 0; i < (n || 4); i++) chain = chain.then(() => {});
  return chain.then(() => new Promise((resolve) => setImmediate(resolve))).then(() => chain);
}

/* 收集一棵子树里所有元素的 class 名 */
function classNamesOf(node, out) {
  out = out || [];
  if (!node) return out;
  String(node.className || '').split(/\s+/).filter(Boolean).forEach((c) => out.push(c));
  (node.children || []).forEach((c) => classNamesOf(c, out));
  return out;
}

function sseResponse(chunks) {
  let i = 0;
  const enc = new TextEncoder();
  return {
    ok: true,
    status: 200,
    text: () => Promise.resolve(''),
    body: {
      getReader() {
        return {
          read() {
            if (i >= chunks.length) return Promise.resolve({ done: true, value: undefined });
            return Promise.resolve({ done: false, value: enc.encode(chunks[i++]) });
          },
        };
      },
    },
  };
}

const ASSISTANT_NODE = makeNode('div');

/* 断言用的可见文本：聊天列表 + 助手气泡（气泡在桩里不一定挂在列表上） */
function visibleText(env) {
  return textOf(env.__chatList).concat(textOf(ASSISTANT_NODE)).join(' | ');
}

async function run(sessionId, response, opts) {
  const env = loadApp(() => (response instanceof Error ? Promise.reject(response) : Promise.resolve(response)), opts);
  const assistantText = makeNode('div');
  const bubble = makeNode('div');
  ASSISTANT_NODE.children.length = 0;
  bubble.parentNode = ASSISTANT_NODE;
  ASSISTANT_NODE.children.push(bubble);
  ASSISTANT_NODE.querySelector = () => bubble;
  ASSISTANT_NODE.parentNode = env.__chatList;
  try {
    await env.__iag.streamChat(sessionId, '你好', assistantText, ASSISTANT_NODE, makeNode('div'));
    return { env, error: null };
  } catch (e) {
    return { env, error: e };
  }
}

/* 顶部状态徽标：把点里的文本和 title 都取出来断言。
   真机 DOM 里 conn-label 是 conn-label-box 的子节点，浏览器的 textContent
   会把子节点文本一起返回；stub 的节点之间没有真正的父子关系，所以这里手工补上，
   否则「掉线」两个字永远断言不到。 */
function connText(env) {
  const box = env.document.getElementById('conn-label-box');
  const label = env.document.getElementById('conn-label');
  const dot = env.document.getElementById('conn-dot');
  return [box.textContent, label.textContent, box.title, dot.className].join(' | ');
}

/* 聊天页横幅文本 */
function bannerText(env) {
  return textOf(env.document.getElementById('chat-banner')).join(' | ');
}

function healthJSON(extra) {
  const base = {
    ok: true, version: '1.0.3', pid: 100, restarts: 0, startedAt: 1699999999,
    lastCrash: null, lastExitClean: true, model: { hasKey: true },
  };
  return JSON.stringify(Object.assign(base, extra || {}));
}

function jsonResponse(body) {
  return { ok: true, status: 200, text: () => Promise.resolve(body), body: null };
}

/* --------------------------------- 用例 --------------------------------- */
(async function main() {
  console.log('iAgent 前端错误路径测试\n');

  // 1. 网络层直接失败（fetch reject）
  {
    const { error, env } = await run('s1', new Error('network down'));
    check('fetch 失败不抛异常', !error, error && error.stack);
    const text = visibleText(env);
    check('fetch 失败会显示错误提示', /连接中断/.test(text), text.slice(0, 200));
  }

  // 2. HTTP 401（body 里带后端错误信息）
  {
    const res = {
      ok: false, status: 401,
      text: () => Promise.resolve('{"error":"API Key 无效"}'),
      body: null,
    };
    const { error, env } = await run('s2', res);
    check('HTTP 401 不抛异常', !error, error && error.stack);
    const text = visibleText(env);
    check('HTTP 401 显示后端错误原文', /API Key 无效/.test(text), text.slice(0, 200));
  }

  // 3. SSE error 事件（模型报错）→ 应该出现带「重试」的错误卡片
  {
    const body = 'event: error\ndata: {"message":"模型返回 HTTP 400 模型名不对"}\n\n';
    const { error, env } = await run('s3', sseResponse([body]));
    check('SSE error 事件不抛异常', !error, error && error.stack);
    const text = visibleText(env);
    check('SSE error 事件显示原因', /模型名不对/.test(text), text.slice(0, 200));
    check('SSE error 事件给出重试入口', /重试/.test(text), text.slice(0, 200));
  }

  // 4. 流在没有 done 的情况下结束（daemon 半路没了）
  {
    const { error, env } = await run('s4', sseResponse(['event: delta\ndata: {"text":"半句话"}\n\n']));
    check('流提前结束不抛异常', !error, error && error.stack);
    const text = visibleText(env);
    check('流提前结束会提示连接被提前关闭', /提前关闭/.test(text), text.slice(0, 200));
  }

  // 5. 用户主动停止（AbortError）
  {
    const abortError = new Error('aborted');
    abortError.name = 'AbortError';
    const { error, env } = await run('s5', abortError);
    check('用户停止不抛异常', !error, error && error.stack);
    const text = visibleText(env);
    check('用户停止提示已停止生成', /已停止生成/.test(text), text.slice(0, 200));
  }

  // 6. 启动冒烟：让 boot() 真的跑一遍（初始化、绑定事件、拉工具/定时任务列表），
  //    任何 ReferenceError 都会在这里暴露出来。
  {
    const json = () => Promise.resolve('[]');
    let err = null;
    try {
      loadApp(() => Promise.resolve({ ok: true, status: 200, text: json, body: null }), { boot: true });
    } catch (e) {
      err = e;
    }
    check('boot() 初始化不抛异常', !err, err && err.stack);
  }

  /* ==================== 本次新增：守护进程存活 + 模型检测 ==================== */
  console.log('\n-- 守护进程存活检测 / 连接提前关闭归因 --');

  // 7. error 事件之后流结束 → 不能再叠加「连接被提前关闭」
  //    （守护进程正常返回 HTTP 401 这类错误时，流的结束是正常收尾）
  {
    const body = 'event: error\ndata: {"message":"模型返回 HTTP 401 API Key 无效，请检查 Key"}\n\n';
    const { error, env } = await run('s7', sseResponse([body]));
    check('error 事件后流结束不抛异常', !error, error && error.stack);
    const text = visibleText(env);
    check('error 事件后流结束不再提示「连接被提前关闭」', !/提前关闭/.test(text), text.slice(0, 260));
    check('error 事件后流结束仍保留真实错误原因', /API Key 无效/.test(text), text.slice(0, 260));
  }

  // 8. 流在没有 done/error 的情况下结束，且期间守护进程重启过 →
  //    文案必须带守护进程信息（第 N 次重启 / 信号 / 日志路径）
  {
    const healthCalls = [];
    const healthResponses = [
      jsonResponse(healthJSON({ pid: 100, restarts: 0 })),
      jsonResponse(healthJSON({
        pid: 200, restarts: 1, lastExitClean: false,
        lastCrash: { at: 1699999000, signal: 'SIGSEGV', detail: 'Exception Type: EXC_BAD_ACCESS\ncrash line A\ncrash line B' },
      })),
    ];
    const sseBody = sseResponse(['event: delta\ndata: {"text":"半句话"}\n\n']);
    const env = loadApp((url) => {
      if (url.indexOf('/api/health') === 0) {
        healthCalls.push(url);
        return Promise.resolve(healthResponses.length > 1 ? healthResponses.shift() : healthResponses[0]);
      }
      return Promise.resolve(sseBody);                     // /api/chat 走 SSE
    });
    let report = null;
    env.__iag.announceDaemonClose = (summary) => { report = summary; };

    const assistantText = makeNode('div');
    const bubble = makeNode('div');
    ASSISTANT_NODE.children.length = 0;
    bubble.parentNode = ASSISTANT_NODE;
    ASSISTANT_NODE.children.push(bubble);
    ASSISTANT_NODE.querySelector = () => bubble;
    ASSISTANT_NODE.parentNode = env.__chatList;

    let error = null;
    try {
      await env.__iag.pollHealthOnce();                    // 第一次健康检查：pid=100
      // 流结束后 app.js 会自己再探一次 /api/health（真机上的兜底实现）
      await env.__iag.streamChat('s8', '你好', assistantText, ASSISTANT_NODE, makeNode('div'));
      await tick(6);
    } catch (e) {
      error = e;
    }
    check('流提前关闭 + 守护进程重启：不抛异常', !error, error && error.stack);
    const text = visibleText(env);
    check('流提前关闭会提示连接被提前关闭', /提前关闭/.test(text), text.slice(0, 260));
    check('流结束后确实又探测了一次 /api/health', healthCalls.length >= 2, '健康检查次数 ' + healthCalls.length);
    check('提示里识别出「守护进程重启过」', !!(report && report.justRestarted),
      report ? JSON.stringify(report) : 'null');
    check('提示里带上了重启次数与新旧 pid',
      !!(report && report.restarts === 1 && report.pid === 200 && report.lastPid === 100),
      report ? JSON.stringify(report) : 'null');
    check('崩溃信号被带上（SIGSEGV）', !!(report && report.lastCrash && report.lastCrash.signal === 'SIGSEGV'),
      report ? JSON.stringify(report.lastCrash) : 'null');
    check('非干净退出被带上（lastExitClean=false）', !!(report && report.lastExitClean === false),
      report ? JSON.stringify(report) : 'null');

    // 文案本体（daemonCloseSuffix）也要包含重启/信号/日志路径关键字
    const suffix = env.__iag.closeSuffix(report);
    check('提示文案含「重启」字样', /重启/.test(suffix), suffix.slice(0, 300));
    check('提示文案含崩溃信号与日志路径',
      /SIGSEGV/.test(suffix) && /iagentd-crash\.log/.test(suffix), suffix.slice(0, 400));
  }

  // 9. 流提前关闭，但守护进程并没有重启 → 不能冤枉它
  {
    const sseBody = sseResponse(['event: delta\ndata: {"text":"半句话"}\n\n']);
    const env = loadApp((url) => {
      if (url.indexOf('/api/health') === 0) {
        return Promise.resolve(jsonResponse(healthJSON({ pid: 777, restarts: 5 })));
      }
      return Promise.resolve(sseBody);
    });
    let report = null;
    env.__iag.announceDaemonClose = (summary) => { report = summary; };

    const assistantText = makeNode('div');
    const bubble = makeNode('div');
    ASSISTANT_NODE.children.length = 0;
    bubble.parentNode = ASSISTANT_NODE;
    ASSISTANT_NODE.children.push(bubble);
    ASSISTANT_NODE.querySelector = () => bubble;
    ASSISTANT_NODE.parentNode = env.__chatList;

    try {
      await env.__iag.pollHealthOnce();                    // pid=777
      await env.__iag.streamChat('s9', '你好', assistantText, ASSISTANT_NODE, makeNode('div'));
      await tick(6);
    } catch (e) {
      check('流提前关闭（未重启）不抛异常', false, e.stack);
    }
    check('未重启时不会误报 justRestarted', !!(report && report.justRestarted === false),
      report ? JSON.stringify(report) : 'null');
    check('未重启时保留 pid 供文案说明「仍在运行」', !!(report && report.pid === 777),
      report ? JSON.stringify(report) : 'null');
    const suffix = env.__iag.closeSuffix(report);
    check('未重启时文案说明「守护进程仍在运行」', /仍在运行/.test(suffix), suffix.slice(0, 300));
  }

  // 10. 健康轮询状态机：成功 → 连续失败 → 掉线 → 重启 → 恢复
  {
    const timers = makeTimers();
    let failMode = false;
    let pid = 1;
    let restarts = 0;
    let healthCalls = 0;
    const env = loadApp(() => {
      healthCalls++;
      if (failMode) return Promise.reject(new Error('connect refused'));
      return Promise.resolve(jsonResponse(healthJSON({ pid, restarts })));
    }, { setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout,
         setInterval: timers.setInterval, clearInterval: timers.clearInterval, Date: timers.Date });

    const offsets = env.__iag.offsets;
    check('轮询间隔参数：可见 5s / 隐藏 15s', offsets.HEALTH_INTERVAL_VISIBLE === 5000 && offsets.HEALTH_INTERVAL_HIDDEN === 15000,
      JSON.stringify(offsets));

    env.__iag.startHealthPolling();
    await tick(6);
    check('startHealthPolling 注册了轮询定时器', timers.liveIntervals() === 1,
      'interval 数=' + timers.liveIntervals());

    // 第 1 次轮询：守护进程健康
    timers.tick(5200);
    await tick(6);
    check('轮询会周期性探测 /api/health', healthCalls >= 1, 'healthCalls=' + healthCalls);
    check('健康时状态徽标显示在线', /在线/.test(connText(env)) && /conn-dot ok/.test(connText(env)), connText(env));
    check('健康时状态记住 pid', env.__iag.state.daemon.lastPid === 1, String(env.__iag.state.daemon.lastPid));

    // 第 2、3 次轮询：连续失败两次才判定掉线
    failMode = true;
    timers.tick(5200);            // 失败 #1
    await tick(6);
    check('单次失败不判定掉线（阈值 2 次）', env.__iag.state.daemon.status === 'up',
      'status=' + env.__iag.state.daemon.status + ' fail=' + env.__iag.state.daemon.failCount);
    timers.tick(5200);            // 失败 #2 → 掉线
    await tick(6);
    check('连续失败 2 次后判定掉线', env.__iag.state.daemon.status === 'down',
      'status=' + env.__iag.state.daemon.status + ' fail=' + env.__iag.state.daemon.failCount);
    check('掉线时状态徽标变红点', /conn-dot bad/.test(connText(env)) && /掉线/.test(connText(env)), connText(env));
    check('掉线时出现常驻横幅', /守护进程未运行/.test(bannerText(env)) && /SpringBoard/.test(bannerText(env)),
      bannerText(env));
    check('掉线时禁用发送按钮', env.document.getElementById('chat-send').disabled === true, 'send.disabled');
    check('掉线时输入框给出提示', /守护进程未运行/.test(env.document.getElementById('chat-input').placeholder),
      env.document.getElementById('chat-input').placeholder);
    check('掉线时整页进入降级状态', env.document.getElementById('app').className.indexOf('daemon-offline') >= 0,
      env.document.getElementById('app').className);

    // 守护进程换了 pid（重启）后恢复
    failMode = false;
    pid = 2;
    restarts = 1;
    timers.tick(5200);
    await tick(6);
    const text = visibleText(env);
    check('重启后状态恢复在线', env.__iag.state.daemon.status === 'up',
      'status=' + env.__iag.state.daemon.status);
    check('重启后状态徽标恢复绿点', /conn-dot ok/.test(connText(env)), connText(env));
    check('重启后不再降级（输入框恢复）', env.document.getElementById('chat-send').disabled === false,
      'send.disabled=' + env.document.getElementById('chat-send').disabled);
    check('重启后出现「守护进程已重启」信息', /守护进程已重启/.test(text), text.slice(0, 300));
    check('重启信息里带第几次重启', /第\s*1\s*次/.test(text), text.slice(0, 300));
    check('页面上出现「已恢复响应」提示', /恢复响应|恢复/.test(text), text.slice(0, 300));

    // 定时器必须能被清理
    env.__iag.stopHealthPolling();
    check('stopHealthPolling 清掉轮询定时器', timers.liveIntervals() === 0,
      '剩余 interval=' + timers.liveIntervals());
  }

  // 11. 隐藏页面时降频、恢复可见时立刻补测
  {
    const timers = makeTimers();
    let healthCalls = 0;
    const env = loadApp(() => {
      healthCalls++;
      return Promise.resolve(jsonResponse(healthJSON({ pid: 5 })));
    }, { setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout,
         setInterval: timers.setInterval, clearInterval: timers.clearInterval, Date: timers.Date });

    env.__iag.startHealthPolling();
    await tick(6);
    check('可见时轮询定时器使用 5s 间隔', timers.liveIntervals() === 1 && firstIntervalDelay(timers) === 5000,
      'delay=' + firstIntervalDelay(timers));

    env.document.hidden = true;
    env.__iag.handleVisibilityChange();
    await tick(6);
    check('页面隐藏时轮询降频到 15s', firstIntervalDelay(timers) === 15000, 'delay=' + firstIntervalDelay(timers));
    const before = healthCalls;

    env.document.hidden = false;
    env.__iag.handleVisibilityChange();
    await tick(6);
    check('恢复可见时立刻补测一次', healthCalls > before, 'before=' + before + ' after=' + healthCalls);
    check('恢复可见后轮询回到 5s', firstIntervalDelay(timers) === 5000, 'delay=' + firstIntervalDelay(timers));
    env.__iag.stopHealthPolling();
  }

  // 12. 设置页模型体检渲染
  console.log('\n-- 模型检测 --');
  {
    const report = {
      ok: false,
      verdict: '不可用：鉴权失败 (HTTP 401)',
      hint: '检查 API Key 是否正确、是否有该模型的权限',
      models: ['gpt-4o', 'gpt-4o-mini'],
      steps: [
        { name: '配置检查', ok: true, detail: 'baseUrl=https://api.openai.com/v1 model=gpt-4o key=已设置(sk-…abcd)', ms: 0 },
        { name: '网络连通', ok: true, detail: '已连通 api.openai.com:443', ms: 132 },
        { name: '接口鉴权', ok: false, detail: 'HTTP 401 {"error":"invalid key"}', ms: 210 },
        { name: '模型列表', ok: false, detail: '未执行（上一步失败）', ms: 0 },
        { name: '流式对话', ok: false, detail: '未执行（上一步失败）', ms: 0 },
      ],
    };
    const env = loadApp(() => Promise.resolve(jsonResponse(JSON.stringify(report))));
    const result = await env.__iag.runModelCheck();
    const card = env.document.getElementById('model-check-result');
    const text = textOf(card).join(' | ');
    check('模型体检：返回报告不抛异常', !!result, 'result 为空');
    check('模型体检：卡片显示 verdict', /不可用：鉴权失败 \(HTTP 401\)/.test(text), text.slice(0, 300));
    check('模型体检：卡片显示 hint', /检查 API Key 是否正确/.test(text), text.slice(0, 300));
    check('模型体检：每个步骤名都渲染出来',
      /配置检查/.test(text) && /网络连通/.test(text) && /接口鉴权/.test(text) &&
      /模型列表/.test(text) && /流式对话/.test(text), text.slice(0, 400));
    check('模型体检：失败步骤的 detail 渲染出来', /invalid key/.test(text), text.slice(0, 400));
    check('模型体检：未执行步骤标灰（⊙/○）', /未执行/.test(text), text.slice(0, 400));
    check('模型体检：步骤耗时格式化', /210ms/.test(text) || /0\.21s/.test(text), text.slice(0, 400));
    check('模型体检：端点报告的模型 id 渲染成可选列表', /gpt-4o-mini/.test(text), text.slice(0, 400));
    // 按钮是按 id 取的（$('model-check-btn')），不是 createElement 出来的，
    // 所以这里必须用 getElementById —— findByClass 只看得见 createElement 的节点。
    const checkBtn = env.document.getElementById('model-check-btn');
    check('模型体检：按钮恢复可点', checkBtn && checkBtn.disabled === false,
      'button.disabled=' + (checkBtn ? checkBtn.disabled : '(按钮不存在)'));
  }

  // 13. 模型体检：端点 200 但没有 SSE 数据 → 显著提示（自建中转最常见的问题）
  {
    const report = {
      ok: false,
      verdict: '不可用：流式对话无数据',
      hint: '端点返回 200，但没有收到 SSE 事件',
      steps: [
        { name: '配置检查', ok: true, detail: 'baseUrl=https://relay.example.com/v1 model=gpt-4o key=已设置(sk-…1234)', ms: 0 },
        { name: '网络连通', ok: true, detail: '已连通 relay.example.com:443', ms: 88 },
        { name: '接口鉴权', ok: true, detail: 'HTTP 200', ms: 120 },
        { name: '模型列表', ok: true, detail: '返回 2 个模型', ms: 95 },
        { name: '流式对话', ok: false, detail: '端点返回 200 但没有 SSE 数据（可能不支持 stream:true）', ms: 1500 },
      ],
    };
    const env = loadApp(() => Promise.resolve(jsonResponse(JSON.stringify(report))));
    await env.__iag.runModelCheck();
    const text = textOf(env.document.getElementById('model-check-result')).join(' | ');
    check('无 SSE 数据时给出显著提示', /SSE/.test(text) && /stream:true|缓冲/.test(text), text.slice(0, 400));
  }

  // 14. 拉取模型列表：点 id 填进 model 输入框
  {
    const env = loadApp(() => Promise.resolve(jsonResponse(JSON.stringify({ ok: true, models: ['qwen-max', 'gpt-4o-mini'], error: null }))));
    await env.__iag.loadModelList();
    const host = env.document.getElementById('model-list');
    const buttons = [];
    (function walk(node) {
      if (String(node.className || '').split(/\s+/).indexOf('model-id') >= 0) buttons.push(node);
      (node.children || []).forEach(walk);
    })(host);
    check('模型列表渲染出可点击的 id', buttons.length === 2, '按钮数 ' + buttons.length);
    if (buttons.length) buttons[0].onclick();
    check('点模型 id 会填进模型名输入框', env.document.getElementById('set-model').value === 'qwen-max',
      env.document.getElementById('set-model').value);
  }

  // 15. /api/models 未实现（404）时给友好提示，不抛异常
  {
    const env = loadApp(() => Promise.resolve({
      ok: false, status: 404, text: () => Promise.resolve('{"error":"未知接口 GET /api/models"}'), body: null,
    }));
    let error = null;
    try {
      await env.__iag.loadModelList();
    } catch (e) {
      error = e;
    }
    const text = textOf(env.document.getElementById('model-list')).join(' | ');
    check('/api/models 未实现时不抛异常', !error, error && error.stack);
    check('/api/models 未实现时给友好提示', /还没实现/.test(text) || /404/.test(text), text.slice(0, 300));
  }

  // 16. 模型体检接口不可用（daemon 没实现 / 掉线）时也要出一张可读的卡片
  {
    const env = loadApp(() => Promise.reject(new Error('Failed to fetch')));
    let error = null;
    try {
      await env.__iag.runModelCheck();
    } catch (e) {
      error = e;
    }
    const text = textOf(env.document.getElementById('model-check-result')).join(' | ');
    check('体检接口不可用时不抛异常', !error, error && error.stack);
    check('体检接口不可用时卡片给出原因与下一步', /检测失败/.test(text) && /守护进程/.test(text), text.slice(0, 300));
  }

  console.log('\n' + checks + ' 项检查，失败 ' + failures.length + ' 项');
  if (failures.length) {
    console.log('失败：' + failures.join('；'));
    process.exit(1);
  }
  // app.js 内部有 setInterval，桩环境下事件循环不会自己空掉，必须显式退出
  process.exit(0);
})().catch((e) => {
  console.error('测试自身异常:', e);
  process.exit(2);
});





