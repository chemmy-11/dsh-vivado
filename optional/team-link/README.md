# dsh-vivado-team-link

**dsh-vivado 的可选协作插件**：把 PC1↔PC2 两台工作站做成"同等权限、靠约定协作"的组员对，而不是主机/受控端。

- 独立 bundle 片段，**默认不进入 Vivado 预设**，只有你显式安装才生效。
- **不改 dsh-vivado 的任何生成文件**（`cordis.patch.yml` / `install.ps1` / `packages/` / `patches/` / `skills/` / `tools/` / `templates/` / `config.yml`）；安装器会自证这一点（前后 SHA256 全量比对）。
- 与 kit 职责不重叠：仿真、构建、ILA 解析仍走 `mcp__vivado__*` + kit 技能；本插件只提供**协作层**（通道、口令、证据搬运、回退）。

## 1. 角色定位

| | PC1 | PC2 |
|---|---|---|
| 角色 | lead | 板 B 侧实物负责人 |
| 权限 | full access | **同等 full access**（不降权） |
| 管什么 | 优先级、共享仓提交、构建与烧录窗口、判据裁决 | 板 B 的烧录/串口/ILA/抓包/证据，板侧范围内自主行动，可提方案 |
| 不该做什么 | 不替 PC2 决定板侧细节 | 不擅自改共享仓判据、不抢构建窗口 |

跨机**只交换决策与证据**，不互相 micromanage。约束力来自口令与审计，不来自降权 —— 所以"约定"必须写在 `skills/prj-team-collab/SKILL.md` 里，并被两台机器同时加载。

## 2. 目录

```
optional/team-link/
  plugin.json              # 本插件清单（可选安装、端口、写入范围、回滚方式）
  package.json             # DSH bundle 描述符（dsh.bundle.patch -> cordis.patch.yml）
  lib/
    index.js               # 宿主半边：导出 name / Config / apply，物化 config.json、把凭据写进 token 文件
    client.js              # 浏览器半边：GUI 配置卡片（手写 bundle，注册进 plugins.row.config；见 §4.7）
  cordis.patch.yml.tmpl    # 由 install.ps1 渲染成 cordis.patch.yml（注入两条：team-link + mcp-team-link）
  cordis.patch.yml         # 渲染产物（install 生成，uninstall -Purge 删除）
  install.ps1              # 注册 bundle + 拷 skill + 写配置 + kit 哈希自证
  uninstall.ps1            # 完整回滚（摘注册 / 删 skill / 可选清产物 / 复核哈希）
  server/
    team-link-a2a.mjs      # A2A：AgentCard + message/send + tasks/get（HTTP，Bearer）
    team-link-mcp.mjs      # MCP：list_roots / read_file / write_file / sha256_file / collab_status
                           #      双传输 —— stdio（DSH 插件用）+ http（跨机 + 自环用）
  client/
    a2a-selfloop.mjs       # A2A 自环验证
    mcp-selfloop.mjs       # MCP 自环验证（含越权与 SHA256 校验）
  tools/
    collab_status.ps1      # 通道/端口/时钟偏移/回退状态（通道断 -> 明确提示转 issue 轮询并写日志）
    pc1_pc2_ping.ps1       # 对端探测（含 192.168.1.x 网段守卫，防连错机器）
    evidence_pull.ps1      # 走 MCP 拉对端证据并本地复核 SHA256
    apply-selftest.mjs     # 宿主半边离线自测（在临时目录里跑 apply()，不碰真 state/）
  skills/prj-team-collab/SKILL.md   # 角色 / 发令回报格式 / 证据目录 / 硬件约定 / issue 回退
  templates/
    PC2_上线清单.md        # PC2 上线 checklist（本插件最终交付物之一）
    AgentCard.template.json
    daily-audit-issue.md
  state/                   # 生成物（.gitignore 忽略）
    config.example.json    #   schema v2 模板：进包，去作者机痕迹，roots 只有 state 一条
    config.json            #   生成物：install.ps1 首生成，此后由 lib/index.js 的 apply() 物化维护
    *.token                #   生成物：入站 a2a/mcp、出站 peer-a2a/peer-mcp（服务端启动时读）
  logs/                    # 运行日志（不进 git）
```

## 3. 安装 / 卸载 / 回滚

```powershell
# 安装（默认注册到 desktop profile；-RegisterMode Manual 为完全离线等价路径）
powershell -NoProfile -File install.ps1 -Profile desktop
powershell -NoProfile -File install.ps1 -Profile desktop -RegisterMode Manual   # 不调用 pnpm/dsh CLI

# 状态
powershell -NoProfile -File tools\collab_status.ps1

# 卸载（保留源码与日志，摘除注册与 skill）
powershell -NoProfile -File uninstall.ps1 -Profile desktop

# 卸载并清理生成物
powershell -NoProfile -File uninstall.ps1 -Profile desktop -Purge
```

安装器做了什么，按顺序：

1. 预检必需文件 + 解析 node(>=20)；
2. 对 **kit 全部文件（排除 `optional/`）** 记录 SHA256 基线 → `state/kit-manifest.before.sha256`；
3. 跑 `node server/team-link-mcp.mjs --selftest`，失败就中止，**绝不留下半装状态**；
4. 生成 `state/a2a.token`、`state/mcp.token`（首次生成后复用）；
5. 生成 `state/config.json`（角色、端口、授权根目录、对端占位、回退参数）；此后这份文件由宿主半边 `apply()` 物化维护（见 §4.4），install 只保证首版可用；
6. 渲染 `cordis.patch.yml`（**两条**：先 `team-link` 宿主插件，再 `mcp-team-link` stdio 客户端；顺序不能换，见 §4.2）；
7. 拷 `skills/prj-team-collab` → `<DshHome>\skills\prj-team-collab`，并记指纹；
7.1 建 `node_modules/@deepseek-ai/schemastery` junction（指向 profile 里的那份）——本插件按 `link:` 注册，`lib/index.js` 靠这个确定性锚点解析 schemastery；拿不到时 `Config` 降级为 `undefined`，插件仍按内置默认值启动（`node_modules/` 已进 `.gitignore`，不入仓）；
8. 注册 bundle：`dsh plugin --profile <p> add link:<bundleDir>`（= pnpm link: + 写入 `dsh.profile.bundles`），并校验"条目在 + node_modules 链接在"；
9. 重算 kit SHA256 → **必须与基线完全一致**，否则 FAIL 并让你看差异清单。

**生效需要重启宿主**（Electron 下 dsh-hmr 不生效）。重启后新会话里出现 `mcp__team_link__*` 工具与宿主工具 `team_link_setup`。

回滚语义：`uninstall.ps1` 摘除注册 → 校验并删除 skill 副本（若你改过 skill 文件，默认**不删**并提示，需 `-Force`）→ 残留检查 → 可选清产物 → 再次复核 kit 哈希。`-UnregisterMode Restore` 会用安装前备份整体还原 `package.json`（仅适用于"刚装就回滚"，否则会丢掉之后新装的插件）。

## 4. 设置与配置（**有 GUI 面板了**：设置 → 插件 → 本行 → 配置）

### 4.1 结论先行

配置有两个入口，改的是**同一份** profile 配置：

1. **GUI 卡片（推荐）**：`设置 → 插件 → 已安装的插件 → dsh-vivado-team-link → 行 team-link → 配置`。
   面板能改角色 / 机器名 / A2A·MCP 的 host 与 port / 对端名字与地址 / 回退仓库与标签与轮询间隔 / 日志目录 / 授权根。
   **它不收 token 值**（原因见 §4.5），只显示 token 的引用名与文件路径。
2. **profile 配置项**：`cordis.patch.yml` 的 `config:` 块。卡片保存的也是这里 —— 宿主会把改动的字段写成一条
   `- id: team-link` 的覆盖项，所以「GUI 改」与「手改 YAML」不会打架。

GUI 面板**不是宿主自动生成的**：DSH 0.2.2-rc.1 没有「按 Config Schema 自动渲染原生表单」这层 UI，面板只能由插件
自己占一个 keyed slot。四条证据（均已核对）：

| # | 证据 | 说明 |
|---|---|---|
| 1 | `@deepseek-ai/dsh-client-ui-settings/README.zh.md` 自述「**自身不渲染任何界面**」 | 设置分区本身不含任何按 schema 生成的控件 |
| 2 | 设置→插件的配置页是 **keyed slot `plugins.row.config`**；全 asar 只有 owner 侧的 `renderSlot` 与文档示例，**没有通用 occupant** | 宿主不会"看到一个 Config 就替你画表单" |
| 3 | `dsh-client-ui-settings-plugins/lib/client.js`：「插件配置页住在各自的伴生包里，本分区只拥有导航项和 tab 外壳」 | 面板必须由插件自己注册 |
| 4 | `@linxin666/*` 每个设置面板都是各包自带的 `*SettingsCard.tsx`（实例：`@linxin666/dsh-agents/src/client/AgentsSettingsCard.tsx`） | 现状是"谁有面板谁自己写" |

所以本插件自带 `lib/client.js`（**手写 bundle + `React.createElement`，无 JSX、无构建步骤**），
通过 `package.json` 的 `dsh.client` + `exports["./client"]` 交给宿主，注册进 `plugins.row.config`
（键 `<包名>#<行 id>` = `dsh-vivado-team-link#team-link`）。实现细节与踩过的坑见 §4.7。

旁证：**schemastery 3.19.0** 没有 secret / password 类型。所以即使哪天宿主开始自动渲染表单，
密文输入框在 schema 层也没有承载物 —— token 值永远不走配置。落地方式是：**配置项收非密参数**，
**宿主工具 `team_link_setup` 收 token 值**（值只进凭据存储，见 §4.5）。

### 4.2 两半结构：宿主插件 + MCP 客户端

`cordis.patch.yml` 从一行变**两行**（`install.ps1` 从模板渲染，`uninstall.ps1` 整体删除）：

| 顺序 | id | name | 职责 |
|---|---|---|---|
| 1 | `team-link` | `dsh-vivado-team-link`（本插件，`lib/index.js`） | 读 profile 配置 → **物化** `<bundle>/state/config.json`；再把凭据存储里的引用值写成 `state/*.token` |
| 2 | `mcp-team-link` | `@deepseek-ai/dsh-mcp-client` | stdio 挂 MCP 服务端；`serverName` 仍是 `team_link`，工具名仍是 `mcp__team_link__*` |

**顺序有意义**：`team-link` 先把 `config.json` 物化到磁盘，`mcp-team-link` 才读得到它（通过 `TEAM_LINK_CONFIG` 环境变量指过去）。顺序反了会让服务端在配置缺失/上一轮配置的情况下起（`failOnStartupError: false` 时表现为"静默没有工具"）。
`apply()` 内部也是按这个顺序做的：**同步**物化 `config.json` → 注册 `team_link_setup` → **异步（不 await）**同步 token 文件，不让 profile 启动等 IO。

### 4.3 Config 字段（全部非密）

字段落在 profile 里本插件那一行的 `config:` 块。`install.ps1` 渲染 `cordis.patch.yml` 时默认只写下面这些（值来自 `-Role` / `-A2aPort` / `-McpPort` 与 bundle 路径）：

```yaml
- insert:
    - id: team-link
      name: 'dsh-vivado-team-link'
      config:
        role: 'pc1'
        a2a:
          host: 127.0.0.1          # 跨机时改成实际网卡地址（WLAN / 第二网卡 / Tailscale，见 §6）
          port: 7310
          tokenFile: '<bundle>/state/a2a.token'
          tokenRef: TEAM_LINK_A2A_TOKEN
        mcp:
          host: 127.0.0.1
          port: 18790
          tokenFile: '<bundle>/state/mcp.token'
          tokenRef: TEAM_LINK_MCP_TOKEN
        peer:
          name: pc2
          a2a:
            tokenFile: '<bundle>/state/peer-a2a.token'
            tokenRef: TEAM_LINK_PEER_A2A_TOKEN
          mcp:
            tokenFile: '<bundle>/state/peer-mcp.token'
            tokenRef: TEAM_LINK_PEER_MCP_TOKEN
        # roots 故意不写：配置项不表态 -> 沿用 state\config.json 既有 roots（升级不丢根）
        # 要加根就解开并**写全**（一旦写就是整表替换）：
        # roots:
        #   - { id: state, path: '<bundle>/state', mode: rw }
        #   - { id: evidence, path: 'D:/your/evidence', mode: rw }
        logDir: logs
```

渲染模板**没写**、需要时手动补的三项：`fallback.repo`（回退轮询的仓库；首版 `config.json` 里通常已有，没写配置项时不会被覆盖）、`peer.a2aUrl` / `peer.mcpUrl`（跨机出站要用）、以及上面注释里的 `roots`（要改授权根才写）。

> **roots 的继承规则（升级不丢根）**：配置项没写 `roots`（或写了空数组）→ 沿用磁盘既有 `roots`；
> 写了**非空** `roots` → **整表替换**。所以升级时不要为了"补一条 state 根"把 `roots` 写进配置项 ——
> 那会把 `config.json` 里的 `evidence` / `delivery` 根一起顶掉。真写了就必须把要用的根全部列出来。

| 字段 | 默认值 | 说明 |
|---|---|---|
| `role` | `pc1` | `pc1` / `pc2` |
| `machine` | `role` 的大写（如 `PC1`） | 显示名，进日志与 `collab_status` 回显 |
| `a2a.host` | `127.0.0.1` | A2A 绑定地址；本轮默认不开外网监听 |
| `a2a.port` | `7310` | |
| `a2a.tokenFile` | `<bundle>/state/a2a.token` | 入站 token 文件（只有路径，没有值） |
| `a2a.tokenRef` | `TEAM_LINK_A2A_TOKEN` | 凭据存储里的引用名（见 §4.5） |
| `mcp.host` | `127.0.0.1` | |
| `mcp.port` | `18790` | |
| `mcp.tokenFile` | `<bundle>/state/mcp.token` | 入站 token 文件 |
| `mcp.tokenRef` | `TEAM_LINK_MCP_TOKEN` | |
| `peer.name` | `pc2` | 对端名字 |
| `peer.a2aUrl` | 空串 | 对端 A2A 地址（出站） |
| `peer.mcpUrl` | 空串 | 对端 MCP 地址（出站） |
| `peer.a2a.tokenFile` | `<bundle>/state/peer-a2a.token` | **对端**的 token，出站用 |
| `peer.a2a.tokenRef` | `TEAM_LINK_PEER_A2A_TOKEN` | |
| `peer.mcp.tokenFile` | `<bundle>/state/peer-mcp.token` | **对端**的 token，出站用 |
| `peer.mcp.tokenRef` | `TEAM_LINK_PEER_MCP_TOKEN` | |
| `roots[]` | 空数组 = 不表态（沿用磁盘既有；磁盘也没有才用 `[{ id: "state", path: "<bundle>/state", mode: "rw" }]`） | 授权根目录，元素为 `{ id, path, mode }`；`list_roots` 暴露的就是这份清单。**写了就整表替换** |
| `fallback.repo` | 空串（配置项不写则沿用 `config.json` 既有值） | 回退 issue 轮询的仓库 |
| `fallback.issueLabel` | `collab-audit` | |
| `fallback.pollSeconds` | `900` | |
| `logDir` | `logs` | 相对 `<bundle>` 或绝对路径 |

`config.json` 里还有一批 **Config 不拥有的键**，物化时**原样保留**、不由配置项覆盖：`version`、`a2a.path`、`a2a.agentCardPath`、`a2a.bindSelfLoop`、`mcp.path`、`peer.wlan`、`peer.tailscale`、`peer.note`、`fallback.mode`、`evidenceDir`。
（这也是"在配置项里少写几个字段"不会把 `config.json` 里的历史字段抹掉的原因。）

### 4.4 `apply(ctx, config)` 的确定行为

- **物化**：把配置写成 `<bundle>/state/config.json`（schema v2，`version` 恒为 `2`）。服务端与三个运维脚本（`tools/collab_status.ps1`、`tools/evidence_pull.ps1`、`tools/pc1_pc2_ping.ps1`）读的都是这**一个**文件。
- **以磁盘为底 + 三级优先级**：每个托管字段的取值顺序是 **配置项 → 磁盘既有值 → 默认值**。
  空串 / 缺省一律视为"配置项没表态"，落到磁盘值（这一条是回归保护：Config 里每个字段都带
  `.default()`，"没写"与"写了默认值"在 `apply()` 里无法区分，直接覆盖会把磁盘上手配的
  `fallback.repo` 冲成空串——曾经的 bug，`tools/apply-selftest.mjs` 场景 3 已锁）。
- **roots 的合并规则**（容易踩）：Config 里给了**非空** `roots` → **整表替换**；没给 → 沿用磁盘既有 `roots`；磁盘也没有 → 默认 `state` 一条。
- **可重建**：`config.json` 不存在 / 被删 → 下次 `apply()` 按默认值重建。
- **绝不 throw**：任何内部异常都降级为日志。物化失败会用**纯默认值兜底重建一次**，再失败就放弃物化、profile 照常启动。理由很直接——宿主插件抛异常会拖垮**整个 profile 启动**，一个协作层没有这个权力；宁可协作层静默退化，也不让 DSH 起不来。
- **token 物化**：见 §4.5，`apply()` 只写文件、不回显值；这一步是异步的（不 await），失败也不影响启动。

### 4.5 token 值怎么进来：凭据存储 → token 文件

值只走一条单向链路，配置与表单**永远只有路径和引用名**：

```
team_link_setup(action=set-token, value=…)
        └→ ~/.dsh/.credentials.yaml 的 refs: 段（键 = 引用名，形如 TEAM_LINK_A2A_TOKEN）
apply()  └→ ctx.get('credentials') 读引用 → 写 <tokenFile>（state/a2a.token 等，服务端启动时读）
```

- 引用未配置时，`apply()` **保持既有 token 文件不动**（不删、不清空）。所以 `install.ps1` 生成的自签 token 不会被物化冲掉。
- **`set-token` 当场落盘**：写进凭据存储后，同一次工具调用里就把值物化到 `<tokenFile>`（不必等重启才写文件）。但运行中的 A2A/MCP 服务是**启动时**读 token 的，要让新值在通道上生效**仍需重启宿主**。
- 四条 `refs:` 键默认是：`TEAM_LINK_A2A_TOKEN`、`TEAM_LINK_MCP_TOKEN`、`TEAM_LINK_PEER_A2A_TOKEN`、`TEAM_LINK_PEER_MCP_TOKEN`（名字可在 §4.3 的 `*.tokenRef` 里改；引用名须是 `[A-Za-z_][A-Za-z0-9_]*` 形状）。
- 部署不提供凭据存储时（`ctx.get('credentials')` 拿不到），`team_link_setup` 会报不可用并提示降级办法：把 token 手工放进 `state/*.token`。

`team_link_setup` 用法（**这是模型工具调用，不是 PowerShell 命令**）：

```
team_link_setup { action: "status" }
team_link_setup { action: "set-token", token: "a2a",      value: "<本机自签的 32 字节 hex>" }
team_link_setup { action: "set-token", token: "peer-a2a", value: "<对端交给你的 hex>" }
team_link_setup { action: "clear-token", token: "peer-mcp" }
```

| 参数 | 取值 |
|---|---|
| `action` | `status` / `set-token` / `clear-token` |
| `token` | `a2a` / `mcp`（本机**入站**，校验来客）· `peer-a2a` / `peer-mcp`（对端**出站**，调用对端） |
| `value` | 仅 `set-token` 用；不能为空、不能含换行；只进凭据存储，**工具永不返回值** |

行为约定：

- **只说布尔事实**：`status` 逐槽位报 `credential=configured|absent`、`file=present(<N>B)|MISSING`，外加 `config.json=present|MISSING`、`凭据存储=available|unavailable`；**没有任何一档会回显 token 值**。
- `clear-token` 只删引用，**保留**既有 token 文件（由人决定要不要删）。
- 任何一层都**不打印 token 值**，只报存在性：
  - `tools/collab_status.ps1` 会多打一行 `token : a2a=present(65B) mcp=present(65B) peer-a2a=MISSING peer-mcp=MISSING`
    （只看文件长度，**不读内容**；`-Json` 时同一信息在 `tokens` 字段里）；
  - `team_link_setup { action: "status" }` 给出同一组布尔事实，外加凭据存储 side 的 `configured/absent`。

### 4.6 为什么是"配置项 + 工具"而不是"表单"

非密参数走配置项、密文走凭据存储，是本版本唯一能落地的组合：宿主没有自动表单（§4.1 的四条证据），schemastery 3.19.0 也没有 secret 类型；硬把明文 token 塞进 `config:`，等于同时污染 profile 配置、`*.bak-*` 备份和卸载回滚链。`team_link_setup` 对标 `task_board_github_setup`：值只进凭据存储，工具自己绝不返回值。

### 4.7 GUI 卡片：怎么做的、踩过什么坑

`lib/client.js` 是一个**手写的客户端 bundle**（不引入构建链）：

```js
window.__ModuleLoader__.load({
  id: 'dsh-vivado-team-link',
  factory: (require) => {
    const React = require('react')            // 平台冻结模块表里的 react
    // …注册卡片…
    return { apply, inject: ['slots'] }
  },
})
```

要点（每条都是实测结论，不是推测）：

- **声明**：`package.json` 的 `dsh.client: { platform: 'web' }` + `exports["./client"]`。宿主的
  `dsh-client-modules` 据此把它编进启动图（`/plugins/??…,dsh-vivado-team-link/client.js&rev=…`）。
  缺了 `lib/client.js` 会让该行**激活失败**并报"缺构建产物"。
- **占位**：`ctx.slots.inject('plugins.row.config', …)` → `ctx.slots.register({ name, key }, Card)`，
  key 必须是 `<包名>#<行 id>`（本插件 `dsh-vivado-team-link#team-link`）。注册成功后，行标题变成
  可点按钮（`aria-label="配置 <包名>"`），点进去就是本卡片。
- **props**：`{ view, form }`。`view === 'summary'` 渲染列表摘要；`view === 'page'` 渲染整页。
  `form.state = { status, value, base, user, revision, writable }`，
  `form.mutate(ops, revision)`，`ops` 形如 `{ op: 'set', path: ['a2a','port'], value: 7311 }`（原子提交，冲突返回 `false`）。
- **宿主只 serve `.volatile()` 字段**：`form.state.value` 里只有标了 volatile 的字段。这条坑过一次 ——
  `tokenRef/tokenFile` 一开始没标，卡片里永远显示"未设引用名"。现在 Config 里除 `fallback.mode` 外全部 volatile。
- **绝不裸调 `ctx.get('远程服务')`**：未 inject 的服务会**抛错**，而 slot 里的异常会把整张卡片崩掉
  （实测报错 `cannot get property "remote.credentials" without inject`，面板全白）。所以卡片
  **不读凭据状态** —— 那个"已配置/未配置"徽章要 `remote.credentials` 这种非必需服务，不值得为它赌面板挂不挂载；
  权威状态请用 `team_link_setup {action:"status"}`（只报存在性、不返回值）。
- **保存后要有反应**：宿主对 volatile 字段只发 `loader/volatile-update`（**不重挂插件**），
  所以 `lib/index.js` 订阅了这条事件并重新物化 `state/config.json`；否则卡片改了、config.json 还停在启动那一刻。
- **roots 的特殊语义**：框里空 = 本配置项没声明 roots → 沿用 `state/config.json` 既有授权根（不会被清空）；
  框里非空 = **整表替换**。卡片会按当前状态把这句话显示出来，避免"以为删了其实没删"。

> 怎么在不重启 Electron 宿主的前提下验 UI：用一个临时 profile 起第二个宿主，
> `dsh --profile <临时名> --from-default-profile web --dump-config` 建 profile → 手工 junction +
> `dsh.profile.bundles` 加一条（等价 `-RegisterMode Manual`）→ `dsh --profile <临时名> --no-open --host 127.0.0.1 --port <端口>`
> → 用启动行打印的 `?token=…` URL 打开。验完删 profile、删 junction。**改客户端文件只需刷页面**
> （bundle URL 带文件元数据算出的 rev），改 `lib/index.js` / `Config` 才需要重启宿主。

## 5. 通道与端口

| 通道 | 端口 | 默认绑定 | 认证 | 用途 |
|---|---|---|---|---|
| A2A | 7310 | 127.0.0.1 | AgentCard 公开；`POST /` 必须 `Authorization: Bearer` | 发令/回报、任务状态、证据交换的"喊话" |
| MCP | 18790 | 127.0.0.1 | `Authorization: Bearer` | 授权目录内的文件读写与 SHA256 校验 |
| MCP (stdio) | 无 | — | 进程内 | DSH 挂载 `mcp__team_link__*`，本机零端口 |

端口来自 `state/config.json` 的 `a2a.port` / `mcp.port`（默认值见 §4.3），不是写死的。

**本轮不开外网监听**：两个服务默认只 bind `127.0.0.1`。要跨机，必须先确认网卡与 IP，再把 `state/config.json` 的 `a2a.host` / `mcp.host` 改成该网卡地址，并确保防火墙只对该网段放行 7310/18790。

## 6. 网络与安全（硬约束）

- **PC↔PC 不能走 `192.168.1.x`**：那是两块板各自私有的板卡链路，且两块板同 IP / 同 MAC，从 PC 侧连过去会命中"错误的那块板"，症状是"烧错了板/ILA 抓不到"而不是报错。
- 跨机只走：WLAN、第二网卡、Tailscale（三者任选其一并固定，别混）。
- 18790 / 7310 **只在内网**，且**强制 Token**（Bearer）。Token 是 32 字节随机 hex，**不进 git / 不进 issue / 不进聊天记录**；权威副本在 DSH 凭据存储的 `refs:` 段，运行时物化到 `state/*.token`（§4.5）。
- **入站与出站 token 分离（schema v2）**：
  | 方向 | 用哪个文件 | 内容归属 |
  |---|---|---|
  | 入站（校验来客） | `state/a2a.token`、`state/mcp.token` | **自己的**，本机生成 |
  | 出站（调用对端） | `state/peer-a2a.token`、`state/peer-mcp.token` | **对端的**，由对方线下交付 |
  因此两端**不需要共享同一份凭据**，任一边都可单边换 token 而不断开另一方向。未放对端 token 时 `evidence_pull` 会回落到自己的 `mcp.token`（兼容 v1 的共享 token 部署）。
- AgentCard 对外是公开的（A2A 规范要求），因此**不要在 AgentCard 里放路径、Token、板卡凭据**。
- 授权目录由 `state/config.json` 的 `roots` 定义；`list_roots` 暴露的就是这份清单，服务端拒绝绝对路径、`..` 段、以及 realpath 后跳出 root 的请求。

## 7. 什么时候该退回 issue

协作层是加速器，不是唯一真相源。出现下列任一情况，**立刻转 issue 轮询**（`collab_status.ps1` 会打印 `[FALLBACK]` 行并写日志）：

- 两条通道任一不可用（对端离线、重启中、防火墙改了、Token 不一致）；
- 对端 IP / 角色 / 判据有争议，通道上讲不清；
- 需要一条"可被第三方复核"的决策记录（烧录窗口裁决、判据变更、回滚决定）；
- 对端 AgentCard 报告的机器身份与预期不符（防连错机器）。

回退动作固定三步：① `tools/collab_status.ps1` 留证；② 在共享仓开/更 issue（用 `templates/daily-audit-issue.md` 的格式）；③ 通道恢复后用 `tools/evidence_pull.ps1` 把通道期间产生的证据补齐并复核 SHA256。

## 8. 单机验证（PC2 未上线也能全过）

```powershell
node client\a2a-selfloop.mjs --config state\config.json     # 需先起 A2A 服务
node client\mcp-selfloop.mjs --config state\config.json     # 需先起 MCP http 服务
powershell -NoProfile -File tools\collab_status.ps1          # 通道断开时须打印 [FALLBACK]
```

四项判据见 `templates/PC2_上线清单.md` 的"单机验证"小节与本仓交付记录。

## 9. 已知风险

- **从仓重装 kit 会替换整个 staging 目录（含 `optional/`）**：dsh-vivado 的 `install.ps1` 会把 kit 重新 stage 到 `<DshHome>\bundles\dsh-vivado`，这是**整目录替换**，不是增量合并——`optional/team-link/` 里的本地改动会被一起换掉。所以**开发一律在仓里做，部署副本只当运行目标**；部署副本上换完 kit 需重新跑本插件的 `install.ps1`（`state/` 里的 token 与配置若没被带走需重新生成，随后由 `apply()` 按 profile 配置物化/重建，见 §4.4）。
- **GUI 面板改的是 profile 配置，不是运行中的服务**：卡片保存后宿主会立刻重物化 `state/config.json`（`apply()` 订阅了 `loader/volatile-update`），但 A2A/MCP 两个服务是**启动时**读端口与 token 的 —— 改完要重启宿主才在通道上生效。凡是说"存了就生效"都是错的。
- **GUI 卡片不读凭据状态**（§4.7）：`remote.credentials` 是非必需服务，未 inject 就取会抛错并崩掉整张卡片，所以"token 配没配"请用 `team_link_setup {action:"status"}` 查。
- `-RegisterMode Cli` 依赖 `dsh` CLI 与 pnpm 在工作目录内解析 link:；离线或 pnpm 异常时用 `-RegisterMode Manual`（等价于手工 junction + `dsh.profile.bundles` 条目）。
- 端口冲突：7310/18790 被占用时 A2A/MCP 起不来，`collab_status.ps1` 会如实报不可用而不是假装正常。
- 中文路径：所有 `config.json` 路径建议 ASCII（与 kit 对 Vivado 的要求一致），至少 `state/` 与证据目录保持 ASCII。

## 10. 版本

0.3.0 —— **GUI 版**：新增 lib/client.js（手写客户端 bundle，零构建），把配置卡片注册进 keyed slot plugins.row.config（键 dsh-vivado-team-link#team-link）；Config 里除 allback.mode 外全部字段标 .volatile()（宿主只 serve volatile 字段），pply() 订阅 loader/volatile-update 在卡片保存后立即重物化 config.json。面板能改角色/地址/端口/对端/回退/日志目录/授权根，**不收也不显示 token 值**。已在独立测试 profile 上实测：面板渲染、保存、profile patch 落盘、config.json 重物化、roots 不丢。

0.2.0 —— **宿主半边落地版**：`cordis.patch.yml` 从一行变两行（`team-link` + `mcp-team-link`）、配置项进 profile、token 值走凭据存储、宿主工具 `team_link_setup` 上线；GUI 配置面板仍未做（§4.1 / §4.7）。
版本号以 `package.json` / `plugin.json` 为准；清单字段见 `plugin.json` 的 `provides` / `writes` / `rollback`。
