/**
 * dsh-vivado-team-link :: tools/apply-selftest.mjs
 *
 * 离线验收 `lib/index.js` 这一半（宿主插件半边）的 **副作用**，不需要重启宿主。
 * 验收口径来自交接 §6「新增（这轮必须补）」四条：
 *
 *   1. apply() 物化出的 state/config.json 与服务端/tools 期望一致
 *      —— 直接拿物化产物去跑 `server/team-link-mcp.mjs --selftest`，服务端说 PASS 才算数。
 *   2. apply() 内部抛异常时**不会**拖垮 profile 启动（塞一个必错分支验一次）
 *      —— 造一个属性访问就抛的 config，断言 apply 不向外抛且仍留下可用的 config.json。
 *   3. 删掉 state/config.json 后 apply() 能重建。
 *   4. token 值链路：凭据存储有值 → 写 token 文件；引用未配置 → **既有文件保持不动**。
 *
 * 隔离策略：把 lib/index.js 复制进一个临时 bundle 目录再 import。
 * lib 用 `import.meta.url` 推 BUNDLE_DIR，所以所有落盘都发生在临时目录里，
 * 真实 state/ 文件一个都不碰（这条很重要：绝不能用测试污染正在用的 token）。
 *
 * 用法：
 *   node tools/apply-selftest.mjs                 # 全部场景
 *   node tools/apply-selftest.mjs --keep          # 保留临时目录便于取证
 *
 * 退出码：0 全 PASS；1 有 FAIL（逐条打印）。
 */
import { execFileSync } from 'node:child_process'
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const BUNDLE = resolve(HERE, '..')
const KEEP = process.argv.includes('--keep')

const results = []
/**
 * 记一条断言结果。
 * @param label - 断言名。
 * @param ok - 是否通过。
 * @param detail - 失败时的细节（PASS 可省略）。
 */
function check(label, ok, detail = '') {
  results.push({ label, ok, detail })
  const mark = ok ? 'PASS' : 'FAIL'
  console.log(`  ${mark} ${label}${ok || detail === '' ? '' : `  <- ${detail}`}`)
}

/**
 * 读 JSON 文件；不存在返回 undefined。
 * @param path - 文件路径。
 * @returns 解析结果。
 */
function readJson(path) {
  if (!existsSync(path)) return undefined
  return JSON.parse(readFileSync(path, 'utf8'))
}

/**
 * 造一个临时 bundle：只有 lib/index.js + state/ 两个东西。
 * @returns `{ dir, lib, state }`。
 */
function makeSandbox() {
  const dir = mkdtempSync(join(tmpdir(), 'team-link-apply-'))
  const lib = join(dir, 'lib')
  const state = join(dir, 'state')
  mkdirSync(lib, { recursive: true })
  mkdirSync(state, { recursive: true })
  copyFileSync(join(BUNDLE, 'lib', 'index.js'), join(lib, 'index.js'))
  return { dir, lib, state }
}

/**
 * 造一个日志收集器，并顺带返回最近一条同级别日志。
 * @returns `{ ctx, logs }`——ctx 只有 apply() 真正会用的那几个面。
 */
function makeStubContext() {
  const logs = []
  const ctx = {
    logger: {
      info: (m) => logs.push(['info', m]),
      warn: (m) => logs.push(['warn', m]),
      error: (m) => logs.push(['error', m]),
    },
    get: () => undefined,
  }
  return { ctx, logs }
}

/**
 * 造一个假的凭据 seam：refs 就是一张内存表。
 * @param store - 引用名 → 值。
 * @returns `{ resolve, describe, set, unset }`。
 */
function makeFakeCredentials(store) {
  return {
    async describe(ref) {
      return { configured: Object.prototype.hasOwnProperty.call(store, ref), writable: true }
    },
    async resolve(ref) {
      return Object.prototype.hasOwnProperty.call(store, ref)
        ? { value: store[ref], source: 'fake-store' }
        : undefined
    },
    async set(ref, value) {
      store[ref] = value
    },
    async unset(ref) {
      delete store[ref]
    },
  }
}

// ---------------------------------------------------------------------------
//  场景 1：默认物化
// ---------------------------------------------------------------------------
console.log('\n== 场景 1：apply() 物化 state/config.json ==')
const box = makeSandbox()
const plugin = await import(pathToFileURL(join(box.lib, 'index.js')).href)
const configJson = join(box.state, 'config.json')

check('lib/index.js 导出契约 { name, Config, apply }',
  typeof plugin.name === 'string' && typeof plugin.apply === 'function' && plugin.Config !== undefined)

const stub = makeStubContext()
plugin.apply({ ...stub.ctx, get: (name) => (name === 'credentials' ? undefined : undefined) }, {
  role: 'pc2',
  a2a: { port: 7410 },
  fallback: { repo: 'chemmy-11/EIF' },
})

const first = readJson(configJson)
check('config.json 已生成', first !== undefined)
check('schema version = 2', first?.version === 2, String(first?.version))
check('role 透传 pc2', first?.role === 'pc2', String(first?.role))
check('machine 由 role 派生 = PC2', first?.machine === 'PC2', String(first?.machine))
check('a2a.port 透传 7410', first?.a2a?.port === 7410, String(first?.a2a?.port))
check('mcp.port 落到默认 18790', first?.mcp?.port === 18790, String(first?.mcp?.port))
check('a2a.tokenFile 是绝对路径（POSIX 风格）',
  typeof first?.a2a?.tokenFile === 'string' && first.a2a.tokenFile.includes('/state/a2a.token'),
  String(first?.a2a?.tokenFile))
check('roots 默认含 state 根', Array.isArray(first?.roots) && first.roots.some((r) => r.id === 'state'),
  JSON.stringify(first?.roots))
check('fallback.repo 透传', first?.fallback?.repo === 'chemmy-11/EIF', String(first?.fallback?.repo))
check('fallback.issueLabel 默认 collab-audit', first?.fallback?.issueLabel === 'collab-audit')

// ---------------------------------------------------------------------------
//  场景 2：物化产物必须是服务端认的东西
// ---------------------------------------------------------------------------
console.log('\n== 场景 2：物化产物直接喂服务端 --selftest ==')
let serverOut = ''
let serverCode = 1
try {
  serverOut = execFileSync(process.execPath, [
    join(BUNDLE, 'server', 'team-link-mcp.mjs'), '--selftest', '--config', configJson,
  ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, NODE_NO_WARNINGS: '1' } })
  serverCode = 0
} catch (error) {
  serverCode = error?.status ?? 1
  serverOut = `${error?.stdout ?? ''}${error?.stderr ?? ''}`
}
check('server --selftest 对 apply() 产物 exit 0', serverCode === 0, `exit=${serverCode}`)
check('server --selftest 打印 PASS', /PASS mcp-selftest/.test(serverOut),
  serverOut.split(/\r?\n/).filter((l) => l.includes('PASS') || l.includes('FAIL')).join(' | '))

// ---------------------------------------------------------------------------
//  场景 3：合并保留既有键（不该被抹掉）
// ---------------------------------------------------------------------------
console.log('\n== 场景 3：既有 config.json 的键被保留（配置项没表态时） ==')
const beforeMerge = readJson(configJson)
const withExtras = {
  ...beforeMerge,
  evidenceDir: 'D:/kept/evidence',
  peer: { ...beforeMerge.peer, wlan: '10.0.0.9', note: '手工写的说明' },
  fallback: { mode: 'issue-poll', repo: 'disk/kept', issueLabel: 'disk-label', pollSeconds: 1234 },
  roots: [
    { id: 'evidence', path: 'D:/kept/evidence', mode: 'rw' },
    { id: 'state', path: box.state.replace(/\\/g, '/'), mode: 'rw' },
  ],
}
writeFileSync(configJson, `${JSON.stringify(withExtras, null, 2)}\n`, 'utf8')
plugin.apply(makeStubContext().ctx, { role: 'pc1' })
const merged = readJson(configJson)
check('evidenceDir 保留', merged?.evidenceDir === 'D:/kept/evidence', String(merged?.evidenceDir))
check('peer.wlan 保留', merged?.peer?.wlan === '10.0.0.9', String(merged?.peer?.wlan))
check('peer.note 保留', merged?.peer?.note === '手工写的说明')
check('手写的 evidence 根保留', merged?.roots?.some((r) => r.id === 'evidence'),
  JSON.stringify(merged?.roots))
check('手写的 state 根保留', merged?.roots?.some((r) => r.id === 'state'))
check('role 被本轮覆盖为 pc1', merged?.role === 'pc1', String(merged?.role))
// 回归：配置项没写 fallback.* 时，不得把磁盘上的值冲成空串（曾经的真 bug）
check('fallback.repo 未被空默认值冲掉', merged?.fallback?.repo === 'disk/kept', String(merged?.fallback?.repo))
check('fallback.issueLabel 未被冲掉', merged?.fallback?.issueLabel === 'disk-label', String(merged?.fallback?.issueLabel))
check('fallback.pollSeconds 未被冲掉', merged?.fallback?.pollSeconds === 1234, String(merged?.fallback?.pollSeconds))

console.log('\n== 场景 3b：配置项显式给了 roots 才是整表替换 ==')
plugin.apply(makeStubContext().ctx, { roots: [{ id: 'only', path: 'D:/only', mode: 'ro' }] })
const replaced = readJson(configJson)
check('显式 roots 生效（整表替换）',
  replaced?.roots?.length === 1 && replaced?.roots?.[0]?.id === 'only',
  JSON.stringify(replaced?.roots))
check('显式 roots 的 mode 归一化 ro', replaced?.roots?.[0]?.mode === 'ro')
// 复原成"沿用磁盘"的形态，后面的场景才有意义
plugin.apply(makeStubContext().ctx, {})

// ---------------------------------------------------------------------------
//  场景 4：apply() 内部抛异常不拖垮启动
// ---------------------------------------------------------------------------
console.log('\n== 场景 4：必错分支 —— apply() 不向外抛 ==')
rmSync(configJson, { force: true })
const poisoned = {
  get role() { throw new Error('注入的必错分支：读 role 就炸') },
}
const poisonCtx = makeStubContext()
let poisonThrew = false
try {
  plugin.apply(poisonCtx.ctx, poisoned)
} catch (error) {
  poisonThrew = true
  console.log(`      意外抛出：${error?.message ?? error}`)
}
check('apply() 没有向外抛', poisonThrew === false)
check('降级日志已记录（error 级）',
  poisonCtx.logs.some(([level]) => level === 'error'),
  JSON.stringify(poisonCtx.logs.slice(0, 2)))
check('降级后 config.json 仍然存在（下次可重建）', existsSync(configJson))

// ---------------------------------------------------------------------------
//  场景 5：删掉 config.json 能重建
// ---------------------------------------------------------------------------
console.log('\n== 场景 5：删掉 state/config.json 后重建 ==')
rmSync(configJson, { force: true })
check('删除成功（起始状态：不存在）', !existsSync(configJson))
const rebuildCtx = makeStubContext()
plugin.apply(rebuildCtx.ctx, {})
const rebuilt = readJson(configJson)
check('config.json 已重建', rebuilt !== undefined)
check('重建后回到默认 role=pc1', rebuilt?.role === 'pc1', String(rebuilt?.role))
check('重建后 roots 仍有 state 根', rebuilt?.roots?.some((r) => r.id === 'state'))

// ---------------------------------------------------------------------------
//  场景 6：token 值链路（凭据 → 文件；未配置则不动既有权）
// ---------------------------------------------------------------------------
console.log('\n== 场景 6：token 值链路 ==')
const a2aFile = join(box.state, 'a2a.token')
const mcpFile = join(box.state, 'mcp.token')
const peerMcpFile = join(box.state, 'peer-mcp.token')

// 既有文件必须先存在，才能验证「未配置时保持不动」。
writeFileSync(a2aFile, 'A'.repeat(64), 'utf8')
writeFileSync(mcpFile, 'B'.repeat(64), 'utf8')
writeFileSync(peerMcpFile, 'P'.repeat(64), 'utf8')

const store = { TEAM_LINK_A2A_TOKEN: 'C'.repeat(64), TEAM_LINK_PEER_MCP_TOKEN: 'D'.repeat(64) }
const credCtx = {
  logger: { info: () => {}, warn: (m) => console.log(`       warn: ${m}`), error: () => {} },
  get: (name) => (name === 'credentials' ? makeFakeCredentials(store) : undefined),
}
plugin.apply(credCtx, {})
// apply 里 token 同步是刻意不 await 的，给它一拍。
await new Promise((done) => setTimeout(done, 250))

check('凭据命中的 a2a.token 被写成存储值', readFileSync(a2aFile, 'utf8').trim() === 'C'.repeat(64))
check('凭据命中的 peer-mcp.token 被写成存储值', readFileSync(peerMcpFile, 'utf8').trim() === 'D'.repeat(64))
check('凭据未命中的 mcp.token 保持既有内容不动（不被清空）',
  readFileSync(mcpFile, 'utf8').trim() === 'B'.repeat(64))

// ---------------------------------------------------------------------------
//  场景 7：team_link_setup 工具
// ---------------------------------------------------------------------------
console.log('\n== 场景 7：team_link_setup（值只进凭据存储，永不回读）==')
const box2 = makeSandbox()
const plugin2 = await import(pathToFileURL(join(box2.lib, 'index.js')).href)
const store2 = {}
let registered
plugin2.apply(
  {
    logger: { info: () => {}, warn: () => {}, error: () => {} },
    get: (name) => (name === 'credentials' ? makeFakeCredentials(store2) : undefined),
    tools: { register: (definition) => { registered = definition } },
  },
  {},
)
await new Promise((done) => setTimeout(done, 200))
check('team_link_setup 已注册', registered?.name === 'team_link_setup', String(registered?.name))
check('参数枚举含四个槽位',
  JSON.stringify(registered?.parameters?.properties?.token?.enum ?? []) ===
  JSON.stringify(['a2a', 'mcp', 'peer-a2a', 'peer-mcp']))

const secret = 'F'.repeat(64)
const setOut = await registered.execute({ action: 'set-token', token: 'a2a', value: secret })
check('set-token 成功', setOut?.ok === true, JSON.stringify(setOut))
check('值已进凭据存储', store2.TEAM_LINK_A2A_TOKEN === secret)
check('值已物化到 a2a.token', readFileSync(join(box2.state, 'a2a.token'), 'utf8').trim() === secret)
check('返回值里没有 token 值', !JSON.stringify(setOut).includes(secret), JSON.stringify(setOut).slice(0, 200))

const statusOut = await registered.execute({ action: 'status' })
check('status 报告 credential=configured', /credential=configured/.test(statusOut?.report ?? ''))
check('status 报告里没有 token 值', !(statusOut?.report ?? '').includes(secret))

const clearOut = await registered.execute({ action: 'clear-token', token: 'a2a' })
check('clear-token 成功', clearOut?.ok === true, JSON.stringify(clearOut))
check('凭据存储中该引用已移除', store2.TEAM_LINK_A2A_TOKEN === undefined)
check('token 文件仍在（清除不清文件）', existsSync(join(box2.state, 'a2a.token')))

// ---------------------------------------------------------------------------
//  汇总
// ---------------------------------------------------------------------------
const failed = results.filter((item) => !item.ok)
console.log(`\n按 selftest 断言统计：${results.length - failed.length}/${results.length} PASS`)
if (failed.length > 0) {
  console.log('FAIL 明细：')
  for (const item of failed) console.log(`  - ${item.label} ${item.detail}`)
}
if (!KEEP) {
  rmSync(box.dir, { recursive: true, force: true })
  rmSync(box2.dir, { recursive: true, force: true })
} else {
  console.log(`临时目录已保留：\n  ${box.dir}\n  ${box2.dir}`)
}
console.log(failed.length === 0 ? 'PASS apply-selftest' : 'FAIL apply-selftest')
process.exit(failed.length === 0 ? 0 : 1)
