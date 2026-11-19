#!/usr/bin/env node
// A2A 自环客户端：自行拉起服务端 -> 五步验证 -> 关闭服务端。
// 用法: node client/a2a-selfloop.mjs --config <cfg> [--port 7310]
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const CLIENT_DIR = path.dirname(fileURLToPath(import.meta.url));
const BUNDLE_DIR = path.resolve(CLIENT_DIR, '..');
const LOOPBACK = '127.0.0.1';
const SERVER = path.join(BUNDLE_DIR, 'server', 'team-link-a2a.mjs');

function parseArgv(argv) {
  const out = { config: null, port: null };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--config') out.config = argv[i += 1];
    else if (a.startsWith('--config=')) out.config = a.slice('--config='.length);
    else if (a === '--port') out.port = Number(argv[i += 1]);
    else if (a.startsWith('--port=')) out.port = Number(a.slice('--port='.length));
    else if (a === '--help' || a === '-h') {
      console.error('用法: node client/a2a-selfloop.mjs --config <cfg> [--port 7310]');
      console.error('说明: 客户端自行启动并关闭 team-link-a2a 服务端（仅 127.0.0.1）。');
      process.exit(0);
    } else { console.error('未知参数: ' + a); process.exit(2); }
  }
  return out;
}

function resolveConfigPath(given) {
  const pick = given || process.env.TEAM_LINK_CONFIG || '';
  if (pick) return path.isAbsolute(pick) ? pick : path.resolve(BUNDLE_DIR, pick);
  const primary = path.join(BUNDLE_DIR, 'state', 'config.json');
  if (fs.existsSync(primary)) return primary;
  const fallback = path.join(BUNDLE_DIR, 'state', 'config.example.json');
  if (fs.existsSync(fallback)) { console.error('[提示] 未找到 state/config.json，回落到 config.example.json'); return fallback; }
  throw new Error('未找到配置文件: ' + primary);
}

function readConfig(cfgPath) {
  try { return JSON.parse(fs.readFileSync(cfgPath, 'utf8')); } catch (e) { throw new Error('配置文件不可读或非法 JSON: ' + e.message); }
}

function tokenPath(cfgPath, tokenFile) {
  if (typeof tokenFile !== 'string' || !tokenFile) return null;
  if (path.isAbsolute(tokenFile)) return tokenFile;
  const cands = [path.resolve(BUNDLE_DIR, tokenFile), path.resolve(path.dirname(cfgPath), tokenFile), path.resolve(process.cwd(), tokenFile)];
  for (const c of cands) if (fs.existsSync(c)) return c;
  return cands[0];
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitExit(child, ms) {
  if (child.exitCode !== null || child.signalCode !== null) return true;
  return await new Promise((resolve) => {
    const t = setTimeout(() => resolve(false), ms);
    child.once('exit', () => { clearTimeout(t); resolve(true); });
  });
}

async function getJson(url, init) {
  const res = await fetch(url, init);
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { json = null; }
  return { status: res.status, json, text };
}

async function main() {
  const args = parseArgv(process.argv.slice(2));
  const cfgPath = resolveConfigPath(args.config);
  const cfg = readConfig(cfgPath);
  const a2aCfg = cfg.a2a || {};
  const port = Number.isFinite(args.port) && args.port > 0 ? args.port : Number(a2aCfg.port || 7310);
  const cardPath = a2aCfg.agentCardPath || '/.well-known/agent.json';
  const rpcPath = a2aCfg.path || '/';
  const base = 'http://' + LOOPBACK + ':' + port;
  const cardUrl = base + cardPath;
  const rpcUrl = base + (rpcPath === '/' ? '/' : rpcPath);

  if (!fs.existsSync(SERVER)) throw new Error('服务端文件不存在: ' + SERVER);
  console.log('== A2A 自环开始 ==');
  console.log('配置: ' + cfgPath);
  console.log('服务端: ' + SERVER + ' --http --port ' + port);

  const child = spawn(process.execPath, [SERVER, '--http', '--port', String(port), '--config', cfgPath], {
    cwd: BUNDLE_DIR, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true
  });
  const logTail = [];
  const keep = (d) => { logTail.push(d.toString()); if (logTail.length > 40) logTail.shift(); };
  child.stdout.on('data', keep);
  child.stderr.on('data', keep);

  let failed = false;
  const fail = (step, msg) => { failed = true; console.log('FAIL: ' + step + ' 原因: ' + msg); };
  const pass = (step, extra) => console.log('PASS ' + step + (extra ? ' — ' + extra : ''));

  try {
    // 等端口就绪
    let ready = false;
    for (let i = 0; i < 120; i += 1) {
      if (child.exitCode !== null) throw new Error('服务端提前退出，日志尾部:\n' + logTail.join('').slice(-1500));
      try { const r = await getJson(cardUrl); if (r.status === 200) { ready = true; break; } } catch { /* 继续等 */ }
      await sleep(150);
    }
    if (!ready) throw new Error('等服务端就绪超时（' + cardUrl + '）');

    // 第 1 步：发现 AgentCard
    const card = await getJson(cardUrl);
    if (card.status !== 200 || !card.json) throw new Error('AgentCard 状态码 ' + card.status);
    const c = card.json;
    if (!c.name || typeof c.name !== 'string') throw new Error('AgentCard.name 为空');
    if (!c.url || typeof c.url !== 'string') throw new Error('AgentCard.url 为空');
    if (!Array.isArray(c.skills) || c.skills.length < 3) throw new Error('skills 少于 3 条');
    pass('discover', 'name=' + c.name + ' skills=' + c.skills.length + ' protocolVersion=' + c.protocolVersion);

    // 第 2 步：无 token 必须 401
    const body1 = {
      jsonrpc: '2.0', id: 'no-auth-1', method: 'message/send',
      params: { message: { kind: 'message', role: 'user', parts: [{ kind: 'text', text: '[ping] no-auth' }], messageId: 'no-auth-1' } }
    };
    const raw = await getJson(rpcUrl, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body1) });
    if (raw.status !== 401) throw new Error('无 token 期望 HTTP 401，实际 ' + raw.status);
    if (!raw.json || !raw.json.error || raw.json.error.code !== -32001) throw new Error('无 token 应返回 JSON-RPC -32001');
    pass('auth-reject', 'HTTP 401 / error ' + raw.json.error.code);

    // 第 3 步：带 token message/send
    const tp = tokenPath(cfgPath, a2aCfg.tokenFile);
    if (!tp || !fs.existsSync(tp)) throw new Error('token 文件不存在: ' + tp);
    const token = fs.readFileSync(tp, 'utf8').trim();
    if (!token) throw new Error('token 文件为空: ' + tp);
    console.log('token 文件: ' + tp);
    const auth = { 'content-type': 'application/json', authorization: 'Bearer ' + token };
    const sent = await getJson(rpcUrl, {
      method: 'POST', headers: auth,
      body: JSON.stringify({
        jsonrpc: '2.0', id: 'send-1', method: 'message/send',
        params: { message: { kind: 'message', role: 'user', parts: [{ kind: 'text', text: '[ping] a2a-selfloop ' + new Date().toISOString() }], messageId: 'msg-' + Date.now() } }
      })
    });
    if (sent.status !== 200) throw new Error('message/send 期望 200，实际 ' + sent.status + ' ' + sent.text.slice(0, 200));
    const task = sent.json && sent.json.result;
    if (!task || task.kind !== 'task') throw new Error('message/send 未返回 Task');
    if (!task.status || task.status.state !== 'completed') throw new Error('Task.status.state 必须为 completed');
    const art = Array.isArray(task.artifacts) && task.artifacts[0];
    if (!art || !art.parts || !art.parts[0] || typeof art.parts[0].text !== 'string') throw new Error('artifacts 结构非法');
    if (!art.parts[0].text.includes('[pong]')) throw new Error('artifact 文本不含 [pong]，实际: ' + art.parts[0].text);
    if (!art.parts[0].text.startsWith('[pong]')) throw new Error('artifact 文本未以 [pong] 开头，实际: ' + art.parts[0].text);
    pass('message-send', 'task=' + task.id + ' state=' + task.status.state + ' reply="' + art.parts[0].text + '"');

    // 第 4 步：tasks/get 复核
    const got = await getJson(rpcUrl, {
      method: 'POST', headers: auth,
      body: JSON.stringify({ jsonrpc: '2.0', id: 'get-1', method: 'tasks/get', params: { id: task.id } })
    });
    if (got.status !== 200) throw new Error('tasks/get 期望 200，实际 ' + got.status);
    const back = got.json && got.json.result;
    if (!back) throw new Error('tasks/get 未返回 result');
    if (back.id !== task.id) throw new Error('tasks/get id 不一致: ' + back.id + ' != ' + task.id);
    if (back.status.state !== task.status.state) throw new Error('tasks/get state 不一致: ' + back.status.state);
    pass('tasks-get', '同 id 同 state (' + back.id + ' / ' + back.status.state + ')');
  } catch (e) {
    fail('selfloop', e && e.message ? e.message : String(e));
  } finally {
    try { child.kill('SIGTERM'); } catch { /* 忽略 */ }
    let stopped = await waitExit(child, 4000);
    if (!stopped) {
      try { child.kill('SIGKILL'); } catch { /* 忽略 */ }
      stopped = await waitExit(child, 3000);
    }
    if (!stopped) console.error('[提示] 服务端进程未能确认退出 pid=' + child.pid);
  }

  console.log('== A2A 自环结束 ' + (failed ? '失败' : '成功') + ' ==');
  // 不直接 process.exit：本脚本用的是全局 fetch（undici），它持有 keep-alive 连接。
  // Windows 上 process.exit 与 uv 句柄关闭撞车会 abort（Assertion failed: !(handle->flags &
  // UV_HANDLE_CLOSING), src\win\async.c:94），表现为"四项全 PASS 但退出码是负数"。
  // 正确做法：设 exitCode 让事件循环自然收尾；仅在还有句柄挂着时兜底硬退（unref 不影响正常路径）。
  process.exitCode = failed ? 1 : 0;
  const bail = setTimeout(() => process.exit(failed ? 1 : 0), 800);
  bail.unref();
}

main().catch((e) => {
  console.log('FAIL: selfloop 原因: ' + (e && e.message ? e.message : String(e)));
  process.exit(1);
});