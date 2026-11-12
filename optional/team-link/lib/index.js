/**
 * dsh-vivado-team-link — 宿主插件半边（host plugin half）。
 *
 * 这个文件把「本插件的配置」变成「服务端能读的东西」：
 *
 *   profile 配置（cordis.patch.yml 的 config: 块）
 *        └─ apply(ctx, config) ──► state/config.json（schema v2，服务端与三个 tools 都读它）
 *                              └─► state/*.token（值来自 DSH 凭据存储，按引用名解析）
 *
 * 三条硬约束（改代码前先读）：
 *
 * 1. **绝不 throw**。apply() 抛异常会拖垮整个 profile 启动，比功能缺失严重得多；
 *    所有异常一律降级成日志。同理，schemastery 解析不到时降级为 `Config = undefined`
 *    （Loader 容忍没有 Config 的插件，`fiber.runtime?.Config` 是可选读）。
 * 2. **配置里不放密文**。Config 只有非密字段 + token 的**文件路径**与**凭据引用名**；
 *    token 值只存在于 `~/.dsh/.credentials.yaml` 的 refs 段。原因：profile 插件配置是
 *    明文持久化的，`.volatile()` 也不是「不落盘」（语义是稳定引用）。
 * 3. **不动既有的 token 文件**。引用未配置就什么都不做；只有拿到新值且与文件内容不同
 *    才写。install.ps1 生成的 token 是权威基线，本文件只做「凭据存储 → 文件」的单向覆盖。
 *
 * 关于 schemastery 的解析：本包按 `dsh plugin add link:<path>` 注册，profile 里是指向
 * 源码目录的 junction，Node 解析裸标识符时会先 realpath 再向上找 node_modules，
 * 因此 `@deepseek-ai/schemastery` 在「源码目录」这一层**找不到**（实测：同一 junction 下
 * 裸 import 直接 ERR_MODULE_NOT_FOUND）。下面 loadSchemastery() 用一条候选链兜住
 * 三种真实部署形态，全部失败时降级而不是抛错。
 *
 * @module dsh-vivado-team-link
 */
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, isAbsolute, join, resolve as resolvePath } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

/** 本插件根目录（= lib/ 的上一级）。部署时是 copy 出来的 bundle，开发时是仓内 optional/team-link。 */
const BUNDLE_DIR = resolvePath(dirname(fileURLToPath(import.meta.url)), '..')
/** 运行期状态目录：config.json 与四个 token 文件的默认落点。 */
const STATE_DIR = join(BUNDLE_DIR, 'state')

/** Loader 侧插件标识（与 plugin.json 的 id 一致，便于日志对齐）。 */
export const name = 'dsh-vivado-team-link'

/** 四个 token 槽位：凭据引用名（refs 段的键）↔ 落盘文件。 */
const TOKEN_SLOTS = ['a2a', 'mcp', 'peer-a2a', 'peer-mcp']

/**
 * 把 Windows 路径写成配置里统一的 POSIX 风格。
 * 服务端按 BUNDLE 解析、运维脚本按 BUNDLE\state 解析，两边写法必须一致，
 * 否则会指向不同文件（历史 bug：evidence_pull 拿到空 token）。
 * @param path - 绝对路径。
 * @returns 正斜杠形式。
 */
function slash(path) {
  return path.replace(/\\/g, '/')
}

/**
 * 默认 token 文件绝对路径。
 * @param leaf - 文件名，例如 `a2a.token`。
 * @returns POSIX 风格绝对路径。
 */
function defaultTokenFile(leaf) {
  return slash(join(STATE_DIR, leaf))
}

// ---------------------------------------------------------------------------
//  schemastery 解析（见文件头「关于 schemastery 的解析」）
// ---------------------------------------------------------------------------

/**
 * 候选搜到的 schemastery 包入口。
 * @param packageDir - `@deepseek-ai/schemastery` 包根。
 * @returns 可 import 的 file: URL。
 */
function schemaMasteryEntry(packageDir) {
  const manifest = join(packageDir, 'package.json')
  if (!existsSync(manifest)) return undefined
  try {
    const meta = JSON.parse(readFileSync(manifest, 'utf8'))
    const entry = meta?.module ?? meta?.main ?? './lib/index.js'
    const resolved = join(packageDir, entry)
    return existsSync(resolved) ? pathToFileURL(resolved).href : undefined
  } catch {
    return undefined
  }
}

/**
 * 从某个锚点向上找 `<锚点>/node_modules/@deepseek-ai/schemastery`。
 * @param anchor - 起始目录。
 * @param depth - 最多向上几层。
 * @returns 候选入口 URL 列表。
 */
function walkUpCandidates(anchor, depth = 8) {
  const found = []
  let dir = resolvePath(anchor)
  for (let i = 0; i < depth; i++) {
    const entry = schemaMasteryEntry(join(dir, 'node_modules', '@deepseek-ai', 'schemastery'))
    if (entry !== undefined) found.push(entry)
    const parent = dirname(dir)
    if (parent === dir) break
    dir = parent
  }
  return found
}

/**
 * 从 DSH_HOME 下的 profile 安装目录找 schemastery（profile node_modules 里一定有它，
 * 因为宿主自带的第三方插件以它为 peer）。
 * @returns 候选入口 URL 列表。
 */
function profileCandidates() {
  const home = process.env.DSH_HOME || join(homedir(), '.dsh')
  const found = []
  const direct = schemaMasteryEntry(join(home, 'node_modules', '@deepseek-ai', 'schemastery'))
  if (direct !== undefined) found.push(direct)
  const profilesDir = join(home, 'profiles')
  let profileNames = []
  try {
    // 只做一次浅枚举，不递归、不假设 profile 名。
    profileNames = readdirShallow(profilesDir)
  } catch {
    profileNames = []
  }
  for (const profileName of profileNames) {
    const entry = schemaMasteryEntry(join(profilesDir, profileName, 'node_modules', '@deepseek-ai', 'schemastery'))
    if (entry !== undefined) found.push(entry)
  }
  return found
}

/**
 * 浅枚举目录下的子目录名。
 * @param dir - 目录。
 * @returns 子目录名列表；目录不存在时抛错（由调用方兜住）。
 */
function readdirShallow(dir) {
  return readdirSync(dir, { withFileTypes: true })
    .filter((item) => item.isDirectory())
    .map((item) => item.name)
}

/**
 * 解析 schemastery；失败返回 undefined（调用方据此降级 Config）。
 * @returns schemastery 的默认导出，或 undefined。
 */
async function loadSchemastery() {
  const attempts = []
  // 1) 裸标识符优先：hoist 到插件之上的部署（profile/copy 安装）走这条。
  attempts.push(() => import('@deepseek-ai/schemastery'))
  // 2) 从本文件与 cwd 向上找（开发态 D:\dsh-vivado、部署态 bundles/dsh-vivado）。
  for (const anchor of [dirname(fileURLToPath(import.meta.url)), process.cwd()]) {
    for (const entry of walkUpCandidates(anchor)) attempts.push(() => import(entry))
  }
  // 3) install.ps1 建的 shim（<bundle>/node_modules/@deepseek-ai/schemastery → profile 的副本）。
  const shim = schemaMasteryEntry(join(BUNDLE_DIR, 'node_modules', '@deepseek-ai', 'schemastery'))
  if (shim !== undefined) attempts.push(() => import(shim))
  // 4) DSH_HOME 下的 profile 安装目录。
  for (const entry of profileCandidates()) attempts.push(() => import(entry))

  for (const attempt of attempts) {
    try {
      const module = await attempt()
      const candidate = module?.default ?? module
      if (typeof candidate === 'function' || typeof candidate?.object === 'function') return candidate
    } catch {
      // 落空是正常路径：继续下一个候选。
    }
  }
  return undefined
}

/** 解析到的 schemastery（可能为 undefined，见 loadSchemastery）。 */
const z = await loadSchemastery()

// ---------------------------------------------------------------------------
//  Config：**全部非密**字段。密文一律不进这里（见文件头约束 2）。
// ---------------------------------------------------------------------------

/**
 * 构造 Config schema。
 * @param schema - schemastery 入口。
 * @returns Config Schema。
 */
function buildConfig(schema) {
  return schema.object({
    // —— 身份 ——
    role: schema.union(['pc1', 'pc2']).default('pc1'),
    machine: schema.string().default(''),

    // —— 入站（本机服务监听）——
    a2a: schema.object({
      host: schema.string().default('127.0.0.1'),
      port: schema.number().step(1).min(1).max(65535).default(7310),
      tokenFile: schema.string().default(defaultTokenFile('a2a.token')),
      tokenRef: schema.string().default('TEAM_LINK_A2A_TOKEN'),
    }),
    mcp: schema.object({
      host: schema.string().default('127.0.0.1'),
      port: schema.number().step(1).min(1).max(65535).default(18790),
      tokenFile: schema.string().default(defaultTokenFile('mcp.token')),
      tokenRef: schema.string().default('TEAM_LINK_MCP_TOKEN'),
    }),

    // —— 出站（对端）——
    peer: schema.object({
      name: schema.string().default('pc2'),
      a2aUrl: schema.string().default(''),
      mcpUrl: schema.string().default(''),
      a2a: schema.object({
        tokenFile: schema.string().default(defaultTokenFile('peer-a2a.token')),
        tokenRef: schema.string().default('TEAM_LINK_PEER_A2A_TOKEN'),
      }),
      mcp: schema.object({
        tokenFile: schema.string().default(defaultTokenFile('peer-mcp.token')),
        tokenRef: schema.string().default('TEAM_LINK_PEER_MCP_TOKEN'),
      }),
    }),

    // —— 可访问根目录（服务端 resolveSafe 的白名单）——
    // 默认是**空数组**而不是 [state]：空数组＝"配置项没表态"，物化时沿用磁盘既有 roots。
    // 若这里写成 .default([state])，schema 会让 config.roots 永远非空，
    // 于是既有的 evidence/delivery 根会在首次 apply() 时被整表替换掉（真踩过）。
    roots: schema
      .array(
        schema.object({
          id: schema.string(),
          path: schema.string(),
          mode: schema.union(['ro', 'rw']).default('rw'),
        }),
      )
      .default([]),

    // —— 回退通道（协作 issue 轮询）——
    fallback: schema.object({
      mode: schema.const('issue-poll').default('issue-poll'),
      repo: schema.string().default(''),
      issueLabel: schema.string().default('collab-audit'),
      pollSeconds: schema.number().step(1).min(30).default(900),
    }),

    logDir: schema.string().default('logs'),
  })
}

/**
 * 插件配置 Schema。schemastery 不可用时为 undefined —— Loader  tolerate 没有 Config
 * 的插件（`fiber.runtime?.Config` 是可选读），apply() 仍会用下面的 DEFAULTS 归一化。
 */
export const Config = z === undefined ? undefined : buildConfig(z)

// ---------------------------------------------------------------------------
//  归一化：config + 磁盘既有 config.json → 服务端契约（schema v2）
// ---------------------------------------------------------------------------

/**
 * 与 Config 默认值同构的纯 JS 兜底（考虑到 Config 可能为 undefined）。
 * 键路径与 Config 一一对应；改一处必须改另一处。
 */
function fallbackDefaults() {
  return {
    role: 'pc1',
    machine: '',
    a2a: { host: '127.0.0.1', port: 7310, tokenFile: defaultTokenFile('a2a.token'), tokenRef: 'TEAM_LINK_A2A_TOKEN' },
    mcp: { host: '127.0.0.1', port: 18790, tokenFile: defaultTokenFile('mcp.token'), tokenRef: 'TEAM_LINK_MCP_TOKEN' },
    peer: {
      name: 'pc2',
      a2aUrl: '',
      mcpUrl: '',
      a2a: { tokenFile: defaultTokenFile('peer-a2a.token'), tokenRef: 'TEAM_LINK_PEER_A2A_TOKEN' },
      mcp: { tokenFile: defaultTokenFile('peer-mcp.token'), tokenRef: 'TEAM_LINK_PEER_MCP_TOKEN' },
    },
    roots: [{ id: 'state', path: slash(STATE_DIR), mode: 'rw' }],
    fallback: { mode: 'issue-poll', repo: '', issueLabel: 'collab-audit', pollSeconds: 900 },
    logDir: 'logs',
  }
}

/**
 * 读一层 live 值：`.volatile()` 字段在运行时是稳定引用（有 .get()），普通字段是裸值。
 * 本轮没有 .volatile()，但下一轮加客户端卡片时会用到，故两边都支持。
 * @param value - 字段值、引用、或 undefined。
 * @param fallback - 字段缺失时的兜底。
 * @returns 实际值。
 */
function live(value, fallback) {
  if (value === undefined || value === null) return fallback
  if (typeof value.get === 'function') {
    const current = value.get()
    return current === undefined || current === null ? fallback : current
  }
  return value
}

/**
 * 取 `{group}` 或 `{group.field}` 的 live 值。
 * @param config - apply 收到的配置对象（未知字段容忍）。
 * @param group - 一级键。
 * @param field - 二级键；省略则返回整个 group。
 * @param fallback - 兜底。
 * @returns 实际值。
 */
function pick(config, group, field, fallback) {
  const container = live(config?.[group], undefined)
  if (container === undefined) return fallback
  if (field === undefined) return container
  return live(container?.[field], fallback)
}

/**
 * 按路径取一层 live 值（逐层解引用 `.volatile()` 的稳定引用）。
 * @param config - apply 收到的配置对象。
 * @param path - 键路径数组，例如 `['peer','a2a','tokenFile']`。
 * @returns 值，或 undefined（任一层缺失）。
 */
function pickPath(config, path) {
  let node = config
  for (const key of path) {
    node = live(node?.[key], undefined)
    if (node === undefined) return undefined
  }
  return node
}

/**
 * 取某个 Config 字段的有效值，优先级：**配置项 → 磁盘既有值 → 默认值**。
 *
 * 为什么要三级：Config 里每个字段都带 .default()，所以「用户没在 profile 里写这一项」
 * 和「用户写了默认值」在 apply() 里长得一模一样。若直接拿 Config 值覆盖磁盘，
 * 那么模板里没写的字段（例如 fallback.repo）会在首次 apply() 时把磁盘上手工配好的值
 * 冲成空串（真踩过：回退轮询的仓库名被抹掉）。
 * 约定：空串/undefined/null 一律视为「没表态」，落到磁盘值；磁盘也没有才用默认值。
 *
 * @param config - apply 收到的配置对象。
 * @param path - 键路径数组。
 * @param diskValue - 磁盘既有 config.json 里同位置的值。
 * @param fallback - 兜底。
 * @returns 有效值。
 */
function owned(config, path, diskValue, fallback) {
  const fromConfig = pickPath(config, path)
  if (fromConfig !== undefined && fromConfig !== null && fromConfig !== '') return fromConfig
  if (diskValue !== undefined && diskValue !== null && diskValue !== '') return diskValue
  return fallback
}

/**
 * 把配置归一化成服务端契约（schema v2）。
 *
 * 合并方向：**配置项为最高优先**（这是本插件的职责）→ 否则沿用磁盘既有值 →
 * 否则用默认值。Config 不认识的键（evidenceDir / peer.wlan / a2a.path …）一律原样保留。
 *
 * @param config - apply 收到的配置对象。
 * @param existing - 磁盘上既有的 config.json（可能为空对象）。
 * @returns schema v2 配置对象。
 */
function normalize(config, existing) {
  const defaults = fallbackDefaults()
  const role = String(owned(config, ['role'], existing.role, defaults.role))
  const machine = String(owned(config, ['machine'], existing.machine, '')).trim()
    || role.toUpperCase()

  const roots = live(config?.roots, undefined)
  const cfgRoots = Array.isArray(roots) ? roots.filter((root) => root !== null && typeof root === 'object') : []
  const diskRoots = Array.isArray(existing.roots) ? existing.roots : []
  const rootList = cfgRoots.length > 0
    ? cfgRoots.map((root) => ({
        id: String(live(root?.id, 'root')),
        path: slash(String(live(root?.path, ''))),
        mode: live(root?.mode, 'rw') === 'ro' ? 'ro' : 'rw',
      }))
    : (diskRoots.length > 0 ? diskRoots : defaults.roots)

  const peerDisk = existing.peer ?? {}
  const peerA2aDisk = peerDisk.a2a ?? {}
  const peerMcpDisk = peerDisk.mcp ?? {}
  const a2aDisk = existing.a2a ?? {}
  const mcpDisk = existing.mcp ?? {}
  const fallbackDisk = existing.fallback ?? {}

  const merged = {
    ...existing,
    version: 2,
    role,
    machine,
    a2a: {
      ...a2aDisk,
      host: owned(config, ['a2a', 'host'], a2aDisk.host, defaults.a2a.host),
      port: Number(owned(config, ['a2a', 'port'], a2aDisk.port, defaults.a2a.port)),
      tokenFile: owned(config, ['a2a', 'tokenFile'], a2aDisk.tokenFile, defaults.a2a.tokenFile),
    },
    mcp: {
      ...mcpDisk,
      host: owned(config, ['mcp', 'host'], mcpDisk.host, defaults.mcp.host),
      port: Number(owned(config, ['mcp', 'port'], mcpDisk.port, defaults.mcp.port)),
      tokenFile: owned(config, ['mcp', 'tokenFile'], mcpDisk.tokenFile, defaults.mcp.tokenFile),
    },
    peer: {
      ...peerDisk,
      name: owned(config, ['peer', 'name'], peerDisk.name, defaults.peer.name),
      a2aUrl: owned(config, ['peer', 'a2aUrl'], peerDisk.a2aUrl, defaults.peer.a2aUrl),
      mcpUrl: owned(config, ['peer', 'mcpUrl'], peerDisk.mcpUrl, defaults.peer.mcpUrl),
      a2a: {
        ...peerA2aDisk,
        tokenFile: owned(config, ['peer', 'a2a', 'tokenFile'], peerA2aDisk.tokenFile, defaults.peer.a2a.tokenFile),
      },
      mcp: {
        ...peerMcpDisk,
        tokenFile: owned(config, ['peer', 'mcp', 'tokenFile'], peerMcpDisk.tokenFile, defaults.peer.mcp.tokenFile),
      },
    },
    roots: rootList,
    fallback: {
      ...fallbackDisk,
      mode: 'issue-poll',
      repo: owned(config, ['fallback', 'repo'], fallbackDisk.repo, defaults.fallback.repo),
      issueLabel: owned(config, ['fallback', 'issueLabel'], fallbackDisk.issueLabel, defaults.fallback.issueLabel),
      pollSeconds: Number(owned(config, ['fallback', 'pollSeconds'], fallbackDisk.pollSeconds, defaults.fallback.pollSeconds)),
    },
    logDir: owned(config, ['logDir'], existing.logDir, defaults.logDir),
  }

  // evidenceDir 是 tools/ 的便利键，与 roots 里 id=evidence 同义；保留既有值，缺省不清空。
  if (existing.evidenceDir !== undefined) merged.evidenceDir = existing.evidenceDir

  return merged
}

/**
 * 从配置里取四个 token 槽位（引用名 + 文件路径）。
 * @param config - apply 收到的配置对象。
 * @returns 槽位列表。
 */
function tokenSlots(config) {
  const defaults = fallbackDefaults()
  return [
    {
      slot: 'a2a',
      label: '本机 A2A（入站）',
      ref: String(pick(config, 'a2a', 'tokenRef', '')).trim() || defaults.a2a.tokenRef,
      file: String(pick(config, 'a2a', 'tokenFile', '')).trim() || defaults.a2a.tokenFile,
    },
    {
      slot: 'mcp',
      label: '本机 MCP（入站）',
      ref: String(pick(config, 'mcp', 'tokenRef', '')).trim() || defaults.mcp.tokenRef,
      file: String(pick(config, 'mcp', 'tokenFile', '')).trim() || defaults.mcp.tokenFile,
    },
    {
      slot: 'peer-a2a',
      label: '对端 A2A（出站）',
      ref: String(pick(config, 'peer', 'a2a', '')?.tokenRef ?? '').trim() || defaults.peer.a2a.tokenRef,
      file: String(pick(config, 'peer', 'a2a', '')?.tokenFile ?? '').trim() || defaults.peer.a2a.tokenFile,
    },
    {
      slot: 'peer-mcp',
      label: '对端 MCP（出站）',
      ref: String(pick(config, 'peer', 'mcp', '')?.tokenRef ?? '').trim() || defaults.peer.mcp.tokenRef,
      file: String(pick(config, 'peer', 'mcp', '')?.tokenFile ?? '').trim() || defaults.peer.mcp.tokenFile,
    },
  ]
}

// ---------------------------------------------------------------------------
//  落盘
// ---------------------------------------------------------------------------

/**
 * 原子写一个文件（同目录 tmp + rename），避免宿主读到半截 JSON。
 * @param path - 目标路径。
 * @param content - 文本内容。
 */
function writeAtomic(path, content) {
  mkdirSync(dirname(path), { recursive: true })
  const tmp = `${path}.tmp-${process.pid}`
  writeFileSync(tmp, content, { encoding: 'utf8' })
  renameSync(tmp, path)
}

/**
 * 读既有 config.json；坏 JSON 视为「没有」，绝不因此失败。
 * @param path - config.json 路径。
 * @returns 解析出的对象，或空对象。
 */
function readExistingConfig(path) {
  try {
    if (!existsSync(path)) return {}
    const parsed = JSON.parse(readFileSync(path, 'utf8'))
    return parsed !== null && typeof parsed === 'object' ? parsed : {}
  } catch {
    return {}
  }
}

/** state/config.json 的绝对路径。 */
function configJsonPath() {
  return join(STATE_DIR, 'config.json')
}

/**
 * 物化 state/config.json。
 * @param config - apply 收到的配置对象。
 * @param log - 日志函数。
 * @returns 写入结果 `{ path, roots, role }`。
 */
function materializeConfigJson(config, log) {
  const path = configJsonPath()
  const existing = readExistingConfig(path)
  const merged = normalize(config, existing)
  writeAtomic(path, `${JSON.stringify(merged, null, 2)}\n`)
  log('info', `config.json 已物化 -> ${path} (role=${merged.role} roots=${merged.roots.length})`)
  return { path, role: merged.role, roots: merged.roots.length }
}

// ---------------------------------------------------------------------------
//  凭据 seam（token 值的唯一来源）
// ---------------------------------------------------------------------------

/**
 * 取凭据 seam；部署不提供时返回 undefined（降级为「只配路径」）。
 * 不声明必需 inject：没有凭据服务的部署也要能启动。
 * @param ctx - 插件上下文。
 * @returns `{ resolve, describe, set, unset }` 或 undefined。
 */
function credentialFace(ctx) {
  try {
    const get = ctx?.get
    if (typeof get !== 'function') return undefined
    const face = get.call(ctx, 'credentials')
    if (face === undefined || face === null) return undefined
    const usable = typeof face.resolve === 'function' && typeof face.describe === 'function'
    return usable ? face : undefined
  } catch {
    return undefined
  }
}

/**
 * 凭据引用名文法：与 DSH refs 段一致（POSIX 标识符 / 环境变量形状）。
 * @param name - 候选引用名。
 * @returns 是否合法。
 */
function isRefName(name) {
  return typeof name === 'string' && /^[A-Za-z_][A-Za-z0-9_]*$/.test(name)
}

/**
 * 解析一个 token 槽位的当前值。
 * @param face - 凭据 seam。
 * @param slot - 槽位。
 * @returns `{ configured, value }`；value 仅供写文件，**绝不出现在任何返回值/日志里**。
 */
async function resolveSlot(face, slot) {
  if (!isRefName(slot.ref)) return { configured: false, value: '', reason: 'bad-ref-name' }
  try {
    const described = await face.describe(slot.ref)
    if (described?.configured !== true) return { configured: false, value: '' }
    const resolved = await face.resolve(slot.ref)
    const value = typeof resolved?.value === 'string' ? resolved.value.trim() : ''
    if (value === '') return { configured: false, value: '' }
    if (/[\r\n]/.test(value)) return { configured: false, value: '', reason: 'multiline' }
    return { configured: true, value }
  } catch {
    return { configured: false, value: '' }
  }
}

/**
 * 把凭据存储里的 token 同步成 token 文件（单向：存储 → 文件）。
 * 规则：引用未配置 / 值为空 → 什么都不做（既有文件保持不动）。
 * @param ctx - 插件上下文。
 * @param config - apply 收到的配置对象。
 * @param log - 日志函数。
 * @returns 每个槽位的结果（不含值）。
 */
async function syncTokenFiles(ctx, config, log) {
  const face = credentialFace(ctx)
  if (face === undefined) {
    log('warn', '凭据存储不可用：token 只按路径使用（state/*.token 由人手放）')
    return []
  }
  const results = []
  for (const slot of tokenSlots(config)) {
    const outcome = await resolveSlot(face, slot)
    const absolute = isAbsolute(slot.file) ? slot.file : resolvePath(BUNDLE_DIR, slot.file)
    let wrote = false
    if (outcome.configured) {
      try {
        const current = existsSync(absolute) ? readFileSync(absolute, 'utf8').trim() : ''
        if (current !== outcome.value) {
          writeAtomic(absolute, `${outcome.value}\n`)
          wrote = true
        }
      } catch (error) {
        log('warn', `写 token 文件失败（${slot.slot}）: ${error?.message ?? error}`)
      }
    }
    results.push({ slot: slot.slot, ref: slot.ref, configured: outcome.configured, file: slash(absolute), wrote })
  }
  const applied = results.filter((item) => item.configured).length
  log('info', `token 同步：凭据存储命中 ${applied}/${results.length}（未命中的槽位保持既有文件不动）`)
  return results
}

// ---------------------------------------------------------------------------
//  宿主工具：token 值的唯一输入面
// ---------------------------------------------------------------------------

/**
 * 注册 `team_link_setup` 工具：把 token 值写进 DSH 凭据存储，并立即物化到 token 文件。
 *
 * 为什么要这个工具：DSH 0.2.2-rc.1 **没有**「按 Config Schema 自动渲染原生表单」这层 UI，
 * 也没有任何通用面板能收密文；schemastery 3.19.0 也没有 secret/password 类型。
 * 宿主侧唯一合法的「收 token 值」入口就是宿主工具（对标 task_board_github_setup：
 * 值只进凭据存储，任何工具都取不回）。工具只回报 configured/文件存在性，永不返回值。
 *
 * @param ctx - 插件上下文。
 * @param config - apply 收到的配置对象。
 * @param log - 日志函数。
 */
function registerSetupTool(ctx, config, log) {
  const tools = ctx?.tools
  if (tools === undefined || typeof tools.register !== 'function') {
    log('warn', 'tools 服务不可用：team_link_setup 未注册（配置与 token 文件仍可用）')
    return
  }
  tools.register({
    name: 'team_link_setup',
    description: [
      'Read or change the PC1<->PC2 team-link token state. Token VALUES are written into the',
      'DSH credential store (~/.dsh/.credentials.yaml refs) and immediately materialized into',
      'state/*.token; no action ever returns a token value, only booleans and file paths.',
      'Use action "status" to inspect, "set-token" to store one value, "clear-token" to remove it.',
    ].join('\n'),
    parameters: {
      type: 'object',
      properties: {
        action: { type: 'string', enum: ['status', 'set-token', 'clear-token'], description: 'Operation to perform.' },
        token: { type: 'string', enum: TOKEN_SLOTS, description: 'Which token slot; required for set-token and clear-token.' },
        value: { type: 'string', description: 'The secret value; required for set-token. Stored host-side, never returned.' },
      },
      required: ['action'],
      additionalProperties: false,
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          ok: { type: 'boolean' },
          report: { type: 'string' },
        },
        required: ['ok', 'report'],
      },
      render: (_args, value) => [{ type: 'text', text: value.report }],
    },
    async execute(args) {
      const action = String(args?.action ?? '')
      const slots = tokenSlots(config)
      const face = credentialFace(ctx)

      if (action === 'status') {
        const lines = ['team-link 配置与 token 状态（只报存在性，不返回值）：']
        lines.push(`  bundle: ${slash(BUNDLE_DIR)}`)
        const cfgPath = configJsonPath()
        lines.push(`  config.json: ${existsSync(cfgPath) ? 'present' : 'MISSING'} -> ${slash(cfgPath)}`)
        lines.push(`  凭据存储: ${face === undefined ? 'unavailable' : 'available'}`)
        for (const slot of slots) {
          const absolute = isAbsolute(slot.file) ? slot.file : resolvePath(BUNDLE_DIR, slot.file)
          const stored = face === undefined ? false : (await resolveSlot(face, slot)).configured
          const fileBytes = existsSync(absolute) ? statSync(absolute).size : 0
          lines.push(
            `  ${slot.slot.padEnd(9)} ref=${slot.ref} credential=${stored ? 'configured' : 'absent'}`
            + ` file=${fileBytes > 0 ? `present(${fileBytes}B)` : 'MISSING'} ${slash(absolute)}`,
          )
        }
        return { ok: true, report: lines.join('\n') }
      }

      const slot = slots.find((item) => item.slot === String(args?.token ?? ''))
      if (slot === undefined) {
        return { ok: false, report: `team_link_setup: "${args?.token ?? ''}" 不是有效槽位（${TOKEN_SLOTS.join(' / ')}）` }
      }
      if (face === undefined) {
        return { ok: false, report: 'team_link_setup: 本部署不提供凭据存储，无法写入 token 值（降级：把 token 手工放进 ' + slash(slot.file) + '）' }
      }
      if (!isRefName(slot.ref)) {
        return { ok: false, report: `team_link_setup: 引用名 "${slot.ref}" 不是合法凭据引用名` }
      }

      if (action === 'clear-token') {
        try {
          await face.unset(slot.ref)
          log('info', `凭据已清除：${slot.ref}（token 文件保留，由人决定是否删除）`)
          return { ok: true, report: `已从凭据存储移除 ${slot.ref}；token 文件保留未动：${slash(slot.file)}` }
        } catch (error) {
          return { ok: false, report: `清除失败：${error?.message ?? error}` }
        }
      }

      if (action === 'set-token') {
        const value = typeof args?.value === 'string' ? args.value.trim() : ''
        if (value === '') return { ok: false, report: 'team_link_setup: value 不能为空（空值无法存储；清除请用 clear-token）' }
        if (/[\r\n]/.test(value)) return { ok: false, report: 'team_link_setup: value 不能含换行' }
        try {
          await face.set(slot.ref, value)
        } catch (error) {
          return { ok: false, report: `写入凭据存储失败：${error?.message ?? error}` }
        }
        // 立即物化，免去「改了凭据还得重启才生效」的困惑。
        const absolute = isAbsolute(slot.file) ? slot.file : resolvePath(BUNDLE_DIR, slot.file)
        try {
          writeAtomic(absolute, `${value}\n`)
        } catch (error) {
          return { ok: true, report: `已写入凭据存储 ${slot.ref}，但 token 文件写入失败：${error?.message ?? error}` }
        }
        log('info', `token 已写入凭据存储并物化：${slot.ref} -> ${slash(absolute)}（值不打印）`)
        return { ok: true, report: `已写入凭据存储 ${slot.ref} 并物化到 ${slash(absolute)}。值不会被任何工具读回。` }
      }

      return { ok: false, report: `team_link_setup: 未知 action "${action}"（status / set-token / clear-token）` }
    },
  })
}

// ---------------------------------------------------------------------------
//  apply
// ---------------------------------------------------------------------------

/**
 * 造一个日志器：优先宿主 logger，其次 console。
 * 日志内容**永不包含 token 值**（只包含槽位名、引用名、路径）。
 * @param ctx - 插件上下文。
 * @returns `(level, message) => void`。
 */
function makeLogger(ctx) {
  const logger = ctx?.logger
  const prefix = '[team-link]'
  return (level, message) => {
    const text = `${prefix} ${message}`
    try {
      if (logger !== undefined && typeof logger[level] === 'function') {
        logger[level](text)
        return
      }
      if (logger !== undefined && typeof logger.info === 'function') {
        logger.info(text)
        return
      }
    } catch {
      // 日志失败绝不影响主流程。
    }
    try {
      // eslint-disable-next-line no-console
      console[level === 'warn' || level === 'error' ? 'warn' : 'log'](text)
    } catch {
      // ignore
    }
  }
}

/**
 * 插件入口。**同步部分先跑完**（config.json 必须在 MCP 客户端那一行启动子进程之前落地），
 * 异步部分（凭据 → token 文件）随后进行；任何异常都降级为日志，绝不向外抛。
 *
 * @param ctx - 插件上下文。
 * @param config - profile 里本行的 config 块（缺省时按默认值重建）。
 */
export function apply(ctx, config) {
  const log = makeLogger(ctx)
  const rawConfig = config ?? {}

  // 1) 先做同步的 config.json 物化：顺序敏感，见 cordis.patch.yml.tmpl 的行序说明。
  let materialized
  try {
    materialized = materializeConfigJson(rawConfig, log)
  } catch (error) {
    log('error', `config.json 物化失败（已降级，profile 继续启动）: ${error?.message ?? error}`)
    // 降级再试一次：拿纯默认值兜底。理由是「配置写坏了」不该让 MCP 子进程连配置文件都没有 ——
    // 服务端读到合法但保守的 config.json，比读到缺失/半截文件好得多。
    try {
      materialized = materializeConfigJson({}, log)
      log('warn', '已用默认值兜底重建 config.json（本轮 Config 内容未生效）')
    } catch (fallbackError) {
      log('error', `默认值兜底也失败（放弃物化，profile 继续启动）: ${fallbackError?.message ?? fallbackError}`)
      materialized = undefined
    }
  }

  // 2) 宿主工具（失败不影响启动）。
  try {
    registerSetupTool(ctx, rawConfig, log)
  } catch (error) {
    log('warn', `team_link_setup 注册失败（已降级）: ${error?.message ?? error}`)
  }

  // 3) 异步：凭据存储 → token 文件。故意不 await：不让 profile 启动等网络/IO。
  Promise.resolve()
    .then(() => syncTokenFiles(ctx, rawConfig, log))
    .catch((error) => {
      log('warn', `token 同步失败（已降级，既有文件不动）: ${error?.message ?? error}`)
    })

  if (materialized !== undefined) {
    log('info', `已就绪：role=${materialized.role} roots=${materialized.roots} config=${slash(materialized.path)}`)
  }
}
