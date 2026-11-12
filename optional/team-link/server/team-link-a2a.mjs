#!/usr/bin/env node
// team-link A2A 服务端（阶段 B，单机自环）。
// 启动：node server/team-link-a2a.mjs --http --port 7310 --config <cfg>
// 自检：node server/team-link-a2a.mjs --selftest --config <cfg>   （只自检，不监听）
// 仅绑定 127.0.0.1；零第三方依赖，仅用 Node 标准库。
import http from 'node:http';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const SERVER_DIR = path.dirname(fileURLToPath(import.meta.url));
const BUNDLE_DIR = path.resolve(SERVER_DIR, '..');
const SERVER_NAME = 'team-link';
const VERSION = '0.1.0';
const PROTOCOL_VERSION = '0.2.0';
const LOOPBACK = '127.0.0.1';

function printHelp() {
  console.error([
    '用法: node server/team-link-a2a.mjs --http --port <端口> --config <配置文件>',
    '      node server/team-link-a2a.mjs --selftest --config <配置文件>',
    '说明: 仅监听 127.0.0.1；AgentCard 免认证，POST 通道强制 Bearer。'
  ].join('\n'));
}

function parseArgv(argv) {
  const out = { http: false, selftest: false, port: null, config: null };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--http') out.http = true;
    else if (a === '--selftest') out.selftest = true;
    else if (a === '--port') out.port = Number(argv[i += 1]);
    else if (a.startsWith('--port=')) out.port = Number(a.slice('--port='.length));
    else if (a === '--config') out.config = argv[i += 1];
    else if (a.startsWith('--config=')) out.config = a.slice('--config='.length);
    else if (a === '--help' || a === '-h') { printHelp(); process.exit(0); }
    else { console.error('未知参数: ' + a); printHelp(); process.exit(2); }
  }
  return out;
}

function resolveConfigPath(given) {
  const pick = given || process.env.TEAM_LINK_CONFIG || '';
  if (pick) {
    const abs = path.isAbsolute(pick) ? pick : path.resolve(BUNDLE_DIR, pick);
    return abs;
  }
  const primary = path.join(BUNDLE_DIR, 'state', 'config.json');
  if (fs.existsSync(primary)) return primary;
  const fallback = path.join(BUNDLE_DIR, 'state', 'config.example.json');
  if (fs.existsSync(fallback)) return fallback;
  throw new Error('未找到配置文件: ' + primary);
}

function loadConfig(cfgPath) {
  const raw = fs.readFileSync(cfgPath, 'utf8');
  let cfg;
  try { cfg = JSON.parse(raw); } catch (e) { throw new Error('配置文件不是合法 JSON: ' + e.message); }
  if (!cfg || typeof cfg !== 'object') throw new Error('配置文件内容必须为对象');
  return cfg;
}

function tokenCandidates(cfgPath, tokenFile) {
  const list = [];
  if (typeof tokenFile === 'string' && tokenFile.length > 0) {
    if (path.isAbsolute(tokenFile)) list.push(tokenFile);
    else {
      list.push(path.resolve(BUNDLE_DIR, tokenFile));
      list.push(path.resolve(path.dirname(cfgPath), tokenFile));
      list.push(path.resolve(process.cwd(), tokenFile));
    }
  }
  return [...new Set(list)];
}

// token 优先读取已存在的文件；不存在则生成并落盘（仅限解析出的第一个候选路径）。
function ensureToken(cfgPath, tokenFile, notes) {
  const cands = tokenCandidates(cfgPath, tokenFile);
  if (cands.length === 0) throw new Error('配置缺少 tokenFile');
  for (const c of cands) {
    try {
      const t = fs.readFileSync(c, 'utf8').trim();
      if (t) return { token: t, file: c, created: false };
    } catch { /* 继续找下一个候选 */ }
  }
  const target = cands[0];
  const token = crypto.randomBytes(24).toString('hex');
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, token + '\n', 'utf8');
  notes.push('已生成 token 文件: ' + target);
  return { token, file: target, created: true };
}

function makeLogger(file) {
  const dir = path.dirname(file);
  fs.mkdirSync(dir, { recursive: true });
  return (line) => {
    const text = new Date().toISOString() + ' ' + line + '\n';
    try { fs.appendFileSync(file, text, 'utf8'); } catch { /* 日志失败不影响服务 */ }
  };
}

function buildContext(args) {
  const cfgPath = resolveConfigPath(args.config);
  const cfg = loadConfig(cfgPath);
  const notes = [];
  const a2aCfg = cfg.a2a || {};
  let host = typeof a2aCfg.host === 'string' && a2aCfg.host ? a2aCfg.host : LOOPBACK;
  if (host !== LOOPBACK && host !== 'localhost' && host !== '::1') {
    notes.push('配置 host=' + host + ' 非回环地址，已强制改为 ' + LOOPBACK);
    host = LOOPBACK;
  }
  if (host === 'localhost' || host === '::1') host = LOOPBACK;
  const port = Number.isFinite(args.port) && args.port > 0 ? args.port : Number(a2aCfg.port || 7310);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('端口非法: ' + port);
  const a2aPath = typeof a2aCfg.path === 'string' && a2aCfg.path ? a2aCfg.path : '/';
  const cardPath = typeof a2aCfg.agentCardPath === 'string' && a2aCfg.agentCardPath ? a2aCfg.agentCardPath : '/.well-known/agent.json';
  const logDirRel = typeof cfg.logDir === 'string' && cfg.logDir ? cfg.logDir : 'logs';
  const logDir = path.isAbsolute(logDirRel) ? logDirRel : path.resolve(BUNDLE_DIR, logDirRel);
  // 契约：任务一律落在 BUNDLE\\state\\tasks/<id>.json，与配置所在目录无关。
  const tasksDir = path.resolve(BUNDLE_DIR, 'state', 'tasks');
  const token = ensureToken(cfgPath, a2aCfg.tokenFile || 'state/a2a.token', notes);
  const role = typeof cfg.role === 'string' && cfg.role ? cfg.role : 'pc1';
  const log = makeLogger(path.join(logDir, 'a2a.log'));
  for (const n of notes) log('[warn] ' + n);
  return { cfgPath, cfg, role, host, port, a2aPath, cardPath, logDir, tasksDir, token, log, notes };
}

function buildAgentCard(ctx) {
  const url = 'http://' + ctx.host + ':' + ctx.port + (ctx.a2aPath === '/' ? '/' : ctx.a2aPath);
  return {
    name: SERVER_NAME + '-' + ctx.role,
    description: 'PC1↔PC2 协作层 A2A 通道（' + ctx.role + '）：本机自环可验证的 ping/回复与证据交换入口。',
    version: VERSION,
    protocolVersion: PROTOCOL_VERSION,
    url,
    capabilities: { streaming: false },
    defaultInputModes: ['text/plain'],
    defaultOutputModes: ['text/plain'],
    skills: [
      {
        id: 'collab-ping',
        name: '协作连通性探测',
        description: '发送 [ping] 文本，返回以 [pong] 开头的回复并带本机 role，用于 PC1↔PC2 双向连通性确认。',
        tags: ['ping', 'health', 'collab']
      },
      {
        id: 'evidence-exchange',
        name: '证据交换',
        description: '交换时序/综合报告等文本证据摘要；文件级证据走 MCP 通道的 read_file/write_file/sha256_file。',
        tags: ['evidence', 'report', 'audit']
      },
      {
        id: 'issue-fallback',
        name: 'Issue 回退',
        description: '对端离线时把协作请求降级为 GitHub issue 轮询（config.fallback），保证协作不中断。',
        tags: ['fallback', 'issue', 'offline']
      }
    ],
    securitySchemes: { bearer: { type: 'http', scheme: 'bearer' } },
    security: [{ bearer: [] }]
  };
}

function rpcError(id, code, message) {
  return { jsonrpc: '2.0', id: id === undefined ? null : id, error: { code, message } };
}

function normalizeMessage(msg, contextId) {
  return {
    kind: 'message',
    role: 'user',
    parts: msg.parts.map((p) => ({ kind: 'text', text: p.text })),
    messageId: typeof msg.messageId === 'string' && msg.messageId ? msg.messageId : crypto.randomUUID(),
    contextId
  };
}

function validateMessageParams(params) {
  const msg = params && typeof params === 'object' ? params.message : null;
  if (!msg || typeof msg !== 'object' || Array.isArray(msg)) return { error: 'params.message 缺失或不是对象' };
  if (msg.kind !== 'message') return { error: 'params.message.kind 必须为 "message"' };
  if (msg.role !== 'user') return { error: 'params.message.role 必须为 "user"' };
  if (!Array.isArray(msg.parts) || msg.parts.length === 0) return { error: 'params.message.parts 必须为非空数组' };
  for (const p of msg.parts) {
    if (!p || typeof p !== 'object' || p.kind !== 'text' || typeof p.text !== 'string') {
      return { error: 'params.message.parts[*] 必须为 {kind:"text", text:string}' };
    }
  }
  return { message: msg };
}

async function saveTask(ctx, task) {
  await fsp.mkdir(ctx.tasksDir, { recursive: true });
  await fsp.writeFile(path.join(ctx.tasksDir, task.id + '.json'), JSON.stringify(task, null, 2), 'utf8');
}

async function loadTask(ctx, id) {
  if (typeof id !== 'string' || !/^[A-Za-z0-9._-]+$/.test(id)) return null;
  try {
    const raw = await fsp.readFile(path.join(ctx.tasksDir, id + '.json'), 'utf8');
    return JSON.parse(raw);
  } catch { return null; }
}

function buildTask(ctx, params) {
  const message = params.message;
  const contextId = typeof message.contextId === 'string' && message.contextId ? message.contextId : crypto.randomUUID();
  const text = message.parts.map((p) => p.text).join('\n');
  const fromTag = SERVER_NAME + ' ' + VERSION;
  const replyText = text.includes('[ping]')
    ? '[pong] from ' + ctx.role + ' (' + fromTag + ')'
    : '[ack] from ' + ctx.role + ' (' + fromTag + ') received ' + Buffer.byteLength(text, 'utf8') + ' bytes';
  return {
    kind: 'task',
    id: crypto.randomUUID(),
    contextId,
    status: { state: 'completed', timestamp: new Date().toISOString() },
    artifacts: [{ artifactId: crypto.randomUUID(), name: 'reply', parts: [{ kind: 'text', text: replyText }] }],
    history: [normalizeMessage(message, contextId)]
  };
}

async function dispatch(ctx, body) {
  const id = body && typeof body === 'object' && !Array.isArray(body) && Object.prototype.hasOwnProperty.call(body, 'id') ? body.id : null;
  if (!body || typeof body !== 'object' || Array.isArray(body)) return rpcError(null, -32600, '无效请求：必须是 JSON-RPC 2.0 对象');
  if (body.jsonrpc !== '2.0') return rpcError(id, -32600, '无效请求：jsonrpc 必须为 "2.0"');
  const method = body.method;
  if (typeof method !== 'string' || !method) return rpcError(id, -32600, '无效请求：method 缺失');
  const params = body.params === undefined ? {} : body.params;

  if (method === 'message/send') {
    const v = validateMessageParams(params);
    if (v.error) return rpcError(id, -32602, '参数错误: ' + v.error);
    const task = buildTask(ctx, { message: v.message });
    await saveTask(ctx, task);
    ctx.log('[a2a] message/send task=' + task.id + ' state=completed');
    return { jsonrpc: '2.0', id, result: task };
  }
  if (method === 'tasks/get') {
    const tid = params && typeof params === 'object' ? params.id : undefined;
    if (typeof tid !== 'string' || !tid) return rpcError(id, -32602, '参数错误: params.id 必须为非空字符串');
    const task = await loadTask(ctx, tid);
    if (!task) return rpcError(id, -32602, '参数错误: 任务不存在 id=' + tid);
    ctx.log('[a2a] tasks/get task=' + tid + ' state=' + (task.status && task.status.state));
    return { jsonrpc: '2.0', id, result: task };
  }
  return rpcError(id, -32601, '未知方法: ' + method);
}

function bearerOf(req) {
  const h = req.headers['authorization'];
  if (typeof h !== 'string') return null;
  const m = /^Bearer\s+(.+)$/i.exec(h.trim());
  return m ? m[1].trim() : null;
}

function authOk(req, token) {
  const given = bearerOf(req);
  if (!given || !token) return false;
  const a = Buffer.from(given, 'utf8');
  const b = Buffer.from(token, 'utf8');
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) { reject(new Error('请求体过大')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function sendJson(res, status, payload) {
  const body = Buffer.from(JSON.stringify(payload), 'utf8');
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': body.length, 'cache-control': 'no-store' });
  res.end(body);
}

function createHandler(ctx) {
  const card = buildAgentCard(ctx);
  return async (req, res) => {
    let pathname = '/';
    try { pathname = new URL(req.url || '/', 'http://' + ctx.host + ':' + ctx.port).pathname; } catch { pathname = '/'; }

    if (req.method === 'GET' && pathname === ctx.cardPath) {
      ctx.log('[a2a] GET agent card 200');
      sendJson(res, 200, card);
      return;
    }
    const isRpcPath = req.method === 'POST' && (pathname === ctx.a2aPath || (ctx.a2aPath === '/' && pathname === ''));
    if (isRpcPath) {
      if (!authOk(req, ctx.token.token)) {
        ctx.log('[a2a] POST ' + pathname + ' 401 unauthorized');
        sendJson(res, 401, rpcError(null, -32001, '未认证：Bearer token 缺失或无效'));
        return;
      }
      let raw = '';
      try { raw = await readBody(req, 2 * 1024 * 1024); } catch (e) {
        ctx.log('[a2a] POST 413 ' + e.message);
        sendJson(res, 413, rpcError(null, -32600, '请求体过大'));
        return;
      }
      let body;
      try { body = JSON.parse(raw); } catch {
        ctx.log('[a2a] POST 400 解析失败');
        sendJson(res, 400, rpcError(null, -32700, '解析错误：请求体不是合法 JSON'));
        return;
      }
      const out = await dispatch(ctx, body);
      sendJson(res, 200, out);
      return;
    }
    if (req.method === 'GET' || req.method === 'POST') {
      ctx.log('[a2a] ' + req.method + ' ' + pathname + ' 404');
      sendJson(res, 404, rpcError(null, -32004, '未找到路径: ' + pathname));
      return;
    }
    ctx.log('[a2a] ' + req.method + ' ' + pathname + ' 405');
    sendJson(res, 405, rpcError(null, -32005, '方法不允许: ' + req.method));
  };
}

async function runSelftest(ctx) {
  const results = [];
  const check = (name, fn) => {
    try {
      const r = fn();
      if (r === false) throw new Error('断言为 false');
      results.push([name, true, '']);
    } catch (e) {
      results.push([name, false, e && e.message ? e.message : String(e)]);
    }
  };
  const checkAsync = async (name, fn) => {
    try {
      const r = await fn();
      if (r === false) throw new Error('断言为 false');
      results.push([name, true, '']);
    } catch (e) {
      results.push([name, false, e && e.message ? e.message : String(e)]);
    }
  };

  check('config-load', () => {
    if (!ctx.cfg || typeof ctx.cfg !== 'object') throw new Error('配置不是对象');
    if (!ctx.role) throw new Error('role 为空');
    return true;
  });
  check('agent-card', () => {
    const c = buildAgentCard(ctx);
    const need = ['name', 'description', 'url'];
    for (const k of need) if (!c[k] || typeof c[k] !== 'string') throw new Error('AgentCard.' + k + ' 为空');
    if (c.version !== '0.1.0') throw new Error('version 必须为 0.1.0');
    if (c.protocolVersion !== '0.2.0') throw new Error('protocolVersion 必须为 0.2.0');
    if (!c.capabilities || c.capabilities.streaming !== false) throw new Error('capabilities.streaming 必须为 false');
    if (JSON.stringify(c.defaultInputModes) !== '["text/plain"]') throw new Error('defaultInputModes 必须为 ["text/plain"]');
    if (JSON.stringify(c.defaultOutputModes) !== '["text/plain"]') throw new Error('defaultOutputModes 必须为 ["text/plain"]');
    if (!Array.isArray(c.skills) || c.skills.length < 3) throw new Error('skills 少于 3 条');
    for (const s of c.skills) {
      for (const k of ['id', 'name', 'description']) if (!s[k]) throw new Error('skill.' + k + ' 缺失');
      if (!Array.isArray(s.tags) || s.tags.length === 0) throw new Error('skill.tags 缺失');
    }
    const ids = c.skills.map((s) => s.id);
    for (const need2 of ['collab-ping', 'evidence-exchange', 'issue-fallback']) {
      if (!ids.includes(need2)) throw new Error('缺少 skill: ' + need2);
    }
    if (!c.securitySchemes || !c.securitySchemes.bearer || c.securitySchemes.bearer.type !== 'http' || c.securitySchemes.bearer.scheme !== 'bearer') {
      throw new Error('securitySchemes.bearer 非法');
    }
    if (JSON.stringify(c.security) !== '[{"bearer":[]}]') throw new Error('security 必须为 [{bearer:[]}]');
    return true;
  });
  check('token', () => {
    if (!ctx.token.token || ctx.token.token.length < 16) throw new Error('token 为空或过短');
    if (!fs.existsSync(ctx.token.file)) throw new Error('token 文件不存在: ' + ctx.token.file);
    return true;
  });
  await checkAsync('tasks-dir', async () => {
    await fsp.mkdir(ctx.tasksDir, { recursive: true });
    const probe = path.join(ctx.tasksDir, '.selftest-' + process.pid + '.tmp');
    await fsp.writeFile(probe, 'ok', 'utf8');
    const back = await fsp.readFile(probe, 'utf8');
    await fsp.rm(probe, { force: true });
    if (back !== 'ok') throw new Error('任务目录读写不一致');
    return true;
  });
  let sentTaskId = null;
  await checkAsync('message-send', async () => {
    const out = await dispatch(ctx, {
      jsonrpc: '2.0', id: 1, method: 'message/send',
      params: { message: { kind: 'message', role: 'user', parts: [{ kind: 'text', text: '[ping] selftest' }], messageId: 'selftest-' + process.pid } }
    });
    if (out.error) throw new Error('返回错误: ' + JSON.stringify(out.error));
    const t = out.result;
    if (!t || t.kind !== 'task') throw new Error('result.kind 必须为 task');
    if (!t.status || t.status.state !== 'completed') throw new Error('status.state 必须为 completed');
    if (!t.status.timestamp) throw new Error('status.timestamp 缺失');
    if (!Array.isArray(t.artifacts) || t.artifacts.length === 0) throw new Error('artifacts 缺失');
    if (t.artifacts[0].name !== 'reply') throw new Error('artifact.name 必须为 reply');
    const reply = t.artifacts[0].parts[0].text;
    if (!reply.startsWith('[pong]')) throw new Error('回复必须以 [pong] 开头，实际: ' + reply);
    if (!reply.includes('from ' + ctx.role + ' (team-link 0.1.0)')) throw new Error('回复未带本机 role，实际: ' + reply);
    if (!Array.isArray(t.history) || t.history.length !== 1) throw new Error('history 必须含原 message');
    const onDisk = path.join(ctx.tasksDir, t.id + '.json');
    if (!fs.existsSync(onDisk)) throw new Error('任务未持久化: ' + onDisk);
    sentTaskId = t.id;
    return true;
  });
  await checkAsync('tasks-get', async () => {
    if (!sentTaskId) throw new Error('前置 message/send 未产生 id');
    const back = await dispatch(ctx, { jsonrpc: '2.0', id: 2, method: 'tasks/get', params: { id: sentTaskId } });
    if (back.error) throw new Error('返回错误: ' + JSON.stringify(back.error));
    if (back.result.id !== sentTaskId) throw new Error('id 不一致');
    if (back.result.status.state !== 'completed') throw new Error('state 不一致');
    await fsp.rm(path.join(ctx.tasksDir, sentTaskId + '.json'), { force: true });
    return true;
  });
  await checkAsync('rpc-unknown-method', async () => {
    const out = await dispatch(ctx, { jsonrpc: '2.0', id: 3, method: 'no/such' });
    if (!out.error || out.error.code !== -32601) throw new Error('未知方法必须返回 -32601');
    return true;
  });
  await checkAsync('rpc-invalid-params', async () => {
    const a = await dispatch(ctx, { jsonrpc: '2.0', id: 4, method: 'message/send', params: {} });
    if (!a.error || a.error.code !== -32602) throw new Error('缺 params.message 必须返回 -32602');
    const b = await dispatch(ctx, { jsonrpc: '2.0', id: 5, method: 'tasks/get', params: {} });
    if (!b.error || b.error.code !== -32602) throw new Error('缺 params.id 必须返回 -32602');
    return true;
  });
  check('auth', () => {
    const req = (h) => ({ headers: h ? { authorization: h } : {} });
    if (authOk(req(null), ctx.token.token)) throw new Error('无 token 必须拒绝');
    if (authOk(req('Bearer wrong-token'), ctx.token.token)) throw new Error('错误 token 必须拒绝');
    if (!authOk(req('Bearer ' + ctx.token.token), ctx.token.token)) throw new Error('正确 token 必须通过');
    return true;
  });

  // tasks-get 的异步检查被嵌在上面，若 message-send 失败则不重复打印
  let failed = 0;
  const printed = new Set();
  for (const [name, ok, msg] of results) {
    if (printed.has(name)) continue;
    printed.add(name);
    if (ok) console.log('PASS ' + name);
    else { failed += 1; console.log('FAIL: ' + name + ' 原因: ' + msg); }
  }
  const overall = failed === 0;
  console.log(overall ? 'PASS a2a-selftest' : 'FAIL: a2a-selftest');
  const tail = results.filter((r) => !r[1]).length;
  ctx.log('[a2a] selftest 完成 ok=' + overall + ' failCount=' + tail);
  return overall;
}

async function startHttp(ctx) {
  const server = http.createServer(createHandler(ctx));
  server.on('error', (e) => {
    console.error('[a2a] 监听失败: ' + (e && e.message ? e.message : String(e)));
    ctx.log('[a2a] listen error ' + (e && e.message));
    process.exit(1);
  });
  await new Promise((resolve) => server.listen(ctx.port, ctx.host, resolve));
  const url = 'http://' + ctx.host + ':' + ctx.port + ctx.a2aPath;
  console.error('[a2a] listening ' + url + ' (agentCard ' + ctx.cardPath + ')');
  ctx.log('[a2a] listening ' + url + ' role=' + ctx.role + ' config=' + ctx.cfgPath);
  const stop = () => {
    ctx.log('[a2a] shutdown');
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 1500).unref();
  };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
  process.on('exit', () => { try { server.close(); } catch { /* ignore */ } });
}

async function main() {
  const args = parseArgv(process.argv.slice(2));
  const ctx = buildContext(args);
  for (const n of ctx.notes) console.error('[提示] ' + n);
  if (args.selftest) {
    const ok = await runSelftest(ctx);
    process.exit(ok ? 0 : 1);
  }
  if (!args.http) ctx.log('[a2a] 未显式传 --http，按 HTTP 模式启动');
  await startHttp(ctx);
}

main().catch((e) => {
  console.error('FAIL: 启动失败 ' + (e && e.message ? e.message : String(e)));
  process.exit(1);
});