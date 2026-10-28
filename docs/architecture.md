# 架构说明 — dsh-vivado 是怎么工作的

> 读者：维护者，以及想改动本包的进阶用户。安装/卸载步骤见 [install 详解](install.md)，体检判据见 [doctor 详解](doctor-checks.md)，版本事实分档见 [版本分档](version-matrix.md)，来源与许可见 [许可审查](licensing.md) 与 [NOTICE](../NOTICE)。
>
> **读法（公开版）**：`<kit>` = 本包根目录（clone 下来的 `dsh-vivado/`）；`<DSH_HOME>` = DSH 配置根（默认 `%USERPROFILE%\.dsh`）；`<profile>` = 目标 profile 名（安装器默认 `desktop`）；`<staging>` = `<DSH_HOME>\bundles\dsh-vivado`；`<install>` = DSH 安装根（含 `DeepSeek Harness.exe`）；`<project_root>` = `config.yml` 里的工程根；`<vivado-mcp>` = vivado-mcp 的安装目录。文中绝对路径都是示例，权威值永远来自 `config.yml` 与 `doctor.ps1`。

## 1. 一句话架构：一个配置型 bundle，只提供一条预设行

本包**没有 Host/Client 入口代码**。`package.json` 只声明两件事：`dsh.bundle.patch` 指向 `./cordis.patch.yml`，`dsh.engines.dsh` 要求 `>=0.2.1-rc.2`（`package.json:27-34`）；没有 `main`/`exports`，也没有任何前端资源。装进 profile 后，它作为**patch 层**参与宿主启动时的组合，只贡献一条 preset 行，profile 自己的 `cordis.patch.yml` 不被改写（`docs/install.md:106-118`）。

```text
bundle patch（顶层只有 - insert:）
  └─ preset-vivado   @deepseek-ai/dsh-agent-preset   (config.id: vivado, order: 2)
       ├─ 22 条 shipped 插件行（persona … tool-plugin-market）
       └─ mcp-vivado   @deepseek-ai/dsh-mcp-client    (stdio, 32 tools)
```

`order: 2` 是预设列表里的排序位；默认预设仍是 `standard`，用户**新会话时手动选** `Vivado`（`templates/preset.patch.yml.tmpl:16-21`）。所以在 `standard` 会话里看不到 `mcp__vivado__*` 是设计，不是故障。

## 2. bundle patch 长什么样，22 行为什么要原样抽

模板是 `templates/preset.patch.yml.tmpl`（175 行）：一条顶层 `- insert:`，其下**只有一行** `preset-vivado`；渲染后插件列表正好 23 条顶层行 = 22 条 shipped（persona 行由 `{{PERSONA_BLOCK}}` 展开）+ 末尾 `mcp-vivado`（`:14-21`、`:152-175`）。模板文件里 persona 还是占位符，所以模板侧只数得到 22 条 `- id:`。

| 环节 | 事实 | 证据 |
|---|---|---|
| 行数断言 | 顶层插件行必须 23 条（10 空格缩进），`mcp-vivado` 必须最后一条 | `tools/make_template.py:71-83`；渲染器同样断言 `tools/render_patch.ps1:150-154` |
| 22 行来源 | 从 DSH 自带的 shipped `standard.patch.yml` **原样抽取**，不手抄 | `templates/preset.patch.yml.tmpl:3-12`；审计件 `templates/shipped-standard-22rows.yml:1-14` |
| 何时会变 | DSH 升级可能改 shipped 预设，22 行要重抽 | `tools/make_template.py:14-20`、`:289-319`（重抽需 `--source`） |

为什么必须"原样抽"而不是手抄：

1. 这 22 行里多数带 `config:`（例如 `agent-instructions.maxBytes`、`tool-fs-search.sampleOverCapGlobResults`、`tool-web.searchTimeoutMs`、`plan-mode.section`），任何一处漂移都会让预设行为悄悄变样，而 DSH 侧只认最终 patch；
2. 生成器**只允许两处改动**：persona 行整块换 `{{PERSONA_BLOCK}}`（`tools/make_template.py:105-113`）、`skill-filesystem` 行加 `customSkillDirs`（`:121-136`）；末尾追加 `mcp-vivado` 行并把 6 个机器相关值参数化（`:138-180`），发现残留绝对路径直接拒绝生成（`:178-179`）；
3. `py tools/make_template.py --check` 有两种判据：不带 `--source` 时做结构自检（行集、占位符集合、sha256 一致性，`tools/make_template.py:234-286`）；带 `--source` 时再与重生成结果逐字节比较（`:303-319`）。任一不过 exit 1。

审计件 `templates/shipped-standard-22rows.yml` **不是安装输入**：它存 21 行（persona 行以注释替身，因为 pre-kit 的 persona 里带作者机器路径），外加整 22 行归一 LF 后的 sha256；模板头部记录同一个 sha256（审计件 `:12-14`、模板 `:11-12`）。两份文件对不上时 `--check` 直接 FAIL（`tools/make_template.py:265-270`）。

## 3. 技能怎么挂上：rank 300 的 `customSkillDirs`

DSH 的 `skill-filesystem` 按 rank 从小到大发现技能根（来源：DSH 安装包内 `@deepseek-ai/dsh-skill-filesystem` 的 README「Roots and priority」与 `lib/index.js:20-24`）：

| rank | 来源 | 路径 |
|---:|---|---|
| 100 | project-dsh | `<projectRoot>/.dsh/skills` |
| 200 | project-agents | `<projectRoot>/.agents/skills` |
| 300 | **custom** | `Config.customSkillDirs`（本包用的就是这档） |
| 400 | user-dsh | `<DSH_HOME>/skills` |
| 500 | user-agents | `<agentsHome>/skills` |
| 600 | bundled | 宿主自带（`bundledSkillDir`） |

本包在 300 档挂 `<staging>/skills`（`templates/preset.patch.yml.tmpl:46-52`），`includeDefaultRoots` 保持默认 `true`，所以用户自己的 100/200/400/500 根照常生效、不会被本包挤掉。

- **为什么不用 100/200**：`projectRoot` 是「最近一个含 `.git` 的祖先目录，没有则用当前 cwd」（同上 README）。也就是说这两个根由**会话从哪个目录开**决定，本包无法控制；写进去等于要求技能目录跟着用户的仓库走，还会把本包的技能混进别人的项目。
- **为什么不写 `<DSH_HOME>/skills`**：那是 400 档的用户根，属于用户资产。写进去既越界，也会让「卸载只删 staging」这个承诺失效——安装器确实从不写它（`docs/install.md:115`）。
- 挂载点错位的后果是"装完了但技能不出现"，所以 doctor 第 10 项会检查 `customSkillDirs` 指向的目录**真实存在**（`doctor.ps1:979-1028`），第 13 项再逐目录核对 `SKILL.md` 的 `name:` 等于目录名（`doctor.ps1:1162`）。

## 4. 为什么 patch 不能预置在仓库里

渲染后的 patch 里至少 7 个值是**这台机器特有**的：`customSkillDirs`、MCP 的 `command` / `PYTHONPATH` / `VIVADO_PATH` / `cwd` / `TEMP` / `TMP`（`templates/preset.patch.yml.tmpl:152-175`），再加 persona 里的 part、工程根、Vivado 路径、解释器（`templates/persona/2023.1.frag.yml:5-8`）。仓库里放一份渲染结果，要么带着作者的机器路径（分发红线），要么对每个用户都是错的。所以链路固定为 `config.yml` → `tools/render_patch.ps1` → `cordis.patch.yml`。

替换是**字面** `String.Replace`，不是正则，所以含 `\`、`$`、`[`、空格的路径不会被解释（`tools/render_patch.ps1:121-128`）。占位符分两层：

| 占位符 | 渲染值 | 语义 |
|---|---|---|
| `{{PERSONA_BLOCK}}` | persona 片段全文（片段自己先渲染一遍） | persona 行整块（含 10 空格缩进） |
| `{{SKILLS_DIR}}` | `-SkillsDir`，默认 `<staging>/skills` | `skill-filesystem.customSkillDirs` |
| `{{KIT_DIR}}` | `-BundleDir`，默认 bundle 根（安装时就是 `<staging>`） | 只出现在 persona 片段里：指向随包的 `tools/vivado-probe.ps1` / `vivado-run.ps1` 与 `templates/build-markers.tcl` |
| `{{MCP_PYTHON}}` | `config.yml: python` | MCP stdio `command` |
| `{{MCP_SITE}}` | `vivado_mcp_site` | MCP 环境变量 `PYTHONPATH` |
| `{{VIVADO_BAT}}` | `<vivado_path>/vivado.bat`（可被 `vivado_bat` 覆盖） | MCP 环境变量 `VIVADO_PATH` |
| `{{MCP_CWD}}` | `vivado_mcp_cwd` | MCP 进程 cwd |
| `{{TEMP_DIR}}` | `temp_dir` | MCP 环境变量 `TEMP` / `TMP` |
| `{{TOOL_COUNT}}` | 常量 `32` | 预设 description 里的工具数 |
| `{{KIT_VERSION}}` | `package.json` 的 `version` | 预设 description 里的包版本 |
| `{{PART}}`、`{{PROJECT_ROOT}}`、`{{VIVADO_VERSION}}`、`{{VIVADO_PATH}}`、`{{PYTHON}}` | 同名 config 值 | 只出现在 persona 片段里，不直接出现在模板里 |

- 模板层面的占位符是上表**前 9 个**（`PERSONA_BLOCK` … `KIT_VERSION`），`make_template.py --check` 把这个集合锁死（`tools/make_template.py:230-231`、`:271-273`）；其余（`PART`、`PROJECT_ROOT`、`VIVADO_VERSION`、`VIVADO_PATH`、`PYTHON`、`KIT_DIR`）只在 persona 片段中出现。渲染器的值表共 15 个键（`tools/render_patch.ps1` 的 `$values`）。
- `{{model}}` 是 DSH 的提示词占位符，**故意不替换**（`tools/render_patch.ps1:19`、`:145`），因此它也不允许被当成"残留占位符"判死——doctor 第 10 项同样豁免它。
- **版本档位**：`vivado_version` 去掉非数字字符后按 `[version]` 比较，`>= 2025.2` 用 `2025.2plus`，否则 `2023.1`；片段不存在直接 `throw`（`tools/render_patch.ps1:76-87`）。两档的实测/未实测界线见 [版本分档](version-matrix.md) §1。
- **渲染后自检**（`tools/render_patch.ps1:142-160`）：① 除 `{{model}}` 外无残留占位符；② 有顶层 `- insert:`；③ 恰好 23 条 `- id:` 且含 `persona` / `skill-filesystem` / `mcp-vivado`；④ persona 的 `prefix:` 是 `|` 缩进块标量。渲染前另有一道 ASCII 守卫，8 个路径值出现非 ASCII 直接 `throw`；输出强制 LF、UTF-8 无 BOM。

## 5. 安装链路：`install.ps1` 的 9 步

`install.ps1` 用 9 个 `[STEP]` 行推进（行号即实现位置）：`1/9 resolve config`（`:169`）→ `2/9 detect values`（`:191`）→ `3/9 check profile`（`:390`）→ `4/9 stage the kit`（`:407`）→ `5/9 persist the values that were actually used`（`:411`）→ `6/9 render the bundle patch`（`:438`）→ `7/9 install the bundle`（`:473`）→ `8/9 verify`（`:616`）→ `9/9 done`（`:642`）。

| 步 | 做什么 | 关键约束 |
|---|---|---|
| 1–2 | 读 `config.yml`，**只补**缺失/明显错的探测值（Vivado、Python、vivado-mcp site） | ASCII 守卫：`-StageDir`、`skills`、`project_root`、`vivado_mcp_cwd`、`temp_dir` 任一含非 ASCII 立即 FAIL（`docs/install.md:60`） |
| 3 | 检查 `<profile>/package.json` 存在且是合法 JSON | profile 不存在时列出 `<DSH_HOME>\profiles` 下已有名字 |
| 4 | `robocopy` 复制到 staging | 排除 `cordis.patch.yml`、`config.yml`、`KIT-SPEC.md`、`*.bak-*`、`.tmp*`、`.git`、`node_modules`（`lib/install-helpers.ps1:780-800`）；增量、不 `/PURGE` |
| 5 | 把**本轮实际用到**的值写进 `<staging>/config.yml` | staging 是派生物，每轮重写（`docs/install.md:63`） |
| 6 | 在 staging 里跑 `tools/render_patch.ps1` | 所有绝对路径都指向 staging |
| 7 | 备份 → 装 → 建链接 → 合并版本豁免 | 备份 `package.json` / `pnpm-lock.yaml` / `compatibility.json` 为 `*.bak-<yyyyMMdd>`，已存在则保留最早那份（`docs/install.md:72`） |
| 8 | `dsh --profile <p> --dump-config` 断言 4 条标记 | 见下 |
| 9 | 打印重启要求、备份清单、逐行回退命令 | 失败会自动回滚本轮改过的 profile 文件 |

第 7 步的三种模式（`install.ps1:494-521`）：

- `cli`：调**随安装包**的 CLI `<install>\resources\runtime\cli\bin\dsh.cmd plugin --profile <p> add "link:<staging>"`，由它内部的 pnpm 写依赖行、由 CLI 的 reconcile 写 `dsh.profile.bundles`；
- `manual`：完全不碰 pnpm，就地改 `package.json`（写盘前用 `ConvertFrom-Json` 复核「两行都在、其余行未变」），再建目录联接；
- `auto`（默认）：CLI 非 0 退出 → 打印 stderr 尾巴（含 CLI 自己的 `Log file:`）→ 回滚到备份 → 改走 `manual`（`install.ps1:506-517`）。

`node_modules` 那层的路径**按包名推导**，不写死 scope：`PackageName -replace '/', '\'`（`install.ps1:572-575`），所以 `dsh-vivado` → `node_modules\dsh-vivado`，带 scope 的包 → `node_modules\@scope\name`。建链顺序 `mklink /J`（junction，不需要管理员）→ `mklink /D` → `Copy-Item -Recurse`（`lib/install-helpers.ps1:730-773`）。

第 8 步的 4 条标记（`lib/install-helpers.ps1:832-841`）：① 列首的 bundle 横幅 `# == dsh-vivado`；② `- id: preset-vivado`；③ `customSkillDirs` **且**路径等于 `<staging>/skills`；④ `- id: mcp-vivado` **必须缩进**——缩进说明它嵌在预设的插件列表里，顶格则意味着漏到了 profile 层。四条都不写死行号，装好后的行号随宿主版本变。

## 6. `compatibility.json`：一行版本豁免

- 它是一张「`包@装的版本` → 允许的 DSH 版本数组」的 JSON（`docs/install.md:124`）。
- 为什么需要：profile 解析到的 `@deepseek-ai/dsh-mcp-client` 版本与宿主运行时版本不同时（本机实测 `0.1.7-rc.2` vs `0.2.1-rc.2`），DSH 加载 profile 时会**静默丢掉** `mcp-vivado` 那一行——预设还在，32 个工具没了。
- 豁免值必须是运行时版本串 `0.2.1-rc.2`：安装器优先取 `dsh.cmd --version`（正则抽版本，保留预发布后缀），拿不到才退 exe 的 `FileVersion`；`ProductVersion`（`0.2.1.0`，丢了 `-rc.2`）只作最后的兜底，真用它写进表里就是写坏（`lib/install-helpers.ps1:203-232`）。
- 一个必须知道的事实：`--dump-config` **不校验**它。本机实测：把 `compatibility.json` 清空成 `{}`、甚至写成非法 JSON，dump 输出逐字节相同、退出码 0（`install.ps1:585-589`、`docs/install.md:147`）。所以第 8 步的 4 条标记**不能**替代这条判定，只有 doctor 第 12 项能判（它直接读文件，`doctor.ps1:1105`）。
- 合并而不是覆盖：只加自己那一个键，其余键与允许版本原样保留；文件不是合法 JSON 时只 WARN、一个字节都不改（`install.ps1:585-609`）。

## 7. doctor 的 13 项：设计原则

13 项的 id 与顺序固定在 `doctor.ps1:1273-1286`，与 [doctor 详解](doctor-checks.md) 一一对应。几条原则值得记住：

1. **能证明才 FAIL**。判据宁可 WARN：`part` 拿不到 parts 树只 WARN（`doctor.ps1:569-572`）；`ascii-paths` 只有 cwd 非 ASCII 只 WARN（`:672-673`），因为 cwd 是 shell 位置，不是 kit 配置。
2. **三项永不 FAIL**：`license`（`:818`，许可证可能来自浮动服务器、加密狗或评估模式，静态判不了）、`mcp-patches`（`:1035`，缺补丁只是能力降级）、`compatibility`（`:1105`，后果是 mcp 行被静默丢弃，仍是能力降级）。
3. **还没装 ≠ 坏了**：profile 与 staging 都没有 kit 痕迹时，`bundle-installed` / `bundle-rendered` / `skills` 报 WARN（`doctor.ps1:933`、`:979`、`:1162`），这样使用者可以先体检、再安装。
4. **`-Quick` 只跳过 3 个慢探针**：`vivado-version` 的 `vivado.bat -version`（`doctor.ps1:373`）、`mcp-import`（`:706`）、`mcp-tools`（`:754`）。被跳过的项报 WARN `skipped by -Quick`，不是 PASS。
5. **崩溃兜底**：`license`、`mcp-patches` 在 `$checkList` 里是 `Soft=$true`，检查函数自身抛异常时降级成 WARN；其余项崩溃会变成 FAIL（`doctor.ps1:1290-1305`）。
6. **输出契约**：`-Json` 是**单行** JSON 数组、字段恒为 `{id,title,status,detail,fix}`（`doctor.ps1:1330-1332`；单行是刻意的：PS 5.1 按行管道化子进程输出，多行 JSON 会让 `| ConvertFrom-Json` 报错）；退出码 `0` = 无 FAIL，`1` = 至少一项 FAIL（`:1351`），WARN 不改退出码。

## 8. 为什么 4 个 vivado-mcp 补丁默认不自动打

- 本包**只带 `.patch`，不带改后的源码**（`patches/vivado-mcp/`、`NOTICE` §2.1）。两个理由：Apache-2.0 §4(b) 要求被修改的文件带"已修改"提示，把改动留在使用者显式应用的补丁里，比静默发一份改过的源码更符合该义务；以及"PR 优先、不做私有分支"（`patches/vivado-mcp/README.md` §6）。
- 不打补丁的代价可量化：`xdc_lint` 默认 `max_items=20`、`get_cdc_report` 默认 `max_details=100`（`NOTICE` §2.1 表），大工程会静默少给明细；`run_tcl` / `safe_tcl` 也没有 `max_lines` / `save_full_to`。
- doctor 判"补丁在不在"用的是**内容探针**（5 组 `Select-String -SimpleMatch` 源码标记），不是 mtime、也不是 `.bak` 文件：补丁重打后 mtime 毫无意义，而 `.bak-mcp-*` 备份反而会让"没打补丁"看起来像"打了"（`doctor.ps1:1035`、[doctor 详解](doctor-checks.md) §11）。

## 8.5 显示元数据：图标与标题（插件列表里长什么样）

bundle 在「设置 → 插件」里显示的标题、描述和图标**不来自渲染产物**，而是宿主从包本体读的
（`@deepseek-ai/dsh-app-boot` 的 `readPluginMeta` / `iconOf`，2026-10-24 读源码确认）：

| 显示项 | 来源 | 约束 |
|---|---|---|
| 标题 / 描述 | `locale/en.json` 的 `meta.title` / `meta.description`（缺省回退 `package.json` 的 `name` / `description`）；`locale/zh.json` 等同结构给中文 | 纯 JSON，UTF-8 |
| 图标 | `package.json` 顶层 `icon`（相对清单目录，**优先于** `exports["./icon"]`） | SVG / PNG / JPEG / WebP，**≤ 256 KiB**，必须留在包目录内；绝对路径、URL、指向包外的软链会被拒绝 |
| 生效方式 | 宿主把它读成 `data:` URL 交给前端渲染（卡片 48×48，详情页最大 320 高） | 改图标/标题后**重新 staging**（`install.ps1 -RenderOnly`）即可，不需要改 patch |

本包的现役值：`icon.png`（512×512，基于 Vivado 三平面标志重上色为蓝色族，见 `NOTICE` §3.0 的授权说明）、
`locale/en.json` = "Vivado Workflow"、`locale/zh.json` = "Vivado 工作环境"。

> 换图标：替换 `icon.png`（保持 ≤256 KiB、留在包内）→ 重跑 `install.ps1 -RenderOnly` → 重开插件页面。
> **不要**把图标放进渲染出的 `cordis.patch.yml`：显示元数据与 patch 是两条独立通路。

## 9. 已知限制

1. **Electron 宿主下 `dsh-hmr` 不生效**：profile 与 bundle patch 只在宿主**启动时**读。换版本档位、改 `config.yml`、重装 bundle，全都要重启（`docs/install.md:11`）。
2. **会话里的 shell 不是本包能决定的**（2026-10-25 更正）：预设只挂官方 `pwsh`（Windows）/ `bash`（其它）；`win_bash` 这类第三方 shell 插件装了也不依赖，卸了也不影响。若官方 `pwsh` 被第三方插件中途摘掉（`unknown tool "pwsh"`），本包的处理是"换仍然存在的 shell 或走 MCP"，**不是**去适配那个插件（`docs/troubleshooting.md` §2.5）。
3. **DSH 升级后 shipped 22 行可能变**：重跑 `py tools/make_template.py --source <你机器上已实证的 bundle patch>` 重抽模板与审计件，再跑 `--check`（`tools/make_template.py:14-20`、`:289-319`）。
4. **staging 是增量复制**：上一版有、新版已删的文件会残留在 staging；要绝对干净就先 `uninstall.ps1` 再 `install.ps1`（`docs/install.md:259`）。
5. **不改第三方源码**：`<vivado-mcp>` 视为只读，补丁手动应用（`NOTICE` §2.1）。
6. 本机**未实测**的项（例如 `2025.2+` 档全部版本事实）在 [版本分档](version-matrix.md) §5 单列，这里不重复，也不替代它。

## 10. 想加东西怎么改

| 想做的事 | 改哪里 | 必须跑的门禁 |
|---|---|---|
| 加一条**本包自己的**插件行（非 shipped） | 改生成器 `tools/make_template.py` 的拼装段，并同步两处行数断言（`tools/make_template.py:78-83`、`:102-103`）与渲染器断言（`tools/render_patch.ps1:150-154`），再重新生成模板；**不要**直接改渲染产物 `cordis.patch.yml` | 重生成后 `py tools/make_template.py --check`；渲染一次；`doctor.ps1` |
| 加一个技能 | 新建 `skills/<name>/SKILL.md`，`name:` 必须等于目录名 | `py tools/gen_skills_manifest.py`（MANIFEST 由生成器唯一产出、禁手写）+ `--check`；`doctor.ps1` 第 13 项 |
| 改 persona 分档内容 | `templates/persona/2023.1.frag.yml` 与 `2025.2plus.frag.yml`（两档都改，否则同一份纪律会在两档漂移） | 渲染一次确认块标量完好；`doctor.ps1` 第 10 项 |
| 新增/改名占位符 | `tools/render_patch.ps1` 的 `$values`、`tools/make_template.py` 的 `EXPECTED_PLACEHOLDERS`、模板或片段 | 两个 `--check` + 渲染 + `doctor.ps1` |
| 加/改一个运行辅助脚本 | `tools/vivado-*.ps1`；公共件在 `lib/common.ps1`（`Find-KitVivadoBat` / `New-KitAsciiWorkDir` / `Write-KitBatchLauncher` / `Get-KitBatchExitCode`）。**不要**改回 `Start-Process -PassThru` 取退出码 | 真跑 `tools/vivado-probe.ps1`（`PROBE_RESULT=OK`）+ `tools/tcl-check.ps1` 对一个 `.tcl` 目录（`TCLCHECK_RESULT=PASS`）+ `doctor.ps1` |

门禁按这个顺序跑（前一步不过就不用跑后面）：

```powershell
py tools\make_template.py --check          # 模板/审计件与生成器是否逐字节一致
py tools\gen_skills_manifest.py --check    # skills/MANIFEST.json 是否漂移
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\vivado-probe.ps1     # 会真起一次 Vivado（~15s）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\tcl-check.ps1 .\templates
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -RenderOnly   # 只 staging + 渲染，自检在渲染器里
powershell -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1 -Json          # 13 项机器可读
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -WhatIf       # 真装之前先看完整计划，不改任何字节
```

- 本仓库**不随包提供端到端验收脚本**：最后一步永远是「真装一次 + 重启宿主 + 在新会话里确认 `Vivado` 预设与 32 个 `mcp__vivado__*`」。症状对照见 [troubleshooting](troubleshooting.md)。
- 端到端没有 `--check` 那样硬的判据，所以改完要么真装，要么至少跑 `install.ps1 -RenderOnly` + `doctor.ps1 -Json` 并把输出贴在 PR / 报告里。

## 11. 运行辅助脚本（`tools/vivado-*.ps1`）

三个脚本都是给**会话里的助手**用的，不是给安装流程用的：预设 persona 直接点名它们，所以每次会话不必重新发明"怎么起 Vivado"。

| 脚本 | 干什么 | 为什么存在（实测） |
|---|---|---|
| `tools/vivado-probe.ps1` | 写一行 Tcl 打印 `TCL_OK [info patchlevel]`，跑一次 batch，输出 `PROBE_*` 行 | `vivado.bat -version` 不是探针：重定向后 exit 1 且零输出（2026-10-24） |
| `tools/vivado-run.ps1` | 把一份 Tcl 跑成 batch；`-Detach` 按 `wmi-com → wmi-cim → schtasks` 三级链起脱离进程树的构建（`RUN_LAUNCHER` 写明走了哪条）；两种模式都写 `build_status.txt` | 会话后台进程随回合中断被回收（2026-10-24 21:02）；`cmd /c "<带引号整串>"` 会二次套引号；2026-10-28 实测：CIM 路由 `Win32_Process.Create` 恒 `RV=8`，而老式 COM 路由可用且能逃出 `KILL_ON_JOB_CLOSE` job；默认 schtasks 任务因 `IdleSettings` 会把 34 min 实现段在 9m20s 静默停掉 |
| `tools/tcl-check.ps1` | 找到 Vivado 自带的 `tclsh85t.exe`、补齐 `PATH` + `TCL_LIBRARY`，逐文件跑 `info complete` | 直接调 tclsh85t 报 `0xC0000135`（缺 DLL）；旧 CI 因此把 Tcl 语法检查永久 SKIP 了 |

**为什么都要经过一个生成的 `.cmd` 包装器**：Windows PowerShell 5.1 里，`Start-Process -PassThru` 对 `.bat` 返回的 Process 对象 `ExitCode` 是 `$null`（2026-10-25 实测，Vivado 已经正常 `Exiting` 了仍然为空）。把 `%ERRORLEVEL%` 交给 cmd 自己写进状态文件，再读回来，是唯一不丢值的做法（`lib/common.ps1` 的 `Write-KitBatchLauncher` / `Get-KitBatchExitCode`）。包装器里两处 cmd 解析细节是刻意的，**不要"简化"**：`%KIT_RC% >> "file"` 之间必须留空格（变量展开后裸 `0>>` / `2>>` 是句柄重定向，不是追加）；`cmd /c` 后面只跟**一个**带引号的 token（整串带引号是实测失败形态）。

附加文件：`templates/build-markers.tcl` 给构建 Tcl 用（`kit_mark SYNTH_OK ...` / `kit_fail ...`），它只认 `KIT_STATUS_FILE` 环境变量，所以 cmd / pwsh / bash 下同一份脚本都能用。
