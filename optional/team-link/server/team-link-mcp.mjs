#!/usr/bin/env node
// team-link MCP 服务端（阶段 B，单机自环；stdio 与 HTTP 共用一套工具）。
// stdio: node server/team-link-mcp.mjs --stdio
// HTTP : node server/team-link-mcp.mjs --http --port 18790 --config <cfg>
// 自检 : node server/team-link-mcp.mjs --selftest --config <cfg>   （不监听）
// 默认只绑 127.0.0.1；跨机要显式 --host + --allow-lan，且永不接受 192.168.1.0/24。
// 零第三方依赖，仅用 Node 标准库。stdout 只输出协议数据。
import http from 'node:http';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import net from 'node:net';
import crypto from 'node:crypto';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

const SERVER_DIR = path.dirname(fileURLToPath(import.meta.url));
const BUNDLE_DIR = path.resolve(SERVER_DIR, '..');
const SERVER_NAME = 'team-link';
/** 版本以 package.json 为唯一真值（曾因写死 0.1.0 与包版本对不上，跨机核对时误导过）。 */
const VERSION = (() => {
  try {
    const pkg = JSON.parse(fs.readFileSync(path.join(BUNDLE_DIR, 'package.json'), 'utf8'));
    return typeof pkg.version === 'string' && pkg.version ? pkg.version : '0.0.0';
  } catch {
    return '0.0.0';
  }
})();
/** 两板私有链路：同 IP、同 MAC，打过去会命中错误的那块板且不报错 —— 任何模式下都拒绝。 */
const FORBIDDEN_CIDR_PREFIX = '192.168.1.';
const DEFAULT_PROTOCOL = '2025-06-18';
const LOOPBACK = '127.0.0.1';
const STARTED_AT = Date.now();

function printHelp() {
  console.error([
    '用法: node server/team-link-mcp.mjs --stdio',
    '      node server/team-link-mcp.mjs --http --port <端口> --config <配置文件>',
    '      node server/team-link-mcp.mjs --selftest --config <配置文件>',
    '说明: stdio 为换行分隔 NDJSON（DSH 插件用）；HTTP 为 POST /mcp 单请求单响应；仅监听 127.0.0.1。'
  ].join('\n'));
}

function parseArgv(argv) {
  const out = { mode: null, selftest: false, port: null, config: null, host: null, allowLan: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--stdio') out.mode = 'stdio';
    else if (a === '--http') out.mode = 'http';
    else if (a === '--selftest') out.selftest = true;
    else if (a === '--allow-lan') out.allowLan = true;
    else if (a === '--port') out.port = Number(argv[i += 1]);
    else if (a.startsWith('--port=')) out.port = Number(a.slice('--port='.length));
    else if (a === '--host') out.host = argv[i += 1];
    else if (a.startsWith('--host=')) out.host = a.slice('--host='.length);
    else if (a === '--config') out.config = argv[i += 1];
    else if (a.startsWith('--config=')) out.config = a.slice('--config='.length);
    else if (a === '--help' || a === '-h') { printHelp(); process.exit(0); }
    else { console.error('未知参数: ' + a); printHelp(); process.exit(2); }
  }
  return out;
}

/**
 * 决定实际绑定的地址。安全默认：默认回环；要绑非回环必须**显式** opt-in，且拒绝板卡私有网段。
 * @param {object} args - parseArgv 结果。
 * @param {string} cfgHost - 配置里的 mcp.host。
 * @param {string[]} notes - 收集告警（进日志）。
 * @returns {string} 实际绑定地址。
 */
function resolveBindHost(args, cfgHost, notes) {
  const optIn = args.allowLan === true || process.env.TEAM_LINK_ALLOW_LAN === '1';
  let host = (typeof args.host === 'string' && args.host.trim() !== '')
    ? args.host.trim()
    : (typeof cfgHost === 'string' && cfgHost.trim() !== '' ? cfgHost.trim() : LOOPBACK);
  if (host === 'localhost' || host === '::1' || host === '0.0.0.0') {
    if (host === '0.0.0.0') notes.push('拒绝绑 0.0.0.0（会暴露到所有网卡），已强制改为 ' + LOOPBACK);
    host = LOOPBACK;   // 注意：0.0.0.0 也必须真的改写，否则日志说"已拒"，实际却绑了所有网卡
  }
  if (host === LOOPBACK) return LOOPBACK;
  if (host.startsWith(FORBIDDEN_CIDR_PREFIX)) {
    notes.push('拒绝绑 ' + host + '：192.168.1.0/24 是两板私有链路（同 IP/同 MAC），已强制改为 ' + LOOPBACK);
    return LOOPBACK;
  }
  if (!optIn) {
    notes.push('host=' + host + ' 非回环但未显式放开（缺 --allow-lan / TEAM_LINK_ALLOW_LAN=1），已强制改为 ' + LOOPBACK);
    return LOOPBACK;
  }
  notes.push('已按显式 opt-in 绑非回环地址 ' + host + '（跨机模式）');
  return host;
}

function resolveConfigPath(given) {
  const pick = given || process.env.TEAM_LINK_CONFIG || '';
  if (pick) return path.isAbsolute(pick) ? pick : path.resolve(BUNDLE_DIR, pick);  const primary = path.join(BUNDLE_DIR, 'state', 'config.json');
  if (fs.existsSync(primary)) return primary;
  const fallback = path.join(BUNDLE_DIR, 'state', 'config.example.json');
  if (fs.existsSync(fallback)) return fallback;
  throw new Error('未找到配置文件: ' + primary);
}

function loadConfig(cfgPath) {
  let cfg;
  try { cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8')); } catch (e) { throw new Error('配置文件不可读或非法 JSON: ' + e.message); }
  if (!cfg || typeof cfg !== 'object') throw new Error('配置文件内容必须为对象');
  return cfg;
}

function tokenCandidates(cfgPath, tokenFile) {
  const list = [];
  if (typeof tokenFile === 'string' && tokenFile) {
    if (path.isAbsolute(tokenFile)) list.push(tokenFile);
    else {
      list.push(path.resolve(BUNDLE_DIR, tokenFile));
      list.push(path.resolve(path.dirname(cfgPath), tokenFile));
      list.push(path.resolve(process.cwd(), tokenFile));
    }
  }
  return [...new Set(list)];
}

function ensureToken(cfgPath, tokenFile, notes) {
  const cands = tokenCandidates(cfgPath, tokenFile);
  if (cands.length === 0) throw new Error('配置缺少 mcp.tokenFile');
  for (const c of cands) {
    try {
      const t = fs.readFileSync(c, 'utf8').trim();
      if (t) return { token: t, file: c, created: false };
    } catch { /* 继续 */ }
  }
  const target = cands[0];
  const token = crypto.randomBytes(24).toString('hex');
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, token + '\n', 'utf8');
  notes.push('已生成 token 文件: ' + target);
  return { token, file: target, created: true };
}

function makeLogger(file) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  return (line) => {
    const text = new Date().toISOString() + ' ' + line + '\n';
    try { fs.appendFileSync(file, text, 'utf8'); } catch { /* 忽略 */ }
    try { process.stderr.write('[mcp] ' + line + '\n'); } catch { /* 忽略 */ }
  };
}

function buildContext(args) {
  const cfgPath = resolveConfigPath(args.config);
  const cfg = loadConfig(cfgPath);
  const notes = [];
  const mcpCfg = cfg.mcp || {};
  const host = resolveBindHost(args, mcpCfg.host, notes);
  const port = Number.isFinite(args.port) && args.port > 0 ? args.port : Number(mcpCfg.port || 18790);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('端口非法: ' + port);
  const mcpPath = typeof mcpCfg.path === 'string' && mcpCfg.path ? mcpCfg.path : '/mcp';
  const logDirRel = typeof cfg.logDir === 'string' && cfg.logDir ? cfg.logDir : 'logs';
  const logDir = path.isAbsolute(logDirRel) ? logDirRel : path.resolve(BUNDLE_DIR, logDirRel);
  const token = ensureToken(cfgPath, mcpCfg.tokenFile || 'state/mcp.token', notes);
  const role = typeof cfg.role === 'string' && cfg.role ? cfg.role : 'pc1';
  const roots = Array.isArray(cfg.roots) ? cfg.roots.filter((r) => r && typeof r.id === 'string' && typeof r.path === 'string') : [];
  const log = makeLogger(path.join(logDir, 'mcp.log'));
  for (const n of notes) log('[warn] ' + n);
  return { cfgPath, cfg, role, host, port, mcpPath, logDir, token, roots, log, notes };
}

// ---------- 路径安全 ----------
function isAbsoluteLike(p) {
  if (path.isAbsolute(p)) return true;
  if (/^[a-zA-Z]:/.test(p)) return true;
  if (p.startsWith('\\\\') || p.startsWith('//')) return true;
  if (p.startsWith('/') || p.startsWith('\\')) return true;
  return false;
}

function hasParentSegment(p) {
  return p.split(/[\\/]+/).some((seg) => seg === '..');
}

function isInside(parent, child) {
  const base = parent.endsWith(path.sep) ? parent : parent + path.sep;
  return child === parent || child.toLowerCase().startsWith(base.toLowerCase());
}

// realpath 到“最深的已存在祖先”，用于拦截符号链接/目录联接越权。
async function realpathDeepest(target) {
  let cur = target;
  const rest = [];
  for (;;) {
    try {
      const real = await fsp.realpath(cur);
      return rest.length === 0 ? real : path.join(real, ...rest.slice().reverse());
    } catch {
      const parent = path.dirname(cur);
      if (parent === cur) return target;
      rest.push(path.basename(cur));
      cur = parent;
    }
  }
}

function pickRoot(ctx, rootId) {
  if (typeof rootId !== 'string' || !rootId) throw new Error('参数 root 必须为非空字符串；合法 id: ' + ctx.roots.map((r) => r.id).join(', '));
  const root = ctx.roots.find((r) => r.id === rootId);
  if (!root) throw new Error('未知 root "' + rootId + '"，合法 id: ' + ctx.roots.map((r) => r.id).join(', '));
  return root;
}

async function resolveSafe(ctx, rootId, rel) {
  const root = pickRoot(ctx, rootId);
  if (typeof rel !== 'string' || rel.length === 0) throw new Error('参数 path 必须为非空字符串');
  if (isAbsoluteLike(rel)) throw new Error('拒绝绝对路径: ' + rel + '（只允许 root 内相对路径）');
  if (hasParentSegment(rel)) throw new Error('拒绝包含 .. 段的路径: ' + rel);
  let rootReal;
  try { rootReal = await fsp.realpath(root.path); } catch {
    throw new Error('root "' + root.id + '" 的目录不可访问: ' + root.path);
  }
  const abs = path.resolve(rootReal, rel);
  if (!isInside(rootReal, abs)) throw new Error('越权：解析后不在 root "' + root.id + '" 内: ' + abs);
  const real = await realpathDeepest(abs);
  if (!isInside(rootReal, real)) throw new Error('越权：realpath 后不在 root "' + root.id + '" 内: ' + real);
  return { root, abs, real, rel: rel.split(/[\\/]+/).join('/') };
}

function sha256Buf(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

function probeListening(host, port, timeoutMs) {
  return new Promise((resolve) => {
    const sock = new net.Socket();
    let done = false;
    const finish = (v) => { if (done) return; done = true; try { sock.destroy(); } catch { /* 忽略 */ } resolve(v); };
    sock.setTimeout(timeoutMs);
    sock.once('connect', () => finish(true));
    sock.once('timeout', () => finish(false));
    sock.once('error', () => finish(false));
    try { sock.connect(port, host); } catch { finish(false); }
  });
}

// ---------- 工具实现 ----------
const TOOLS = [
  {
    name: 'list_roots',
    description: '列出本机已授权的协作根目录（只含 config.roots 的项，一项不多）。',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false }
  },
  {
    name: 'read_file',
    description: '读取 root 内文件的文本内容，返回 bytes 与 sha256。',
    inputSchema: {
      type: 'object',
      properties: { root: { type: 'string', description: 'root id' }, path: { type: 'string', description: 'root 内相对路径' } },
      required: ['root', 'path'],
      additionalProperties: false
    }
  },
  {
    name: 'write_file',
    description: '写入 root 内文件（自动建父目录），返回 bytes 与 sha256。',
    inputSchema: {
      type: 'object',
      properties: { root: { type: 'string' }, path: { type: 'string' }, content: { type: 'string' } },
      required: ['root', 'path', 'content'],
      additionalProperties: false
    }
  },
  {
    name: 'sha256_file',
    description: '计算 root 内文件的 sha256 与字节数，不返回内容。',
    inputSchema: {
      type: 'object',
      properties: { root: { type: 'string' }, path: { type: 'string' } },
      required: ['root', 'path'],
      additionalProperties: false
    }
  },
  {
    name: 'collab_status',
    description: '返回本机协作状态：role、pid、uptimeSec、a2a/mcp 监听情况、roots 数量、peer 与 fallback 配置。',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false }
  }
];
const TOOL_NAMES = TOOLS.map((t) => t.name);

async function toolListRoots(ctx) {
  ctx.log('[mcp] tool list_roots');
  return { roots: ctx.roots.map((r) => ({ id: r.id, path: r.path, mode: r.mode || 'rw' })) };
}

async function toolReadFile(ctx, a) {
  const { root, abs, rel } = await resolveSafe(ctx, a.root, a.path);
  const buf = await fsp.readFile(abs);
  ctx.log('[mcp] tool read_file root=' + root.id + ' path=' + rel + ' bytes=' + buf.length);
  return { root: root.id, path: rel, bytes: buf.length, sha256: sha256Buf(buf), content: buf.toString('utf8') };
}

async function toolWriteFile(ctx, a) {
  if (typeof a.content !== 'string') throw new Error('参数 content 必须为字符串');
  const { root, abs, rel } = await resolveSafe(ctx, a.root, a.path);
  await fsp.mkdir(path.dirname(abs), { recursive: true });
  const buf = Buffer.from(a.content, 'utf8');
  await fsp.writeFile(abs, buf);
  ctx.log('[mcp] tool write_file root=' + root.id + ' path=' + rel + ' bytes=' + buf.length);
  return { root: root.id, path: rel, bytes: buf.length, sha256: sha256Buf(buf) };
}

async function toolSha256File(ctx, a) {
  const { root, abs, rel } = await resolveSafe(ctx, a.root, a.path);
  const buf = await fsp.readFile(abs);
  ctx.log('[mcp] tool sha256_file root=' + root.id + ' path=' + rel + ' bytes=' + buf.length);
  return { root: root.id, path: rel, bytes: buf.length, sha256: sha256Buf(buf) };
}

async function toolCollabStatus(ctx) {
  const a2aCfg = ctx.cfg.a2a || {};
  const mcpCfg = ctx.cfg.mcp || {};
  const a2aPort = Number(a2aCfg.port || 7310);
  const mcpPort = Number(mcpCfg.port || 18790);
  const a2aHost = typeof a2aCfg.host === 'string' && a2aCfg.host ? a2aCfg.host : LOOPBACK;
  const mcpHost = typeof mcpCfg.host === 'string' && mcpCfg.host ? mcpCfg.host : LOOPBACK;
  const [a2aUp, mcpUp] = await Promise.all([probeListening(LOOPBACK, a2aPort, 400), probeListening(LOOPBACK, mcpPort, 400)]);
  ctx.log('[mcp] tool collab_status a2a=' + a2aUp + ' mcp=' + mcpUp);
  return {
    role: ctx.role,
    pid: process.pid,
    uptimeSec: Math.round((Date.now() - STARTED_AT) / 1000),
    a2a: { url: 'http://' + a2aHost + ':' + a2aPort + (a2aCfg.path || '/'), listening: a2aUp },
    mcp: { url: 'http://' + mcpHost + ':' + mcpPort + (mcpCfg.path || '/mcp'), listening: mcpUp },
    roots: ctx.roots.length,
    peer: ctx.cfg.peer || null,
    fallback: ctx.cfg.fallback || null
  };
}

const RUNNERS = {
  list_roots: toolListRoots,
  read_file: toolReadFile,
  write_file: toolWriteFile,
  sha256_file: toolSha256File,
  collab_status: toolCollabStatus
};

function rpcError(id, code, message) {
  return { jsonrpc: '2.0', id: id === undefined ? null : id, error: { code, message } };
}

function ok(id, result) {
  return { jsonrpc: '2.0', id: id === undefined ? null : id, result };
}

async function toolResult(ctx, name, args) {
  const runner = RUNNERS[name];
  if (!runner) {
    return { content: [{ type: 'text', text: '错误：未知工具 "' + name + '"，可用工具: ' + TOOL_NAMES.join(', ') }], isError: true };
  }
  try {
    const payload = await runner(ctx, args || {});
    return { content: [{ type: 'text', text: JSON.stringify(payload, null, 2) }], structuredContent: payload, isError: false };
  } catch (e) {
    return { content: [{ type: 'text', text: '错误：' + (e && e.message ? e.message : String(e)) }], isError: true };
  }
}

// 返回 null 表示“通知，不回复”。
async function handleMessage(ctx, msg) {
  if (Array.isArray(msg)) return rpcError(null, -32600, '不支持批量请求');
  if (!msg || typeof msg !== 'object') return rpcError(null, -32600, '无效请求：必须是 JSON 对象');
  const method = msg.method;
  const params = msg.params && typeof msg.params === 'object' ? msg.params : {};
  const hasId = Object.prototype.hasOwnProperty.call(msg, 'id');
  if (typeof method !== 'string' || !method) return rpcError(hasId ? msg.id : null, -32600, '无效请求：method 缺失');
  if (!hasId && method.startsWith('notifications/')) {
    ctx.log('[mcp] 通知 ' + method);
    return null;
  }
  if (method === 'initialize') {
    const echoed = typeof params.protocolVersion === 'string' && params.protocolVersion ? params.protocolVersion : DEFAULT_PROTOCOL;
    ctx.log('[mcp] initialize protocolVersion=' + echoed);
    return ok(msg.id, {
      protocolVersion: echoed,
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: SERVER_NAME, version: VERSION }
    });
  }
  if (method === 'notifications/initialized') {
    ctx.log('[mcp] notifications/initialized');
    return null;
  }
  if (method === 'ping') return ok(msg.id, {});
  if (method === 'tools/list') {
    ctx.log('[mcp] tools/list');
    return ok(msg.id, { tools: TOOLS });
  }
  if (method === 'tools/call') {
    const name = params.name;
    if (typeof name !== 'string' || !name) return rpcError(msg.id, -32602, '参数错误: params.name 必须为非空字符串');
    const args = params.arguments === undefined ? {} : params.arguments;
    if (args === null || typeof args !== 'object' || Array.isArray(args)) return rpcError(msg.id, -32602, '参数错误: params.arguments 必须为对象');
    const result = await toolResult(ctx, name, args);
    return ok(msg.id, result);
  }
  return rpcError(msg.id, -32601, '未知方法: ' + method);
}

// ---------- stdio 传输 ----------
function startStdio(ctx) {
  const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  let chain = Promise.resolve();
  const write = (obj) => { process.stdout.write(JSON.stringify(obj) + '\n'); };
  rl.on('line', (line) => {
    const text = line.trim();
    if (!text) return;
    chain = chain.then(async () => {
      let msg;
      try { msg = JSON.parse(text); } catch {
        write(rpcError(null, -32700, '解析错误：不是合法 JSON'));
        return;
      }
      try {
        const out = await handleMessage(ctx, msg);
        if (out) write(out);
      } catch (e) {
        ctx.log('[mcp] stdio 处理异常 ' + (e && e.message));
        write(rpcError(null, -32603, '内部错误: ' + (e && e.message ? e.message : String(e))));
      }
    });
  });
  rl.on('close', () => {
    ctx.log('[mcp] stdio 关闭');
    chain.finally(() => process.exit(0));
  });
  ctx.log('[mcp] stdio 就绪 role=' + ctx.role + ' config=' + ctx.cfgPath);
}

// ---------- HTTP 传输 ----------
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

async function startHttp(ctx) {
  const server = http.createServer(async (req, res) => {
    let pathname = '/';
    try { pathname = new URL(req.url || '/', 'http://' + ctx.host + ':' + ctx.port).pathname; } catch { pathname = '/'; }
    if (pathname !== ctx.mcpPath) {
      ctx.log('[mcp] ' + req.method + ' ' + pathname + ' 404');
      sendJson(res, 404, rpcError(null, -32004, '未找到路径: ' + pathname));
      return;
    }
    if (req.method !== 'POST') {
      ctx.log('[mcp] ' + req.method + ' ' + pathname + ' 405');
      sendJson(res, 405, rpcError(null, -32005, '方法不允许: ' + req.method + '（本通道只接受 POST）'));
      return;
    }
    if (!authOk(req, ctx.token.token)) {
      ctx.log('[mcp] POST ' + pathname + ' 401 unauthorized');
      sendJson(res, 401, rpcError(null, -32001, '未认证：Bearer token 缺失或无效'));
      return;
    }
    let raw;
    try { raw = await readBody(req, 4 * 1024 * 1024); } catch (e) {
      sendJson(res, 413, rpcError(null, -32600, e.message));
      return;
    }
    let msg;
    try { msg = JSON.parse(raw); } catch {
      ctx.log('[mcp] POST 400 解析失败');
      sendJson(res, 400, rpcError(null, -32700, '解析错误：请求体不是合法 JSON'));
      return;
    }
    let out;
    try { out = await handleMessage(ctx, msg); } catch (e) {
      ctx.log('[mcp] 处理异常 ' + (e && e.message));
      sendJson(res, 500, rpcError(null, -32603, '内部错误: ' + (e && e.message ? e.message : String(e))));
      return;
    }
    if (out === null) {
      res.writeHead(202, { 'content-length': 0 });
      res.end();
      return;
    }
    sendJson(res, 200, out);
  });
  server.on('error', (e) => {
    console.error('[mcp] 监听失败: ' + (e && e.message ? e.message : String(e)));
    ctx.log('[mcp] listen error ' + (e && e.message));
    process.exit(1);
  });
  await new Promise((resolve) => server.listen(ctx.port, ctx.host, resolve));
  const url = 'http://' + ctx.host + ':' + ctx.port + ctx.mcpPath;
  console.error('[mcp] listening ' + url);
  ctx.log('[mcp] http listening ' + url + ' role=' + ctx.role + ' config=' + ctx.cfgPath);
  const stop = () => {
    ctx.log('[mcp] shutdown');
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 1500).unref();
  };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
}

// ---------- 自检 ----------
async function runSelftest(ctx) {
  const results = [];
  const check = async (name, fn) => {
    try {
      const r = await fn();
      if (r === false) throw new Error('断言为 false');
      results.push([name, true, '']);
    } catch (e) {
      results.push([name, false, e && e.message ? e.message : String(e)]);
    }
  };

  await check('config-load', () => {
    if (!ctx.role) throw new Error('role 为空');
    if (ctx.roots.length === 0) throw new Error('config.roots 为空');
    return true;
  });
  await check('token', () => {
    if (!ctx.token.token || ctx.token.token.length < 16) throw new Error('token 为空或过短');
    if (!fs.existsSync(ctx.token.file)) throw new Error('token 文件不存在');
    return true;
  });
  await check('tools-list', async () => {
    const out = await handleMessage(ctx, { jsonrpc: '2.0', id: 1, method: 'tools/list' });
    const names = out.result.tools.map((t) => t.name);
    const need = ['list_roots', 'read_file', 'write_file', 'sha256_file', 'collab_status'];
    for (const n of need) if (!names.includes(n)) throw new Error('缺少工具: ' + n);
    if (names.length !== need.length) throw new Error('工具数必须为 5，实际 ' + names.length);
    return true;
  });
  await check('list_roots', async () => {
    const out = await handleMessage(ctx, { jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'list_roots', arguments: {} } });
    const roots = out.result.structuredContent.roots;
    const want = ctx.cfg.roots.map((r) => r.id).sort().join(',');
    const got = roots.map((r) => r.id).sort().join(',');
    if (want !== got) throw new Error('root 集合不一致 want=' + want + ' got=' + got);
    return true;
  });
  await check('path-escape-rejected', async () => {
    const a = await toolResult(ctx, 'read_file', { root: ctx.roots[0].id, path: '../x.txt' });
    if (!a.isError) throw new Error('.. 段未被拒绝');
    const b = await toolResult(ctx, 'read_file', { root: ctx.roots[0].id, path: 'C:\\Windows\\win.ini' });
    if (!b.isError) throw new Error('绝对路径未被拒绝');
    return true;
  });
  await check('unknown-root', async () => {
    const a = await toolResult(ctx, 'read_file', { root: 'no-such-root', path: 'a.txt' });
    if (!a.isError) throw new Error('未知 root 未被拒绝');
    const text = a.content[0].text;
    for (const r of ctx.roots) if (!text.includes(r.id)) throw new Error('错误信息未列出合法 id');
    return true;
  });
  await check('io-roundtrip', async () => {
    const usable = [];
    for (const r of ctx.roots) {
      try { await fsp.access(r.path); usable.push(r); } catch { /* 不存在则跳过 */ }
    }
    if (usable.length === 0) throw new Error('没有任何可写的 root 目录存在，无法自检 IO');
    const root = usable[0];
    const rel = '.selftest/mcp-selftest-' + process.pid + '.txt';
    const payload = '自检内容 team-link selftest\n';
    const w = await toolResult(ctx, 'write_file', { root: root.id, path: rel, content: payload });
    if (w.isError) throw new Error('write_file 失败: ' + w.content[0].text);
    const r = await toolResult(ctx, 'read_file', { root: root.id, path: rel });
    if (r.isError) throw new Error('read_file 失败: ' + r.content[0].text);
    if (r.structuredContent.content !== payload) throw new Error('读回内容不一致');
    const s = await toolResult(ctx, 'sha256_file', { root: root.id, path: rel });
    const local = crypto.createHash('sha256').update(Buffer.from(payload, 'utf8')).digest('hex');
    if (s.structuredContent.sha256 !== local) throw new Error('sha256 不一致');
    if (s.structuredContent.bytes !== Buffer.byteLength(payload, 'utf8')) throw new Error('bytes 不一致');
    await fsp.rm(path.resolve(usable[0].path, '.selftest'), { recursive: true, force: true });
    return true;
  });
  await check('collab_status', async () => {
    const out = await handleMessage(ctx, { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'collab_status', arguments: {} } });
    const s = out.result.structuredContent;
    for (const k of ['role', 'pid', 'uptimeSec']) if (s[k] === undefined) throw new Error('collab_status 缺字段 ' + k);
    if (!s.a2a || typeof s.a2a.listening !== 'boolean') throw new Error('collab_status.a2a.listening 非法');
    if (!s.mcp || typeof s.mcp.listening !== 'boolean') throw new Error('collab_status.mcp.listening 非法');
    if (s.roots !== ctx.cfg.roots.length) throw new Error('collab_status.roots 数量不一致');
    return true;
  });
  await check('protocol-echo', async () => {
    const out = await handleMessage(ctx, { jsonrpc: '2.0', id: 4, method: 'initialize', params: { protocolVersion: '2025-06-18' } });
    if (out.result.protocolVersion !== '2025-06-18') throw new Error('protocolVersion 未回显');
    if (!out.result.capabilities || !out.result.capabilities.tools || out.result.capabilities.tools.listChanged !== false) throw new Error('capabilities 非法');
    if (out.result.serverInfo.name !== 'team-link' || out.result.serverInfo.version !== VERSION) throw new Error('serverInfo 非法（version 应为 ' + VERSION + '，实际 ' + out.result.serverInfo.version + '）');
    const dft = await handleMessage(ctx, { jsonrpc: '2.0', id: 5, method: 'initialize', params: {} });
    if (dft.result.protocolVersion !== DEFAULT_PROTOCOL) throw new Error('缺省 protocolVersion 必须为 ' + DEFAULT_PROTOCOL);
    return true;
  });
  await check('notify-no-reply', async () => {
    const out = await handleMessage(ctx, { jsonrpc: '2.0', method: 'notifications/initialized' });
    if (out !== null) throw new Error('通知不得回复');
    return true;
  });

  let failed = 0;
  for (const [name, good, msg] of results) {
    if (good) console.log('PASS ' + name);
    else { failed += 1; console.log('FAIL: ' + name + ' 原因: ' + msg); }
  }
  const overall = failed === 0;
  console.log(overall ? 'PASS mcp-selftest' : 'FAIL: mcp-selftest');
  ctx.log('[mcp] selftest 完成 ok=' + overall + ' failCount=' + failed);
  return overall;
}

async function main() {
  const args = parseArgv(process.argv.slice(2));
  const ctx = buildContext(args);
  for (const n of ctx.notes) console.error('[提示] ' + n);
  if (args.selftest) {
    const good = await runSelftest(ctx);
    process.exit(good ? 0 : 1);
  }
  const mode = args.mode || 'stdio';
  if (mode === 'stdio') startStdio(ctx);
  else await startHttp(ctx);
}

main().catch((e) => {
  console.error('FAIL: 启动失败 ' + (e && e.message ? e.message : String(e)));
  process.exit(1);
});
