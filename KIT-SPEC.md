# KIT-SPEC — dsh-vivado 团队契约（2026-10-24）

> 所有队友**先读本文件**。任务书原文：`作者本机笔记库\本项目的需求契约（未随仓库发布）`
> 前序事实：`作者本机笔记库\作者本机的规范化取证记录（未随仓库发布）`
>
> **2026-10-25 增补（本文件=2026-10-24 的历史分工记录，按历史件读）**：本轮按《dsh-vivado 实战问题与改进》
> 加了 `tools/vivado-probe.ps1`、`tools/vivado-run.ps1`、`tools/tcl-check.ps1`、`templates/build-markers.tcl`、
> `docs/tools.md`；persona 两档**去掉对第三方 shell（`win_bash`）的依赖**，改为只用会话里真实存在的官方
> `pwsh`/`bash`；渲染器 `$values` 由 14 键变 15 键（新增 `{{KIT_DIR}}`）。现役契约以 `docs/architecture.md` 为准。

## 0. 一句话目标

把「Vivado 专用会话预设 + AMD 官方 6 技能 + 文档检索 + 已打补丁的 vivado-mcp」打成一个
**DSH bundle 插件包**，使用者「一条命令 + 重启」即可获得同等环境。

## 1. 交付根目录（唯一写作用域根）

```
D:\dsh-vivado\
```

**不要**往 vault（`作者本机笔记库\.dsh\`）或 `<project_root>` 其它目录写东西。
**不要**改在有 desktop profile（`<DSH_HOME>\profiles\desktop\`）。
**不要** git commit、不要 `plugin_manager` 安装到在用的 desktop profile（Lead 负责受控测试）。

## 2. 目录与所有权（写作用域，别越界）

| 路径 | 所有者 | 内容 |
|---|---|---|
| `package.json` | Lead | bundle 清单：`name`/`version`/`private`/`type`/`description`/`dsh.bundle.patch`/`dsh.engines` |
| `cordis.patch.yml` | Lead（**由模板渲染，不手写**） | 预设行 + skill-filesystem 行 + mcp-vivado 行 |
| `config.example.yml` / `config.yml` | Lead | 扁平 `key: value`，见 §4 |
| `lib/common.ps1` | Lead | PowerShell 公共函数（读 config、定位 DSH、备份、日志） |
| `templates/preset.patch.yml.tmpl` | Lead | 带 `{{PLACEHOLDER}}` 的 YAML 模板（模板契约 9 个 + 渲染器 `$values` 15 键，多出来的 6 个只在 persona 片段里用） |
| `tools/render_patch.ps1` | Lead | 渲染器：config → cordis.patch.yml |
| `install.ps1` / `uninstall.ps1` | **ps-installer** | 装/卸；调 `tools/render_patch.ps1` |
| `docs/install.md` | **ps-installer** | 安装/卸载/回退说明书 |
| `doctor.ps1` | **ps-doctor** | 体检，见 §7 |
| `docs/doctor-checks.md` | **ps-doctor** | 每条检查的判据与修法 |
| `templates/persona/*.frag.yml` | **ps-docs**（Lead 出 v0） | 版本分档 persona 片段 |
| `skills/**` | **ps-skills** | AMD 6 件 + 自研纪律 skill + `skills/NOTICE-skills.md` |
| `NOTICE` / `LICENSE` / `README.md` | **ps-docs** | 来源/许可/改动清单/快速开始 |
| `docs/version-matrix.md` | **ps-docs** | 版本真值分档表（T4） |
| `patches/vivado-mcp/**` | **ps-docs** | 3 个 MCP 补丁的 `.patch` 归档 + README |

共享只读：`<project_root>\.tmp\kit-recon-2026-10-24\`（asar 取证的官方文档副本，`refs/`、`pkg-skillfs/`）

## 3. 产物运行时形态（必须理解，别自作主张）

安装时 `install.ps1` 做：

1. 读 `config.yml`（没有就从 `config.example.yml` 探测生成）；
2. 把**整个 dist 目录**复制到 **staging**：`$DSH_HOME\bundles\dsh-vivado\`（默认 `$DSH_HOME=~\.dsh`）；
3. 在 staging 里用 `tools/render_patch.ps1` 渲染 `cordis.patch.yml`（**所有绝对路径都指向 staging**，
   因为 `customSkillDirs` / MCP `command` 必须是绝对路径）；
4. 跑官方 CLI：`"<install>\resources\runtime\cli\bin\dsh.cmd" plugin --profile <p> add "link:<staging>"`
   （等价于 `plugin_manager install_bundle`；由 CLI 的 reconcile 写入 `dsh.profile.bundles`）；
5. 备份被改的 profile 文件为 `*.bak-<YYYYMMDD>`，打印**必须重启宿主**。

装完的结构（在使用者的 `~/.dsh`）：

```
~/.dsh/bundles/dsh-vivado/     ← staging（bundle 本体，含 skills/）
~/.dsh/profiles/<p>/package.json   ← dependencies 多一行 "dsh-vivado": "link:<staging>"
                                     dsh.profile.bundles 末尾多一项 "dsh-vivado"
~/.dsh/profiles/<p>/cordis.patch.yml ← 安装器**不改**（bundle 层本身提供预设）
```

## 4. `config.yml` 契约（扁平 key: value，安装器自带解析器，不依赖 YAML 模块）

```yaml
# dsh-vivado 环境配置（install.ps1 会按探测结果写实际值）
part: xcku060-ffva1156-2-i          # 器件
project_root: D:/FPGA               # 工程根（必须 ASCII）
vivado_version: 2023.1              # 决定 persona 版本分档
vivado_path: D:/Xilinx/Vivado/2023.1/bin   # 含 vivado.bat 的 bin 目录
python: <vivado-mcp>/venv/Scripts/python.exe   # 跑 vivado-mcp 的解释器
vivado_mcp_site: <vivado-mcp>/site        # PYTHONPATH
vivado_mcp_cwd: D:/FPGA                    # MCP server 的 cwd（必须 ASCII）
temp_dir: D:/FPGA/.tmp                     # TEMP/TMP（必须 ASCII）
```

规则：值里 `\` 允许，渲染时统一写 `/`；`#` 之后是注释；空行忽略；未知键忽略。
`vivado_version` → tier：`>=2025.2` 用 `2025.2plus`，否则 `2023.1`。

## 5. 预设契约（渲染后的 `cordis.patch.yml` 顶层只有一条 `- insert:`）

`- insert:` 下**只有 1 行**：`preset-vivado`（`@deepseek-ai/dsh-agent-preset`，`config.id: vivado`）。
它的 `config.plugins` = shipped `standard.patch.yml` 的 22 行原样（顺序/内容不许改）+ 两处改动：

1. `persona` 行的 `config.prefix` = 版本分档 persona 片段（`{{PERSONA_BLOCK}}` 渲染）；
2. `skill-filesystem` 行加 `config: { customSkillDirs: ['<staging>/skills'] }`；
3. 末尾追加 `mcp-vivado` 行（`@deepseek-ai/dsh-mcp-client`，stdio，32 工具）。

**shipped 22 行的唯一权威来源**：从 bundle 现役文件
`作者本机笔记库\.dsh\bundles\vivado-preset\cordis.patch.yml` 原样取（它已自证与
shipped 逐字节一致，见结论 §2.2）；Lead 会把它落到 `templates/shipped-standard-22rows.yml`，
队友**不要手抄**。

## 6. 硬约束（红线，违反即返工）

1. **不打包 Vivado 本体/许可证**；不代签 AMD 协议。
2. 安装器**只动 bundle 与 profile 的 bundle 列表**；改 profile 前先备份；给逐行回退命令。
3. **必须重启宿主**才生效 —— 文档里不许出现「热更新」。
4. 结论一律带证据（`file:line` 或命令原文 + 输出）；「本机实测」不许写成「官方保证」。
5. 所有脚本只用 **Windows PowerShell 5.1**（`powershell.exe`）可用的语法：
   - 不用 `??`/`?.`/三元（PS7 才有）；不用 `ConvertFrom-Json -AsHashtable`；
   - 文件编码 **UTF-8 无 BOM**，但**脚本里的中文字符串必须能过 PS5.1**：为避 GBK 乱码，
     **PS 脚本（*.ps1）一律用英文输出**，中文说明放 `.md`。
   - 路径优先纯 ASCII（dist 在 `<project_root>\dist\`，满足）。
6. 幂等：`install.ps1` 跑两次结果一致；`uninstall.ps1` 可把 profile 还原到备份状态。
7. 不改第三方源码（`<vivado-mcp>\site` 只读）；补丁只以 `.patch` 文件随包。

## 7. doctor.ps1 必须覆盖（每项 PASS/WARN/FAIL + 一句可执行修法）

| # | id | 检查 | FAIL/WARN 判据 |
|---:|---|---|---|
| 1 | `vivado-install` | `vivado_path\vivado.bat` 存在且是文件 | FAIL=缺失/不是文件 |
| 2 | `vivado-version` | 版本可证（`installed_devices.txt` BuildNumber → `vivado.bat -version` → 目录名） | FAIL=拿到两个可比值且不一致；WARN=只能靠目录名 |
| 3 | `python` | `python` 可跑 + **≥3.10**（vivado-mcp 0.3.26 `Requires-Python>=3.10`）+ `PYTHONUTF8=1` 下能输出中文 | FAIL=不可跑/低于 3.10/UTF-8 探针失败；WARN=模板未导出 `PYTHONUTF8` |
| 4 | `part` | `part` 非空、器件族目录存在 | FAIL=族目录不存在；WARN=无法静态核实 |
| 5 | `ascii-paths` | cwd/TEMP/TMP/project_root/vivado_mcp_cwd/temp_dir 纯 ASCII | FAIL=TEMP/TMP 或三个 config 键含非 ASCII；**WARN=仅 cwd 非 ASCII**（防止从中文 vault 跑 doctor 把健康环境判死） |
| 6 | `mcp-import` | `PYTHONPATH=<vivado_mcp_site>` 下 `import vivado_mcp` 且路径落在 site 内 | FAIL=不可导入/路径不符 |
| 7 | `mcp-tools` | `mcp_ctl.py list` = **32** 工具 | FAIL=命令失败；WARN=数量≠32 但 >0 |
| 8 | `license` | 静态判定：`XILINXD_LICENSE_FILE`/`LM_LICENSE_FILE` 或 `~/.Xilinx/*.lic` | **只 WARN，不 FAIL**（license 可能来自别处） |
| 9 | `bundle-installed` | profile `dependencies` 有 link 依赖且目录存在 + `dsh.profile.bundles` 含之 | FAIL=缺依赖/目录不存在/未登记；**裸 profile（零痕迹）=WARN** |
| 10 | `bundle-rendered` | staging 的 `cordis.patch.yml` 存在、无未替换占位符（`{{model}}` 除外）、`customSkillDirs` 指向存在目录 | FAIL=缺失/占位符残留/目录不存在 |
| 11 | `mcp-patches` | 3 个内容探针（`xdc_lint.max_items=0`、`get_cdc_report.max_details=0`、`tcl_tools` 的 `safe_tcl` 提示/`max_lines`） | **只 WARN**（缺补丁仍能跑，只是默认非全量） |
| 12 | `compatibility` | profile 里 mcp-client 版本 ≠ 运行时版本时，`compatibility.json` 必须有该精确豁免键；运行时版本取 `dsh.cmd --version` | **只 WARN 永不 FAIL**（缺豁免时 mcp 行会被静默禁用） |
| 13 | `skills` | staging `skills/` 含 8 个技能目录（AMD 6 + `amd-doc-search` + `vivado-workflow-discipline`），每个 `SKILL.md` 的 `name:` == 目录名 | FAIL=目录/SKILL.md 缺失或 name 不符；WARN=staging 不存在 |

要求：`doctor.ps1 -Json` 输出机器可读结果（`{id,title,status,detail,fix}` 五字段）；退出码 0=无 FAIL，1=至少一项 FAIL。
`-Quick` 跳过慢检查（Vivado 版本探测 / import / `mcp_ctl.py list`）。

## 8. 团队纪律

- 每步带证据；改动他人文件前先 `send_message` 给 Lead。
- 备份惯例 `*.bak-<YYYYMMDD>`；**不要在 dist 里留备份文件**（会进包），备份放
  `<project_root>\.tmp\kit-recon-2026-10-24\backups\`。
- 完成后把**证据报告**写到作者本机的临时目录（清单见当时的会话记录；不随仓库发布）
  （不写进 dist），并在 `send_message` 里给 Lead 一段 ≤15 行摘要（含命令原文与关键输出）。
- 遇到阻塞（缺事实/契约不清）立刻问 Lead，不要猜着写。
