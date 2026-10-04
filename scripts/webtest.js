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
    classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
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
    setAttribute() {}, getAttribute() { return null; }, removeAttribute() {},
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
  src = src.slice(0, tail) + '  globalThis.__iag = { streamChat: streamChat, state: state, appendToChat: appendToChat };\n' + src.slice(tail);

  const chatList = makeNode('div');
  const ids = new Map();
  const document = {
    readyState: opts.boot ? 'complete' : 'loading',   // boot 用例才会真的执行 boot()
    addEventListener() {},
    removeEventListener() {},
    createElement: (t) => makeNode(t),
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
    location: { href: 'http://127.0.0.1:8080/', search: '', hash: '' },
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    fetch: fetchImpl,
    setTimeout, clearTimeout, setInterval, clearInterval,
    TextDecoder, AbortController, Promise, Error, JSON, Date, Math,
    addEventListener() {}, removeEventListener() {},
    innerWidth: 390, innerHeight: 844, devicePixelRatio: 2, scrollX: 0, scrollY: 0,
    matchMedia: () => ({ matches: false, media: '', addEventListener() {}, removeEventListener() {} }),
    requestAnimationFrame: (cb) => setTimeout(() => cb(Date.now()), 0),
    cancelAnimationFrame: (id) => clearTimeout(id),
    scrollTo() {}, alert() {}, confirm: () => true,
    __chatList: chatList,
  };
  sandbox.window = sandbox;
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox, { filename: 'app.js' });
  sandbox.__iag.__chatList = chatList;
  return sandbox;
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

async function run(sessionId, response) {
  const env = loadApp(() => (response instanceof Error ? Promise.reject(response) : Promise.resolve(response)));
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
