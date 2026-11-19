#!/usr/bin/env node
// MCP 自环客户端（HTTP 传输）：自行拉起服务端 -> 八步验证 -> 关闭服务端。
// 用法: node client/mcp-selfloop.mjs --config <cfg> [--port 18790]
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const CLIENT_DIR = path.dirname(fileURLToPath(import.meta.url));
const BUNDLE_DIR = path.resolve(CLIENT_DIR, '..');
const LOOPBACK = '127.0.0.1';
const SERVER = path.join(BUNDLE_DIR, 'server', 'team-link-mcp.mjs');
const FIXED = 'team-link-fixed-C0FFEE';

function parseArgv(argv) {
  const out = { config: null, port: null };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--config') out.config = argv[i += 1];
    else if (a.startsWith('--config=')) out.config = a.slice('--config='.length);
    else if (a === '--port') out.port = Number(argv[i += 1]);
    else if (a.startsWith('--port=')) out.port = Number(a.slice('--port='.length));
    else if (a === '--help' || a === '-h') {
      console.error('用法: node client/mcp-selfloop.mjs --config <cfg> [--port 18790]');
      console.error('说明: 客户端自行启动并关闭 team-link-mcp 服务端（HTTP 传输，仅 127.0.0.1）。');
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

function makeRpc(url) {
  return async function rpc(payload, token) {
    const headers = { 'content-type': 'application/json', accept: 'application/json' };
    if (token) headers.authorization = 'Bearer ' + token;
    const res = await fetch(url, { method: 'POST', headers, body: JSON.stringify(payload) });
    const text = await res.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { json = null; }
    return { status: res.status, json, text };
  };
}

function payloadOf(result) {
  if (result && result.structuredContent) return result.structuredContent;
  const t = result && result.content && result.content[0] && result.content[0].text;
  try { return JSON.parse(t); } catch { return null; }
}

function errorText(result) {
  const t = result && result.content && result.content[0] && result.content[0].text;
  return typeof t === 'string' ? t : JSON.stringify(result);
}

async function main() {
  const args = parseArgv(process.argv.slice(2));
  const cfgPath = resolveConfigPath(args.config);
  const cfg = readConfig(cfgPath);
  const mcpCfg = cfg.mcp || {};
  const port = Number.isFinite(args.port) && args.port > 0 ? args.port : Number(mcpCfg.port || 18790);
  const mcpPath = mcpCfg.path || '/mcp';
  const url = 'http://' + LOOPBACK + ':' + port + mcpPath;
  const roots = Array.isArray(cfg.roots) ? cfg.roots : [];

  if (!fs.existsSync(SERVER)) throw new Error('服务端文件不存在: ' + SERVER);
  console.log('== MCP 自环开始 ==');
  console.log('配置: ' + cfgPath);
  console.log('服务端: ' + SERVER + ' --http --port ' + port);

  const child = spawn(process.execPath, [SERVER, '--http', '--port', String(port), '--config', cfgPath], {
    cwd: BUNDLE_DIR, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true
  });
  const logTail = [];
  const keep = (d) => { logTail.push(d.toString()); if (logTail.length > 60) logTail.shift(); };
  child.stdout.on('data', keep);
  child.stderr.on('data', keep);

  let failed = false;
  const fail = (step, msg) => { failed = true; console.log('FAIL: ' + step + ' 原因: ' + msg); };
  const pass = (step, extra) => console.log('PASS ' + step + (extra ? ' — ' + extra : ''));

  const rpc = makeRpc(url);

  try {
    // 等端口就绪
    let ready = false;
    for (let i = 0; i < 120; i += 1) {
      if (child.exitCode !== null) throw new Error('服务端提前退出，日志尾部:\n' + logTail.join('').slice(-1500));
      try { const r = await rpc({ jsonrpc: '2.0', id: 'probe', method: 'ping' }, null); if (r.status === 401 || r.status === 200) { ready = true; break; } } catch { /* 继续等 */ }
      await sleep(150);
    }
    if (!ready) throw new Error('等服务端就绪超时（' + url + '）');

    const tp = tokenPath(cfgPath, mcpCfg.tokenFile);
    if (!tp || !fs.existsSync(tp)) throw new Error('token 文件不存在: ' + tp);
    const token = fs.readFileSync(tp, 'utf8').trim();
    if (!token) throw new Error('token 文件为空: ' + tp);
    console.log('token 文件: ' + tp);

    // 1. initialize
    const init = await rpc({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'mcp-selfloop', version: '1.0.0' } } }, token);
    if (init.status !== 200 || !init.json || !init.json.result) throw new Error('initialize 失败: HTTP ' + init.status + ' ' + init.text.slice(0, 200));
    const sr = init.json.result;
    if (sr.protocolVersion !== '2025-06-18') throw new Error('protocolVersion 未回显: ' + sr.protocolVersion);
    if (!sr.capabilities || !sr.capabilities.tools || sr.capabilities.tools.listChanged !== false) throw new Error('capabilities 非法');
    if (!sr.serverInfo || sr.serverInfo.name !== 'team-link' || !/^\d+\.\d+\.\d+/.test(String(sr.serverInfo.version))) throw new Error('serverInfo 非法');
    pass('initialize', sr.serverInfo.name + ' ' + sr.serverInfo.version + ' protocolVersion=' + sr.protocolVersion);

    // 2. notifications/initialized（不得回复正文）
    const notif = await rpc({ jsonrpc: '2.0', method: 'notifications/initialized' }, token);
    if (![200, 202, 204].includes(notif.status)) throw new Error('通知期望 202/204，实际 ' + notif.status);
    if (notif.json && notif.json.id !== undefined && notif.json.id !== null) throw new Error('通知不应带 id 回复');
    pass('notify-initialized', 'HTTP ' + notif.status);

    // 3. tools/list
    const list = await rpc({ jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} }, token);
    if (!list.json || !list.json.result || !Array.isArray(list.json.result.tools)) throw new Error('tools/list 失败: ' + list.text.slice(0, 200));
    const names = list.json.result.tools.map((t) => t.name);
    for (const need of ['list_roots', 'read_file', 'write_file', 'sha256_file', 'collab_status']) {
      if (!names.includes(need)) throw new Error('缺少工具 ' + need + '，实际: ' + names.join(','));
    }
    pass('tools-list', '工具 ' + names.length + ' 个: ' + names.join(', '));

    // 4. list_roots 只含授权项
    const lr = await rpc({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'list_roots', arguments: {} } }, token);
    const lrRes = lr.json && lr.json.result;
    if (!lrRes || lrRes.isError) throw new Error('list_roots 失败: ' + errorText(lrRes));
    const listed = payloadOf(lrRes);
    if (!listed || !Array.isArray(listed.roots)) throw new Error('list_roots 返回结构非法');
    const wantIds = roots.map((r) => r.id).sort();
    const gotIds = listed.roots.map((r) => r.id).sort();
    if (wantIds.join(',') !== gotIds.join(',')) throw new Error('root 集合不一致 want=' + wantIds.join(',') + ' got=' + gotIds.join(','));
    pass('list_roots-only-authorized', 'ids=' + gotIds.join(','));

    // 5. write_file -> state/inbox/selftest-<ts>.txt
    const rootId = roots.some((r) => r.id === 'state') ? 'state' : (roots.some((r) => r.id === 'inbox') ? 'inbox' : roots[0].id);
    const ts = Date.now();
    const rel = rootId === 'state' ? 'inbox/selftest-' + ts + '.txt' : 'selftest-' + ts + '.txt';
    const content = '自环写入测试 ' + FIXED + ' 时间=' + new Date(ts).toISOString() + '\n第二行：中文与固定串 ' + FIXED + '\n';
    const w = await rpc({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'write_file', arguments: { root: rootId, path: rel, content } } }, token);
    const wRes = w.json && w.json.result;
    if (!wRes || wRes.isError) throw new Error('write_file 失败: ' + errorText(wRes));
    const wPayload = payloadOf(wRes);
    if (wPayload.root !== rootId || wPayload.path !== rel) throw new Error('write_file 回显不一致: ' + JSON.stringify(wPayload));
    if (wPayload.bytes !== Buffer.byteLength(content, 'utf8')) throw new Error('write_file bytes 不一致');
    pass('write', rootId + ':' + rel + ' bytes=' + wPayload.bytes);

    // 6. read_file 比对
    const r = await rpc({ jsonrpc: '2.0', id: 5, method: 'tools/call', params: { name: 'read_file', arguments: { root: rootId, path: rel } } }, token);
    const rRes = r.json && r.json.result;
    if (!rRes || rRes.isError) throw new Error('read_file 失败: ' + errorText(rRes));
    const rPayload = payloadOf(rRes);
    if (rPayload.content !== content) throw new Error('read_file 内容不一致');
    if (!rPayload.content.includes(FIXED)) throw new Error('read_file 内容缺固定串');
    pass('read', '内容一致 bytes=' + rPayload.bytes);

    // 7. sha256_file 与本地 crypto 比对
    const localSha = crypto.createHash('sha256').update(Buffer.from(content, 'utf8')).digest('hex');
    const s = await rpc({ jsonrpc: '2.0', id: 6, method: 'tools/call', params: { name: 'sha256_file', arguments: { root: rootId, path: rel } } }, token);
    const sRes = s.json && s.json.result;
    if (!sRes || sRes.isError) throw new Error('sha256_file 失败: ' + errorText(sRes));
    const sPayload = payloadOf(sRes);
    if (sPayload.sha256 !== localSha) throw new Error('sha256 不一致 server=' + sPayload.sha256 + ' local=' + localSha);
    if (sPayload.bytes !== Buffer.byteLength(content, 'utf8')) throw new Error('bytes 不一致');
    pass('sha256', sPayload.sha256);

    // 8. 越权用例必须被拒
    const a = await rpc({ jsonrpc: '2.0', id: 7, method: 'tools/call', params: { name: 'read_file', arguments: { root: rootId, path: '../x.txt' } } }, token);
    const aRes = a.json && a.json.result;
    if (!aRes || aRes.isError !== true) throw new Error('../x.txt 未被拒绝');
    if (!/\.\./.test(errorText(aRes))) throw new Error('.. 拒绝信息不明确: ' + errorText(aRes));
    const b = await rpc({ jsonrpc: '2.0', id: 8, method: 'tools/call', params: { name: 'read_file', arguments: { root: rootId, path: 'C:\\Windows\\win.ini' } } }, token);
    const bRes = b.json && b.json.result;
    if (!bRes || bRes.isError !== true) throw new Error('绝对路径未被拒绝');
    if (!/绝对路径/.test(errorText(bRes))) throw new Error('绝对路径拒绝信息不明确: ' + errorText(bRes));
    pass('path-escape-rejected', '.. 与绝对路径均被拒');

    // 9. 无 token HTTP 必须 401
    const noAuth = await rpc({ jsonrpc: '2.0', id: 9, method: 'tools/list', params: {} }, null);
    if (noAuth.status !== 401) throw new Error('无 token 期望 401，实际 ' + noAuth.status);
    if (!noAuth.json || !noAuth.json.error || noAuth.json.error.code !== -32001) throw new Error('无 token 应返回 -32001');
    pass('auth-reject', 'HTTP 401 / error ' + noAuth.json.error.code);
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

  console.log('== MCP 自环结束 ' + (failed ? '失败' : '成功') + ' ==');
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